"""
Django management command to export the Saathi "Session Summary" reporting sheet as CSV.

The extraction logic lives in chatbot/scripts/reporting/session_summary.sql (the same
file can be pasted into pgAdmin / Metabase). Its detection block is a copy of the one
in message_log.sql; this command refuses to run when the two differ. It only fills in
the SETTINGS values from the CLI, runs the query inside a READ ONLY transaction that is
always rolled back, and streams the rows to a CSV file.

Usage:
    python manage.py export_session_summary --from 2026-10-01 --to 2026-10-31 --out session_summary.csv
    python manage.py export_session_summary --from 2026-10-01 --to 2026-10-31 --tz Asia/Kolkata \
        --exclude-users TEST_QA01,TEST_QA02 --out session_summary.csv
"""

import csv
import os
from collections import Counter
from pathlib import Path

from django.core.management.base import BaseCommand, CommandError
from django.db import connection, transaction

from ._reporting_common import (
    REPORTING_DIR, apply_settings, check_in_sync, guard_read_only, open_read_only, parse_date, parse_list, preflight,
    settings_cte,
)

SQL_FILE = REPORTING_DIR / 'session_summary.sql'
MESSAGE_LOG_SQL_FILE = REPORTING_DIR / 'message_log.sql'
FINAL_SELECT_MARKER = '-- ===== FINAL SELECT ====='

SESSION_COL = 'session_id'
STAGE_COL = 'Session _Stage '
MIP_COL = 'MIP_user asked query_timestamp'
ONBOARDING_LABEL = 'Onboarding'

# Report-only counts, computed from the same CTE chain as the export (read-only).
DIAGNOSTICS_SELECT = """
SELECT
    (SELECT COUNT(*) FROM onb WHERE onb_src = 'row')     AS onb_via_row,
    (SELECT COUNT(*) FROM onb WHERE onb_src = 'history') AS onb_via_history,
    (SELECT COUNT(*) FROM mip_sel WHERE goal_sel_seq IS NOT NULL AND goal_sel_seq <> obj_seq - 1)  AS goal_sel_gap,
    (SELECT COUNT(*) FROM mip_sel WHERE obj_sel_seq IS NOT NULL AND obj_sel_seq <> steps_seq - 1)  AS obj_sel_gap
"""


class Command(BaseCommand):
    help = 'Exports the Saathi Session Summary reporting sheet to CSV (strictly read-only).'

    def add_arguments(self, parser):
        parser.add_argument('--from', dest='date_from', required=True,
                            help='First day (YYYY-MM-DD) of session start, inclusive, in --tz.')
        parser.add_argument('--to', dest='date_to', required=True,
                            help='Last day (YYYY-MM-DD) of session start, inclusive, in --tz.')
        parser.add_argument('--out', required=True, help='Output CSV path.')
        parser.add_argument('--tz', default='UTC', help="Timezone for dates and timestamps (default UTC, e.g. 'Asia/Kolkata').")
        parser.add_argument('--exclude-users', default='', help='Comma-separated user ids to leave out.')
        parser.add_argument('--include-only', default='', help='Comma-separated user ids to keep (default: everyone).')
        parser.add_argument('--bom', action='store_true', help='Write a UTF-8 BOM (helps Excel open Indic text).')
        parser.add_argument('--statement-timeout', type=int, default=600, help='Per-statement timeout in seconds.')
        parser.add_argument('--batch-size', type=int, default=2000, help='Rows fetched per round trip.')

    def handle(self, *args, **options):
        date_from = parse_date(options['date_from'], '--from')
        date_to = parse_date(options['date_to'], '--to')
        if date_from > date_to:
            raise CommandError('--from must not be after --to')

        overrides = {
            'date_from': date_from.isoformat(),
            'date_to': date_to.isoformat(),
            'tz': options['tz'],
            'exclude_user_ids': parse_list(options['exclude_users']),
            'include_only_user_ids': parse_list(options['include_only']),
        }

        connection.ensure_connection()
        raw_conn = connection.connection
        sql_text = apply_settings(SQL_FILE.read_text(encoding='utf-8'), overrides, raw_conn, SQL_FILE)
        message_log_text = apply_settings(MESSAGE_LOG_SQL_FILE.read_text(encoding='utf-8'), overrides, raw_conn,
                                          MESSAGE_LOG_SQL_FILE)
        check_in_sync(sql_text, SQL_FILE, message_log_text, MESSAGE_LOG_SQL_FILE)
        query = guard_read_only(sql_text)
        if FINAL_SELECT_MARKER not in sql_text:
            raise CommandError(f'"{FINAL_SELECT_MARKER}" marker not found in {SQL_FILE}')
        diagnostics_query = guard_read_only(sql_text[:sql_text.index(FINAL_SELECT_MARKER)] + DIAGNOSTICS_SELECT)
        settings_sql = settings_cte(sql_text)

        out_path = Path(options['out'])
        stats = Counter()
        stage_counts = Counter()
        sessions = set()

        self.stdout.write(f'[export_session_summary] sessions started {date_from} .. {date_to} ({options["tz"]})')
        self.stdout.write(f'[export_session_summary] shared detection block matches {MESSAGE_LOG_SQL_FILE.name}')

        with transaction.atomic():
            with connection.cursor() as cur:
                open_read_only(cur, options['statement_timeout'], self.stdout, 'export_session_summary')
                preflight(cur, settings_sql, self.stdout, self.style)

            named = raw_conn.cursor(name='saathi_session_summary_export')
            named.itersize = options['batch_size']
            named.execute(query)
            batch = named.fetchmany(options['batch_size'])
            header = [col[0] for col in named.description]
            with open(out_path, 'w', newline='', encoding='utf-8-sig' if options['bom'] else 'utf-8') as fh:
                writer = csv.writer(fh)
                writer.writerow(header)
                while batch:
                    for row in batch:
                        self._count(dict(zip(header, row)), stats, stage_counts, sessions)
                        writer.writerow(['' if v is None else v for v in row])
                    batch = named.fetchmany(options['batch_size'])
            named.close()

            with connection.cursor() as cur:
                cur.execute(diagnostics_query)
                onb_via_row, onb_via_history, goal_sel_gap, obj_sel_gap = cur.fetchone()
            # Nothing is ever written, but make the intent explicit: always roll back.
            transaction.set_rollback(True)

        self.stdout.write('[export_session_summary] done')
        self.stdout.write(f'  rows written        : {stats["rows"]}')
        self.stdout.write(f'  sessions            : {len(sessions)}')
        self.stdout.write(f'  row types           : MIP={stats["mip"]} onboarding={stats["onboarding"]} '
                          f'no-MIP={stats["no_mip"]} (zero-message sessions: {stats["empty"]})')
        self.stdout.write(f'  Session _Stage      : {dict(stage_counts)}')
        self.stdout.write(f'  onboarding completed: {onb_via_row} via the profile_extracted row, '
                          f'{onb_via_history} via profile history')
        if goal_sel_gap or obj_sel_gap:
            self.stdout.write(self.style.WARNING(
                f'  ! selected row not directly before its stage row: goal={goal_sel_gap} objective={obj_sel_gap} '
                f'MIP(s) — review those sessions (the last user message before the stage was used)'))
        self.stdout.write(f'  written to          : {os.path.abspath(out_path)}')

    @staticmethod
    def _count(record, stats, stage_counts, sessions):
        stats['rows'] += 1
        sessions.add(record[SESSION_COL])
        labels = [label for label in (record[STAGE_COL] or '').split(', ') if label]
        stage_counts.update(labels)
        if ONBOARDING_LABEL in labels:
            stats['onboarding'] += 1
        elif record[MIP_COL]:
            stats['mip'] += 1
        else:
            stats['no_mip'] += 1
        if not record['user_turn_count'] and not record['saathi_turn_count']:
            stats['empty'] += 1
