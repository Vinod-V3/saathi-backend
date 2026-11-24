# Saathi reporting extracts

Read-only exports of Saathi chat data for the reporting sheets.

| Sheet | Raw SQL | Command |
|---|---|---|
| Message Log (one row per message) | `message_log.sql` | `python manage.py export_message_log` |
| Session Summary (one row per MIP; one row per session without a MIP; onboarding sessions are their own rows) | `session_summary.sql` | `python manage.py export_session_summary` |

Nothing here writes to the database:
- **The SQL file** is a single `WITH … SELECT`.
- **The command** runs it inside a `READ ONLY` transaction, with a statement timeout, and always rolls back. It also refuses any SQL that isn't a single SELECT.

## Running it

### On a server (SSH)

From the `saathi-backend` folder:

```bash
python manage.py export_message_log --from 2026-10-01 --to 2026-10-31 --out /tmp/message_log.csv
```

If the backend runs in Docker:

```bash
docker exec <backend-container> python manage.py export_message_log --from 2026-10-01 --to 2026-10-31 --out /tmp/message_log.csv
docker cp <backend-container>:/tmp/message_log.csv .
```

Options:

| Option | Meaning |
|---|---|
| `--from`, `--to` | Session **start** dates, both inclusive. A session that started in the range is exported with **all** its messages, even ones sent after `--to`. |
| `--tz` | Timezone for the dates and the timestamps. Default `UTC`; for example `Asia/Kolkata`. The column header keeps the sheet's name `Chat_timestamp_utc`, so rename that header cell in the sheet if you switch. |
| `--exclude-users a,b` / `--include-only a,b` | Filter by `user_id`. The default includes everyone. |
| `--bom` | Adds a UTF-8 BOM so Excel shows Indic scripts correctly. Google Sheets doesn't need it. |
| `--labels rules` | The default. Uses the detection rules only; **makes no external calls**. |
| `--labels llm` / `--labels llm-fallback` | Optional and off by default. Asks the LLM gateway (same `LLM_GATEWAY_*` env as the backend) to label each conversation. Results are cached in `<out>.llm_cache.json`. This sends transcripts to the LLM provider and costs tokens. `llm-fallback` only replaces rows the rules left as Answer / Clarification. |

`export_session_summary` takes the same options except `--labels` (it has no LLM layer):

```bash
python manage.py export_session_summary --from 2026-10-01 --to 2026-10-31 --out /tmp/session_summary.csv
```

The two commands are independent: run either one on its own. `export_session_summary` only *reads* `message_log.sql` as text to check that the shared detection block is the same (see "Keeping the two SQL files in sync").

Before extracting, each command prints a **preflight**. It uses read-only queries on the same DB and makes no external calls:
- the AI profile;
- sessions and messages in the range;
- the bot `stream` flag;
- whether each phrase-pattern group still appears in the bot prompt. A warning means the prompt wording may have changed (see "Detection rules").

After extracting, it prints label counts (Session Summary: row types, Session _Stage counts, how onboarding completion was found, and a warning when a "selected" row isn't directly before its stage row).

### pgAdmin

1. Open the Query Tool and paste the whole `message_log.sql` (or `session_summary.sql`).
2. Edit the SETTINGS block.
3. Run it.
4. Export with the result grid's "Save results to file" (CSV).

Optional extra safety: uncomment `BEGIN TRANSACTION READ ONLY;` at the top and `ROLLBACK;` at the end.

### Metabase

Create a native SQL question and paste from `WITH settings AS (` down to the final `ORDER BY …;`, leaving the BEGIN / ROLLBACK lines commented out. Edit the SETTINGS block, run it, and download the results as CSV.

## The SETTINGS block

All settings live at the top of each SQL file, and that is the only place to edit. Both files have the same SETTINGS block:
- **Date range, `tz`, user filters:** the values the command fills in from its options.
- **`ai_profile_id`:** the Profile id that sends Saathi messages (`1`).
- **`onboarding_session_type`:** `saathi_profile`.
- **`stage_order`:** the MIP stage order.
- **`answer_min_chars`** (120): a Saathi message ending in "?" is a Clarification question only when the text before that last question is shorter than this. Longer ones are answers that end with a follow-up offer ("Here are some tips … Would you like more?").
- **Phrase patterns, invite patterns, greeting words, casual words:** change these when the bot prompt wording changes.

Each command reads its own file, so editing a file updates both the pasted query and its command.

## Keeping the two SQL files in sync

`session_summary.sql` reuses the Message Log's detection rules. The lines between these two markers are the same in both files:

```
-- ===== SHARED DETECTION START (keep identical in message_log.sql and session_summary.sql) =====
...  SETTINGS block and every detection CTE, up to `flow`  ...
-- ===== SHARED DETECTION END =====
```

- **To change detection** (a phrase pattern, a setting such as `answer_min_chars`, a rule): edit the block in `message_log.sql`, then copy the whole block into `session_summary.sql`.
- **`export_session_summary` refuses to run while the blocks differ** and names the first differing line. That way the two sheets can't silently disagree; for example, a new goal phrase added to one file only would make a Message Log row "Goal generated" with no goal in the Session Summary.
- The date range, `tz` and the user lists don't count as differences: the command fills them in from its options in both texts before comparing.
- In pgAdmin or Metabase, editing the SETTINGS values (dates, `tz`, users) in your pasted copy is fine. The check runs only in the command, so it can't catch an old copy that is already pasted somewhere.

## Columns (Message Log)

| Column | How it is filled |
|---|---|
| user_id | `chatbot_profile.userid` of the user in the chat (falls back to `chatbot_chatsession.user_id`) |
| user_name, Profile_ Status, mapping_status, User_type /role, State name, District name | blank: these come from the user service, keyed by `user_id` |
| user_selected_language | `chatbot_chatsession.language` (the session's latest language) |
| session_id / chat_id / Chat_sequence | `chatsession.session` / `companychat.id` / message order within the session |
| Chat_timestamp_utc | message time in `tz`, ISO-8601 |
| speaker | `Saathi` when the sender is the AI profile, else `User` |
| conversation_stage | `Onboarding` for `saathi_profile` sessions, else `Conversation` |
| user/saathi_message_original | the text in the language the user saw |
| user/saathi_message_translated | the English text. Blank for English sessions. |
| saathi_response_type / user_response_type / session_flow_type | detection rules below |
| input_mode | `Voice` when the user message has a recording URL (`file_url`), else `Text` |
| latency_seconds | Saathi message time minus the user message just before it. It includes translation time. |

## Detection rules

The database stores no "stage" field, so labels are worked out from the messages. Every rule runs on the English text: Saathi's `message` is always English, the user's English is in `translated_message`, and chips are stored in English. So all languages behave the same.

1. **Hard signals** (from tools or config, not wording):
   - **Onboarding captured:** `extra_content.profile_extracted`.
   - **MIP Downloaded / Content download:** `extra_content.download`. A download counts as an MIP when the file name starts with `MIP`, when it is the first one inside a MIP, or when it repeats the file name of an earlier MIP download in the session (the plan sent again).
   - **Technical error:** the text equals any `bot_vernacular.error_message`.
   - **Unable to understand:** the backend's default reply.
   - **No response:** a user message with no Saathi reply after it.
2. **Message shape:** chips, knowledge-base sources, ending in a question, numbered or "Objective N" lines, and plan sections (Goal / Objective / Action Plan / Success Indicators).
3. **Phrase patterns** from the SETTINGS block, e.g. "here is your goal".

**How a MIP stage is accepted:**
- A stage counts when either its phrase **or** its shape matches.
- A phrase match is accepted in any order. A shape-only match must follow the previous stage in `stage_order` within the same MIP.
- A new MIP starts at a goal that comes after a MIP that had reached objectives or later. Repeated goals before objectives are corrections of the same MIP.

**user_response_type:**
- **User Response:** the text equals a chip from Saathi's previous message, or it answers a Saathi question or stage offer (a download is not an offer: it closes the MIP).
- **Greeting / casual:** a greeting word, or a casual word that isn't answering a question.
- **User Query:** anything else. These also count as a User Query:
  - a message right after Saathi's reply to a greeting;
  - a message right after an out-of-scope rejection, an error or "please rephrase";
  - a message right after a Saathi question matching `invite_patterns` ("Anything else you'd like to work on?").

**session_flow_type:**
- **MIP:** at least one MIP.
- **KQ:** Saathi answered a real query outside every MIP.
- **Both:** both of the above.
- Blank for onboarding sessions, or sessions with only greetings or errors.

## Columns (Session Summary)

**Rows.**
- One row per MIP.
- A conversation with no MIP gives one row with blank MIP columns.
- Each onboarding session (`saathi_profile`) is its own row.
- A session with no messages still gives one row: the start (`created_at`), turn counts 0 / 0, everything else blank.

**Slices (sessions with several MIPs).**
- Each MIP row covers one slice of the session. Row 1 starts at the session's first message; row k starts at MIP k's asked query. Each slice ends just before the next one, and the last one ends at the session's last message.
- Turn counts, the Conversation columns and "Knowledge query" come from the row's slice, so they add up to the session totals.
- Example, s27 (two MIPs, 28 messages): row 1 = messages 1–14 (7 user / 7 Saathi), row 2 = messages 15–28 (7 / 7).
- Rows with no MIP, and onboarding rows, have one slice: the whole session.

| Column | How it is filled |
|---|---|
| user_id | as in the Message Log |
| user_name | blank: from the user service, keyed by `user_id` |
| session_id / chat_id | `chatsession.session` / `chatsession.id` |
| session_start / end / duration | first / last message of the session; the same on every row of the session |
| Session _Stage | stages reached, fixed order, joined with ", ": `Onboarding`, `MIP - Goal generated`, `MIP - Objective generated`, `MIP - Action steps generated`, `MIP generated`, `MIP Downloaded`, `Knowledge query`. A MIP row lists only its own MIP's stages; `Knowledge query` = a KQ answer (the Message Log's KQ evidence) in the row's slice. |
| Onboarding_started / completed / duration | onboarding rows only: first message / the Saathi row with `profile_extracted` (fallback: the first profile-history time `is_onboarding_completed` became true, used only while the profile still says onboarded and only between this session's start and the user's next session) / the difference. Blank on conversation rows. |
| Converation_started / ENDED / duration | the slice's first user message (any kind, greetings included) / its last message / the difference. Blank on onboarding rows. |
| MIP_user asked query | the user message just before Saathi's diagnostic questions (the Message Log's MIP segment start) |
| MIP_Goal_generated / _seconds | the MIP's first Goal generated row / minus the asked query |
| MIP_user selected goal | the last user message before the first Objectives generated row |
| MIP_saathi_objective_generated / _seconds | the first Objectives generated row / minus the asked query |
| MIP_user selected objective | the last user message before the first Action steps generated row (blank if there is none) |
| MIP_saathi_generated/downloaded / _seconds | the MIP's first MIP Downloaded row, else its first MIP generated row / minus the asked query. Session _Stage shows which happened. Content downloads never count. |
| user_turn_count / saathi_turn_count | user / Saathi messages in the slice |

Timestamps use the same format as the Message Log (ISO-8601 in `tz`). `_seconds` are computed from the exact times, to 3 decimals. When a MIP is abandoned, its later milestones are blank.

## Known limits

- **App merges at save time.** When two messages from the same sender are saved back to back, the app overwrites the earlier row (`save_in_company_db`). Those texts were never stored, so they can't be exported.
- **Not stored at all:** the intro message and PDF download clicks.
- **Language** is per session and holds its latest value.
- **A MIP abandoned right after the goal, followed by a new goal,** counts as one MIP (the second goal is treated as a corrected goal). This is the Message Log's rule.
- **Selected goal / objective** is the last user message before the next stage. If Saathi asked another question after the user confirmed, the answer to that question is used. The command warns when this happens.
