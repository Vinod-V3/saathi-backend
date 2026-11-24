"""
Shared helpers for the read-only reporting export commands (export_message_log,
export_session_summary). Not a command itself: Django skips modules whose name
starts with an underscore.

The SQL files live in chatbot/scripts/reporting/. Each one is a single WITH ...
SELECT statement with a SETTINGS block at the top; the commands only fill in the
SETTINGS values and run the file inside a READ ONLY transaction.
"""

import datetime
import re
from pathlib import Path

from django.core.management.base import CommandError
from psycopg2 import sql as pg_sql

REPORTING_DIR = Path(__file__).resolve().parents[2] / 'scripts' / 'reporting'

SETTINGS_START = '-- ===== SETTINGS START'
SETTINGS_END = '-- ===== SETTINGS END'
SHARED_START = '-- ===== SHARED DETECTION START'
SHARED_END = '-- ===== SHARED DETECTION END'
# One overridable setting per line: "    CAST(<value> AS <type>)   AS <name>,   -- comment"
SETTING_LINE = re.compile(
    r'^(?P<head>\s*CAST\()(?P<value>.*)(?P<tail>\s+AS\s+[a-z_\[\]]+\)\s+AS\s+(?P<name>[a-z_]+)\b.*)$'
)
FORBIDDEN_KEYWORDS = re.compile(
    r'\b(insert|update|delete|merge|upsert|create|alter|drop|truncate|grant|revoke|copy|call|execute|'
    r'vacuum|analyze|refresh|lock|reindex|cluster|comment|listen|notify|prepare|discard|set|reset|'
    r'begin|commit|rollback|savepoint|into)\b'
)


def split_sql(text):
    """Return (executable_sql, code_only): comments removed / comments, literals and quoted names blanked."""
    exec_parts, code_parts = [], []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if text.startswith('--', i):
            j = text.find('\n', i)
            i = n if j == -1 else j
        elif text.startswith('/*', i):
            j = text.find('*/', i + 2)
            if j == -1:
                raise CommandError('Unterminated /* comment in SQL file')
            i = j + 2
        elif ch in ("'", '"'):
            j = i + 1
            while True:
                j = text.find(ch, j)
                if j == -1:
                    raise CommandError(f'Unterminated {ch} quote in SQL file')
                if j + 1 < n and text[j + 1] == ch:  # doubled quote = escaped
                    j += 2
                    continue
                break
            exec_parts.append(text[i:j + 1])
            code_parts.append(' ')
            i = j + 1
        else:
            exec_parts.append(ch)
            code_parts.append(ch)
            i += 1
    return ''.join(exec_parts), ''.join(code_parts)


def guard_read_only(sql_text):
    """Allow exactly one WITH/SELECT statement with no write or session-changing keywords."""
    executable, code = split_sql(sql_text)
    code = code.strip()
    if code.endswith(';'):
        code = code[:-1].rstrip()
        executable = executable.strip()
        executable = executable[:executable.rfind(';')]
    lowered = code.lower()
    if not (lowered.startswith('with') or lowered.startswith('select')):
        raise CommandError('Refusing to run: the SQL must be a single WITH/SELECT statement.')
    if ';' in code:
        raise CommandError('Refusing to run: the SQL contains more than one statement.')
    bad = FORBIDDEN_KEYWORDS.search(lowered)
    if bad:
        raise CommandError(f'Refusing to run: the SQL contains the keyword "{bad.group(1)}".')
    return executable.strip()


def apply_settings(sql_text, overrides, raw_conn, sql_file):
    """Replace the value of each overridden setting line inside the SETTINGS block."""
    lines = sql_text.split('\n')
    try:
        start = next(i for i, line in enumerate(lines) if SETTINGS_START in line)
        end = next(i for i, line in enumerate(lines) if SETTINGS_END in line)
    except StopIteration:
        raise CommandError(f'SETTINGS markers not found in {sql_file}')

    pending = dict(overrides)
    for i in range(start, end):
        match = SETTING_LINE.match(lines[i])
        if match and match.group('name') in pending:
            literal = pg_sql.Literal(pending.pop(match.group('name'))).as_string(raw_conn)
            lines[i] = f"{match.group('head')}{literal}{match.group('tail')}"
    if pending:
        raise CommandError(f'Settings not found in the SETTINGS block: {", ".join(sorted(pending))}')
    return '\n'.join(lines)


def settings_cte(sql_text):
    """The 'WITH settings AS (...)' part of the query, reused by the preflight checks."""
    end_marker = sql_text.index(SETTINGS_END)
    close = sql_text.index(')', end_marker)
    return sql_text[sql_text.index('WITH settings AS ('):close + 1]


def shared_block(sql_text, sql_file):
    """The lines between the SHARED DETECTION markers (the detection chain both sheets use)."""
    lines = sql_text.split('\n')
    try:
        start = next(i for i, line in enumerate(lines) if line.startswith(SHARED_START))
        end = next(i for i, line in enumerate(lines) if line.startswith(SHARED_END))
    except StopIteration:
        raise CommandError(f'SHARED DETECTION markers not found in {sql_file}')
    return lines[start + 1:end]


def check_in_sync(sql_text, sql_file, other_text, other_file):
    """Refuse to run when the shared detection block differs between two SQL files.

    Both texts must already have the same CLI overrides applied, so differing
    default dates / tz / user lists in the files never count as drift.
    """
    ours, theirs = shared_block(sql_text, sql_file), shared_block(other_text, other_file)
    for number, (line, other) in enumerate(zip(ours, theirs), start=1):
        if line != other:
            raise CommandError(
                f'Refusing to run: the shared detection block of {sql_file.name} differs from {other_file.name} '
                f'at block line {number}:\n  {sql_file.name}: {line.strip()}\n  {other_file.name}: {other.strip()}\n'
                f'Copy the block between the SHARED DETECTION markers from {other_file.name} into {sql_file.name}.')
    if len(ours) != len(theirs):
        raise CommandError(
            f'Refusing to run: the shared detection block of {sql_file.name} has {len(ours)} lines, '
            f'{other_file.name} has {len(theirs)}. Copy the block between the SHARED DETECTION markers '
            f'from {other_file.name} into {sql_file.name}.')


def parse_date(value, flag):
    try:
        return datetime.date.fromisoformat(value)
    except ValueError:
        raise CommandError(f'{flag} must be a date in YYYY-MM-DD format, got "{value}"')


def parse_list(value):
    return [item.strip() for item in (value or '').split(',') if item.strip()]


def preflight(cur, settings_cte_sql, stdout, style):
    """Read-only sanity checks on the same database. No external calls."""
    range_filter = """cs.created_at >= (st.date_from::timestamp AT TIME ZONE st.tz)
                  AND cs.created_at < ((st.date_to + 1)::timestamp AT TIME ZONE st.tz)"""

    cur.execute(f'{settings_cte_sql} SELECT st.ai_profile_id, p.first_name, st.stage_order, st.onboarding_session_type '
                f'FROM settings st LEFT JOIN chatbot_profile p ON p.id = st.ai_profile_id')
    ai_id, ai_name, stage_order, onboarding_type = cur.fetchone()
    if ai_name is None:
        stdout.write(style.WARNING(f'  ! AI profile id {ai_id} not found — speaker detection will be wrong'))
    else:
        stdout.write(f'  AI profile          : id={ai_id} name={ai_name!r}')

    cur.execute(f"""{settings_cte_sql}
        SELECT COALESCE(cs.session_type, '(none)'), COALESCE(b.route, '(none)'), b.stream, COUNT(*)
        FROM chatbot_chatsession cs CROSS JOIN settings st
        LEFT JOIN chatbot_companybot b ON b.id = cs.company_bot_id
        WHERE {range_filter}
        GROUP BY 1, 2, 3 ORDER BY 4 DESC""")
    session_mix = cur.fetchall()
    for session_type, route, stream, count in session_mix:
        stdout.write(f'  sessions in range   : {count:>6}  type={session_type} bot={route} stream={stream}')
    if not session_mix:
        stdout.write(style.WARNING('  ! no sessions started in this range'))

    cur.execute(f"""{settings_cte_sql}
        SELECT COUNT(*) FROM chatbot_companychat c
        JOIN chatbot_chatsession cs ON cs.session = c.session CROSS JOIN settings st
        WHERE {range_filter}""")
    stdout.write(f'  messages in range   : {cur.fetchone()[0]:>6}  (before user filters)')

    cur.execute(f"""{settings_cte_sql},
        bots AS (
            SELECT DISTINCT b.context
            FROM chatbot_chatsession cs CROSS JOIN settings st
            JOIN chatbot_companybot b ON b.id = cs.company_bot_id
            WHERE {range_filter} AND cs.session_type IS DISTINCT FROM st.onboarding_session_type
        ),
        groups AS (
            SELECT 'goal' AS grp, goal_patterns AS pats FROM settings
            UNION ALL SELECT 'objectives', objective_patterns FROM settings
            UNION ALL SELECT 'action_steps', action_steps_patterns FROM settings
            UNION ALL SELECT 'plan', plan_patterns FROM settings
            UNION ALL SELECT 'out_of_scope', out_of_scope_patterns FROM settings
        )
        SELECT g.grp, EXISTS (SELECT 1 FROM bots b WHERE lower(b.context) ~* ANY (g.pats)),
               EXISTS (SELECT 1 FROM bots)
        FROM groups g""")
    for group, found, have_bots in cur.fetchall():
        if not have_bots:
            break
        if found:
            stdout.write(f'  pattern check       : {group:<13} found in bot prompt')
        else:
            stdout.write(style.WARNING(
                f'  ! pattern check     : {group:<13} NOT found in bot prompt — the prompt wording may have '
                f'changed; review the {group} patterns in the SETTINGS block'))

    return {'stage_order': list(stage_order or []), 'onboarding_type': onboarding_type, 'session_mix': session_mix}


def open_read_only(cur, statement_timeout, stdout, prefix):
    """Switch the current transaction to READ ONLY with timeouts, and prove it. Call inside transaction.atomic()."""
    cur.execute('SET TRANSACTION READ ONLY')
    cur.execute(f"SET LOCAL statement_timeout = '{int(statement_timeout)}s'")
    cur.execute("SET LOCAL idle_in_transaction_session_timeout = '300s'")
    cur.execute('SHOW transaction_read_only')
    if cur.fetchone()[0] != 'on':
        raise CommandError('Could not switch the transaction to read-only; aborting.')
    stdout.write(f'[{prefix}] transaction_read_only=on')
