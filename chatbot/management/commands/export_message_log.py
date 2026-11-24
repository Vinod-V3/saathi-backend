"""
Django management command to export the Saathi "Message Log" reporting sheet as CSV.

The extraction logic lives in chatbot/scripts/reporting/message_log.sql (the same
file can be pasted into pgAdmin / Metabase). This command only fills in the
SETTINGS values from the CLI, runs the query inside a READ ONLY transaction that is
always rolled back, and streams the rows to a CSV file.

Usage:
    python manage.py export_message_log --from 2026-10-01 --to 2026-10-31 --out message_log.csv
    python manage.py export_message_log --from 2026-10-01 --to 2026-10-31 --tz Asia/Kolkata \
        --exclude-users TEST_QA01,TEST_QA02 --out message_log.csv

Optional LLM labelling (disabled by default, makes external calls to the LLM gateway):
    --labels llm           LLM labels for every message (hard-signal labels are kept)
    --labels llm-fallback  LLM only for rows the rules left as Answer / Clarification
"""

import csv
import hashlib
import json
import os
from collections import Counter
from pathlib import Path

from django.core.management.base import BaseCommand, CommandError
from django.db import connection, transaction

from ._reporting_common import (
    REPORTING_DIR, apply_settings, guard_read_only, open_read_only, parse_date, parse_list, preflight, settings_cte,
)

SQL_FILE = REPORTING_DIR / 'message_log.sql'

SAATHI_COL = 'saathi_response_type'
USER_COL = 'user_response_type'
FLOW_COL = 'session_flow_type'
SPEAKER_COL = 'speaker'
SESSION_COL = 'session_id'
SEQ_COL = 'Chat_sequence(optional)'
STAGE_COL = 'conversation_stage'

# Labels that come from hard signals (tools / config) — never overridden by the LLM.
HARD_LABELS = {
    'Technical error / no response', 'Unable to understand / answer', 'MIP Downloaded',
    'Content download', 'Onboarding captured',
}
SAATHI_LLM_LABELS = [
    'Answer / solution', 'Clarification question', 'Goal generated', 'Objectives generated',
    'Action steps generated', 'MIP generated', 'Out of scope rejection', 'Unable to understand / answer',
]
USER_LLM_LABELS = ['User Query', 'User Response', 'Greeting / casual']
FLOW_LLM_LABELS = ['KQ', 'MIP', 'Both', '']
FALLBACK_REPLACEABLE = {'Answer / solution', 'Clarification question'}
FALLBACK_ACCEPTED = {
    'Goal generated', 'Objectives generated', 'Action steps generated', 'MIP generated', 'Out of scope rejection',
}
STAGE_LABEL_KEYS = {
    'Goal generated': 'goal', 'Objectives generated': 'objectives', 'Action steps generated': 'action_steps',
    'MIP generated': 'plan', 'MIP Downloaded': 'download',
}

LLM_SYSTEM_PROMPT = """You label chat transcripts between a teacher (USER) and Saathi, an education assistant.
Saathi has two flows: Knowledge Query (KQ: answering education questions) and Micro-Improvement Plan
(MIP: diagnostic questions -> goal -> objectives -> action steps -> compiled plan -> download).

Label every line of the transcript. Each line looks like "[<seq>] USER: ..." or "[<seq>] SAATHI: ...".
SAATHI labels: %(saathi)s
USER labels: %(user)s
Session flow: KQ (only knowledge answers), MIP (a plan flow), Both (a plan flow plus knowledge answers
outside it), or "" (only greetings / errors).

Reply with JSON only, no prose:
{"messages": [{"seq": <int>, "label": "<label>"}, ...], "session_flow_type": "<KQ|MIP|Both|>"}"""


class Command(BaseCommand):
    help = 'Exports the Saathi Message Log reporting sheet to CSV (strictly read-only).'

    def add_arguments(self, parser):
        parser.add_argument('--from', dest='date_from', required=True,
                            help='First day (YYYY-MM-DD) of session start, inclusive, in --tz.')
        parser.add_argument('--to', dest='date_to', required=True,
                            help='Last day (YYYY-MM-DD) of session start, inclusive, in --tz.')
        parser.add_argument('--out', required=True, help='Output CSV path.')
        parser.add_argument('--tz', default='UTC', help="Timezone for dates and timestamps (default UTC, e.g. 'Asia/Kolkata').")
        parser.add_argument('--exclude-users', default='', help='Comma-separated user ids to leave out.')
        parser.add_argument('--include-only', default='', help='Comma-separated user ids to keep (default: everyone).')
        parser.add_argument('--labels', choices=['rules', 'llm', 'llm-fallback'], default='rules',
                            help='Label source. Default "rules" makes no external calls.')
        parser.add_argument('--llm-bot-route', default=None,
                            help='CompanyBot route whose gateway provider/model is used for --labels llm*.')
        parser.add_argument('--llm-cache', default=None, help='LLM label cache file (default: <out>.llm_cache.json).')
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
        query = guard_read_only(sql_text)
        settings_sql = settings_cte(sql_text)

        use_llm = options['labels'] != 'rules'
        out_path = Path(options['out'])
        stats = Counter()
        label_counts = {SAATHI_COL: Counter(), USER_COL: Counter()}
        flow_by_session = {}
        rows_for_llm = []

        self.stdout.write(f'[export_message_log] sessions started {date_from} .. {date_to} ({options["tz"]}), '
                          f'labels={options["labels"]}')

        with transaction.atomic():
            with connection.cursor() as cur:
                open_read_only(cur, options['statement_timeout'], self.stdout, 'export_message_log')
                checks = preflight(cur, settings_sql, self.stdout, self.style)

            llm_bot = self._pick_llm_bot(options['llm_bot_route'], checks) if use_llm else None

            named = raw_conn.cursor(name='saathi_message_log_export')
            named.itersize = options['batch_size']
            named.execute(query)
            first = named.fetchmany(options['batch_size'])
            header = [col[0] for col in named.description]

            if use_llm:
                batch = first
                while batch:
                    rows_for_llm.extend(dict(zip(header, row)) for row in batch)
                    batch = named.fetchmany(options['batch_size'])
            else:
                with open(out_path, 'w', newline='', encoding='utf-8-sig' if options['bom'] else 'utf-8') as fh:
                    writer = csv.writer(fh)
                    writer.writerow(header)
                    batch = first
                    while batch:
                        for row in batch:
                            record = dict(zip(header, row))
                            self._count(record, stats, label_counts, flow_by_session, checks)
                            writer.writerow(['' if v is None else v for v in row])
                        batch = named.fetchmany(options['batch_size'])
            named.close()
            # Nothing is ever written, but make the intent explicit: always roll back.
            transaction.set_rollback(True)

        if use_llm:
            # LLM calls happen after the read-only transaction is closed.
            cache_path = Path(options['llm_cache'] or f'{out_path}.llm_cache.json')
            self._apply_llm_labels(rows_for_llm, options['labels'], llm_bot, cache_path, stats)
            with open(out_path, 'w', newline='', encoding='utf-8-sig' if options['bom'] else 'utf-8') as fh:
                writer = csv.writer(fh)
                writer.writerow(header)
                for record in rows_for_llm:
                    self._count(record, stats, label_counts, flow_by_session, checks)
                    writer.writerow(['' if record[col] is None else record[col] for col in header])

        self._report(out_path, stats, label_counts, flow_by_session)

    # ------------------------------------------------------------------ reporting

    def _count(self, record, stats, label_counts, flow_by_session, preflight):
        stats['rows'] += 1
        session = record[SESSION_COL]
        if session not in flow_by_session:
            flow_by_session[session] = {'flow': record[FLOW_COL], 'stage': record[STAGE_COL], 'stages': []}
        if record[SAATHI_COL]:
            label_counts[SAATHI_COL][record[SAATHI_COL]] += 1
        if record[USER_COL]:
            label_counts[USER_COL][record[USER_COL]] += 1
        stage_key = STAGE_LABEL_KEYS.get(record[SAATHI_COL] or '')
        if stage_key in preflight['stage_order']:
            flow_by_session[session]['stages'].append(preflight['stage_order'].index(stage_key) + 1)

    def _report(self, out_path, stats, label_counts, flow_by_session):
        # Out-of-order: a stage whose rank drops below the previous stage without a new opening stage.
        out_of_order = 0
        for info in flow_by_session.values():
            previous = 0
            for rank in info['stages']:
                if rank != 1 and rank < previous:
                    out_of_order += 1
                previous = rank
        flows = Counter(info['flow'] or '(blank)' for info in flow_by_session.values())

        self.stdout.write('[export_message_log] done')
        self.stdout.write(f'  rows written        : {stats["rows"]}')
        self.stdout.write(f'  sessions            : {len(flow_by_session)}')
        self.stdout.write(f'  session_flow_type   : {dict(flows)}')
        self.stdout.write(f'  saathi_response_type: {dict(label_counts[SAATHI_COL])}')
        self.stdout.write(f'  user_response_type  : {dict(label_counts[USER_COL])}')
        if stats['llm_sessions'] or stats['llm_failures']:
            self.stdout.write(f'  llm labelled        : {stats["llm_sessions"]} sessions '
                              f'({stats["llm_cached"]} from cache, {stats["llm_failures"]} failed)')
        if out_of_order:
            self.stdout.write(self.style.WARNING(
                f'  ! {out_of_order} stage(s) appeared out of the configured stage_order — '
                f'if the MIP flow order changed, update stage_order in the SETTINGS block'))
        self.stdout.write(f'  written to          : {os.path.abspath(out_path)}')

    # ------------------------------------------------------------------ optional LLM labels

    def _pick_llm_bot(self, route, preflight):
        from chatbot.models import CompanyBot

        if not route:
            conversation = [r for r in preflight['session_mix']
                            if r[0] != preflight['onboarding_type'] and r[1] != '(none)']
            if not conversation:
                raise CommandError('--labels llm*: no conversation bot found in range; pass --llm-bot-route')
            route = conversation[0][1]
        bot = CompanyBot.objects.filter(route=route).first()
        if not bot or not bot.gateway_provider:
            raise CommandError(f'--labels llm*: bot {route!r} not found or has no gateway provider')
        self.stdout.write(f'  llm labels via bot  : {route} ({bot.gateway_provider} / {bot.gateway_model})')
        return bot

    def _apply_llm_labels(self, records, mode, bot, cache_path, stats):
        from chatbot.llm_models.llm_gateway import build_gateway_params, call_llm_gateway, get_effective_provider_model

        cache = {}
        if cache_path.exists():
            cache = json.loads(cache_path.read_text(encoding='utf-8'))
        provider, model = get_effective_provider_model(bot)
        params = build_gateway_params(bot)
        params['temperature'] = 0
        params['max_tokens'] = max(params.get('max_tokens') or 0, 4000)
        system_prompt = LLM_SYSTEM_PROMPT % {'saathi': ' | '.join(SAATHI_LLM_LABELS),
                                             'user': ' | '.join(USER_LLM_LABELS)}

        sessions = {}
        for record in records:
            sessions.setdefault(record[SESSION_COL], []).append(record)

        for session, rows in sessions.items():
            if rows[0][STAGE_COL] == 'Onboarding':
                continue
            transcript = '\n'.join(
                f"[{r[SEQ_COL]}] {r[SPEAKER_COL].upper()}: "
                f"{(r['user/saathi_message_translated'] or r['user/saathi_message_original'] or '')[:1200]}"
                for r in rows
            )
            key = hashlib.sha256(f'{model}\n{transcript}'.encode('utf-8')).hexdigest()
            result = cache.get(key)
            if result is not None:
                stats['llm_cached'] += 1
            else:
                response = call_llm_gateway(
                    messages=[{'role': 'system', 'content': system_prompt}, {'role': 'user', 'content': transcript}],
                    provider=provider, model=model, params=params,
                )
                result = self._parse_llm_json(response)
                if result is None:
                    stats['llm_failures'] += 1
                    continue
                cache[key] = result
                cache_path.write_text(json.dumps(cache, ensure_ascii=False), encoding='utf-8')
            stats['llm_sessions'] += 1
            self._merge_llm_result(rows, result, mode)

    @staticmethod
    def _parse_llm_json(response):
        if not response:
            return None
        try:
            content = response['choices'][0]['message']['content'] or ''
            start, end = content.find('{'), content.rfind('}')
            parsed = json.loads(content[start:end + 1])
            return parsed if isinstance(parsed.get('messages'), list) else None
        except (KeyError, IndexError, TypeError, ValueError, AttributeError):
            return None

    @staticmethod
    def _merge_llm_result(rows, result, mode):
        by_seq = {}
        for item in result.get('messages', []):
            try:
                by_seq[int(item.get('seq'))] = item.get('label')
            except (TypeError, ValueError):
                continue

        for row in rows:
            label = by_seq.get(int(row[SEQ_COL]))
            if row[SPEAKER_COL] == 'Saathi':
                current = row[SAATHI_COL]
                if label not in SAATHI_LLM_LABELS or current in HARD_LABELS:
                    continue
                if mode == 'llm' or (current in FALLBACK_REPLACEABLE and label in FALLBACK_ACCEPTED):
                    row[SAATHI_COL] = label
            elif mode == 'llm' and label in USER_LLM_LABELS:
                row[USER_COL] = label

        flow = result.get('session_flow_type')
        if flow in FLOW_LLM_LABELS:
            current_flow = rows[0][FLOW_COL]
            if mode == 'llm' or (current_flow in (None, '', 'KQ') and flow in ('MIP', 'Both')):
                for row in rows:
                    row[FLOW_COL] = flow or None
