-- =============================================================================
-- Saathi reporting: SESSION SUMMARY  (one row per MIP; one row per session
-- without a MIP; onboarding sessions are their own rows)
-- =============================================================================
-- READ-ONLY. This file is a single WITH ... SELECT statement. It never writes.
--
-- How to run:
--   * pgAdmin Query Tool / psql : paste the whole file and run it. For an extra
--     safety net you may uncomment the BEGIN line below and the ROLLBACK line at
--     the very end (the database then refuses any write for this run).
--   * Metabase native question  : paste everything from "WITH settings AS" down
--     to the final ORDER BY (leave the BEGIN / ROLLBACK lines commented out).
--   * Server (SSH)               : python manage.py export_session_summary --help
--     (runs this same file, read-only, and writes a CSV).
--
-- Edit ONLY the SETTINGS block. Everything below it is the extraction logic.
-- Sessions are selected by their START time (all messages of those sessions are
-- included, even ones after date_to). Dates are inclusive, in the tz setting.
--
-- The block between the SHARED DETECTION markers is a copy of the same block in
-- message_log.sql (the Message Log's detection rules). Change detection there,
-- then copy the block here; export_session_summary refuses to run until both
-- blocks match. Columns and rules: chatbot/scripts/reporting/README.md.
-- =============================================================================

-- BEGIN TRANSACTION READ ONLY;

-- ===== SHARED DETECTION START (keep identical in message_log.sql and session_summary.sql) =====
WITH settings AS (
    -- ===== SETTINGS START: edit values here only =====
    SELECT
        CAST('2026-10-01' AS date)        AS date_from,             -- sessions started on/after this day
        CAST('2026-11-01' AS date)        AS date_to,               -- ... up to and including this day
        CAST('UTC' AS text)               AS tz,                    -- e.g. 'Asia/Kolkata' for IST
        CAST(ARRAY[] AS text[])           AS exclude_user_ids,      -- e.g. ARRAY['TEST_QA01','12345']
        CAST(ARRAY[] AS text[])           AS include_only_user_ids, -- empty = everyone
        CAST(1 AS bigint)                 AS ai_profile_id,         -- Profile id of the "AI" (Saathi) sender
        CAST('saathi_profile' AS text)    AS onboarding_session_type,
        CAST(3 AS int)                    AS max_diag_questions,    -- prompt caps diagnostic questions at 3
        CAST(120 AS int)                  AS answer_min_chars,      -- text before a closing "?" at least this long = an answer with a follow-up, not a clarification
        -- MIP stage order. The first entry opens a MIP. Used only to accept stages
        -- found by message SHAPE; stages found by PHRASE are accepted in any order.
        ARRAY['goal', 'objectives', 'action_steps', 'plan', 'download'] AS stage_order,
        -- Phrase patterns: case-insensitive regular expressions, matched on the
        -- English text of Saathi messages. Add synonyms here if the prompt changes.
        ARRAY[
            'here is your goal',
            'here''s (the|your) goal',
            'goal (i''ve|i have) (drafted|written|created|framed)',
            'goal for (this|your|the) plan'
        ] AS goal_patterns,
        ARRAY[
            '\m(three|3|four|4|five|5|six|6) (smart )?objectives\M',
            'objectives? to choose from',
            '\mobjective options\M',
            'options for (your |the )?objectives?'
        ] AS objective_patterns,
        ARRAY[
            'here are (your|the) ([a-z-]+ )?action steps',
            'action steps (for|to) (your|this|the) ',
            'confirm (these|the) (action )?steps'
        ] AS action_steps_patterns,
        ARRAY[
            'here is your (micro[- ]?)?improvement plan',
            'i''ve compiled everything',
            '(^|\n)[[:space:]*#]*(micro[- ]?)?improvement plan[[:space:]*#:]*(\n|$)'
        ] AS plan_patterns,
        ARRAY[
            'i''m set up to help with education',
            'outside (of )?what i can help',
            'outside (of )?my scope'
        ] AS out_of_scope_patterns,
        ARRAY[
            'I am sorry, I could not understood completely. Could you rephrase this please?'
        ] AS unable_texts,
        -- Saathi questions that invite a NEW topic; the user's next message is a User Query.
        ARRAY[
            'how (else )?can i help',
            'what would you like help with',
            'what (else )?(would you like|can i help you) to work on',
            'anything else (you would|you''d|i can)',
            'another (school )?challenge',
            'what (challenge|question) can i help'
        ] AS invite_patterns,
        CAST('^mip' AS text)              AS mip_download_name_pattern, -- download.file_name of MIP files
        -- Greeting / small-talk words (always "Greeting / casual"); checked on the
        -- English text and on the original text, so native words work too.
        ARRAY[
            'hi+', 'hello+', 'helo', 'hey+', 'hai', 'hi there', 'hello there', 'hey there',
            'namaste', 'namaskar(am)?', 'vanakkam', 'good (morning|afternoon|evening|night)',
            'thanks?', 'thank you( (so|very) much)?', 'thx', 'bye', 'good ?bye',
            'नमस्ते', 'नमस्कार', 'धन्यवाद', 'ನಮಸ್ಕಾರ', 'ಧನ್ಯವಾದ', 'வணக்கம்', 'நன்றி',
            'నమస్కారం', 'ధన్యవాదాలు', 'ନମସ୍କାର', 'ଧନ୍ୟବାଦ'
        ] AS greeting_words,
        -- Casual words: "Greeting / casual" only when NOT answering a Saathi question.
        ARRAY['ok', 'okay', 'okk+', 'cool', 'nice', 'great', 'fine'] AS casual_words
    -- ===== SETTINGS END =====
),

-- Sessions started inside the date range, with the session owner's user id.
sess AS (
    SELECT cs.id AS session_pk, cs.session, cs.language, cs.session_type,
           cs.created_at AS session_created_at,
           COALESCE(p.userid, cs.user_id) AS session_user_id
    FROM chatbot_chatsession cs
    CROSS JOIN settings st
    LEFT JOIN chatbot_profile p ON p.id = cs.profile_id
    WHERE cs.created_at >= (st.date_from::timestamp AT TIME ZONE st.tz)
      AND cs.created_at <  ((st.date_to + 1)::timestamp AT TIME ZONE st.tz)
      AND (cardinality(st.include_only_user_ids) = 0
           OR COALESCE(COALESCE(p.userid, cs.user_id) = ANY (st.include_only_user_ids), false))
      AND NOT COALESCE(COALESCE(p.userid, cs.user_id) = ANY (st.exclude_user_ids), false)
),

-- Configured technical-error texts, in every language.
err AS (
    SELECT DISTINCT btrim(error_message) AS txt
    FROM shikshalokam.bot_vernacular
    WHERE COALESCE(btrim(error_message), '') <> ''
),

-- One row per message. en_text = the English version of the message.
msgs AS (
    SELECT c.id AS chat_id, c.session, s.language, s.session_type, s.session_created_at, s.session_user_id,
           c.created_at,
           (c.sender_id = st.ai_profile_id) AS is_saathi,
           CASE WHEN c.sender_id = st.ai_profile_id THEN c.receiver_id ELSE c.sender_id END AS user_profile_id,
           c.message, c.translated_message, c.file_url, c.chunks,
           CASE WHEN jsonb_typeof(c.other_params -> 'extra_content') = 'object'
                THEN c.other_params -> 'extra_content' END AS xc,
           CASE WHEN c.sender_id = st.ai_profile_id THEN c.message
                ELSE COALESCE(NULLIF(btrim(c.translated_message), ''), c.message) END AS en_text,
           ROW_NUMBER() OVER (PARTITION BY c.session ORDER BY c.created_at, c.id) AS seq
    FROM chatbot_companychat c
    JOIN sess s ON s.session = c.session
    CROSS JOIN settings st
),

-- Layer 1 (hard signals) and Layer 2 (message shape) features.
feat AS (
    SELECT m.*,
           lower(btrim(COALESCE(m.en_text, ''))) AS t,
           COALESCE(jsonb_typeof(m.xc -> 'quick_reply_chips') = 'array'
                    AND jsonb_array_length(m.xc -> 'quick_reply_chips') > 0, false) AS has_chips,
           CASE WHEN jsonb_typeof(m.xc -> 'quick_reply_chips') = 'array' THEN m.xc -> 'quick_reply_chips' END AS chips,
           (COALESCE(jsonb_typeof(m.xc -> 'sources') = 'array' AND jsonb_array_length(m.xc -> 'sources') > 0, false)
            OR COALESCE(btrim(m.chunks), '') NOT IN ('', '[]', 'null')) AS has_sources,
           (m.is_saathi AND COALESCE(m.xc ? 'download', false)) AS is_download,
           COALESCE(m.xc -> 'download' ->> 'file_name', '') AS download_name,
           (m.is_saathi AND COALESCE(m.xc ->> 'profile_extracted', '') = 'true') AS is_onboarding_captured,
           (m.is_saathi AND (btrim(m.message) IN (SELECT txt FROM err)
                             OR btrim(COALESCE(m.translated_message, '')) IN (SELECT txt FROM err))) AS is_error,
           (m.is_saathi AND btrim(COALESCE(m.message, '')) = ANY (st.unable_texts)) AS is_unable,
           (m.is_saathi AND lower(btrim(COALESCE(m.en_text, ''))) ~* ANY (st.out_of_scope_patterns)) AS is_out_of_scope,
           (NOT m.is_saathi
            AND (lower(btrim(COALESCE(m.en_text, ''))) ~* ('^[^a-z0-9]*(' || array_to_string(st.greeting_words, '|') || ')[^a-z0-9]*$')
                 OR lower(btrim(COALESCE(m.message, ''))) ~* ('^[^a-z0-9]*(' || array_to_string(st.greeting_words, '|') || ')[^a-z0-9]*$'))
           ) AS is_greeting,
           (m.is_saathi AND lower(btrim(COALESCE(m.en_text, ''))) ~* ANY (st.invite_patterns)) AS is_invite,
           (btrim(COALESCE(m.en_text, '')) ~ '\?[^[:alnum:]]{0,8}$') AS is_question,
           -- length of the text before the closing question sentence
           length(btrim(regexp_replace(btrim(COALESCE(m.en_text, '')), '[^.!?\n]*\?[^[:alnum:]]*$', ''))) AS pre_question_len,
           (SELECT count(*) FROM regexp_matches(COALESCE(m.en_text, ''),
                '(^|\n)[[:space:]*#>-]*(objective|option)[[:space:]]*[0-9]+', 'gi')) AS n_objective_lines,
           (SELECT count(*) FROM regexp_matches(COALESCE(m.en_text, ''),
                '(^|\n)[[:space:]*#>-]*[0-9]+[.)][[:space:]]', 'g')) AS n_numbered_lines,
           (COALESCE(m.en_text, '') ~* '(^|\n)[[:space:]*#]*goal[[:space:]*]*:') AS has_goal_line,
           (COALESCE(m.en_text, '') ~* '(^|\n)[[:space:]*#]*objectives?[[:space:]*]*:') AS has_objective_line,
           (COALESCE(m.en_text, '') ~* '(^|\n)[[:space:]*#]*(action plan|action steps|success indicators)') AS has_plan_section
    FROM msgs m
    CROSS JOIN settings st
),

-- Layer 3 (phrases) + Layer 2 (shape) stage candidates for Saathi rows.
cand AS (
    SELECT f.*,
           -- a real clarification: ends with "?" and has little text before it
           (f.is_question AND f.pre_question_len < st.answer_min_chars) AS is_clarification,
           CASE WHEN NOT f.is_saathi OR f.is_error OR f.is_unable OR f.is_out_of_scope
                     OR f.is_download OR f.is_onboarding_captured THEN NULL
                WHEN f.t ~* ANY (st.plan_patterns)         THEN 'plan'
                WHEN f.t ~* ANY (st.action_steps_patterns) THEN 'action_steps'
                WHEN f.t ~* ANY (st.objective_patterns)    THEN 'objectives'
                WHEN f.t ~* ANY (st.goal_patterns)         THEN 'goal'
           END AS phrase_stage,
           CASE WHEN NOT f.is_saathi OR f.is_error OR f.is_unable OR f.is_out_of_scope
                     OR f.is_download OR f.is_onboarding_captured THEN NULL
                WHEN f.has_goal_line AND f.has_objective_line AND f.has_plan_section THEN 'plan'
                WHEN f.n_objective_lines >= 2
                     OR COALESCE(f.chips::text ~* '"(objective|option) *[0-9]', false) THEN 'objectives'
                WHEN f.n_numbered_lines >= 3 AND (f.has_sources OR f.has_chips) THEN 'action_steps'
                WHEN f.is_question AND (f.has_goal_line OR COALESCE(f.chips::text ~* 'confirm[^"]*goal', false)) THEN 'goal'
           END AS shape_stage
    FROM feat f
    CROSS JOIN settings st
),

cand2 AS (
    SELECT c.*,
           COALESCE(c.phrase_stage, c.shape_stage) AS cand_stage,
           array_position(st.stage_order, COALESCE(c.phrase_stage, c.shape_stage)) AS cand_rank,
           (c.phrase_stage IS NOT NULL) AS by_phrase
    FROM cand c
    CROSS JOIN settings st
),

-- Goal groups: each row of the opening stage (rank 1) starts a new group.
grp0 AS (
    SELECT c.*,
           SUM(CASE WHEN c.cand_rank = 1 THEN 1 ELSE 0 END)
               OVER (PARTITION BY c.session ORDER BY c.seq) AS goal_grp,
           CASE WHEN c.by_phrase OR c.cand_rank = 1 THEN c.cand_rank END AS acc0
    FROM cand2 c
),

-- Shape-only stages are accepted when an earlier stage of the same group allows
-- them (stage order). Three passes let a chain of shape-only stages propagate.
pass1 AS (
    SELECT g.*,
           CASE WHEN g.acc0 IS NOT NULL THEN g.acc0
                WHEN g.cand_rank IS NOT NULL AND g.goal_grp > 0
                     AND COALESCE(MAX(g.acc0) OVER w, 0) >= g.cand_rank - 1 THEN g.cand_rank
           END AS acc1
    FROM grp0 g
    WINDOW w AS (PARTITION BY g.session, g.goal_grp ORDER BY g.seq ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
),
pass2 AS (
    SELECT p.*,
           CASE WHEN p.acc0 IS NOT NULL THEN p.acc0
                WHEN p.cand_rank IS NOT NULL AND p.goal_grp > 0
                     AND COALESCE(MAX(p.acc1) OVER w, 0) >= p.cand_rank - 1 THEN p.cand_rank
           END AS acc2
    FROM pass1 p
    WINDOW w AS (PARTITION BY p.session, p.goal_grp ORDER BY p.seq ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
),
pass3 AS (
    SELECT p.*,
           CASE WHEN p.acc0 IS NOT NULL THEN p.acc0
                WHEN p.cand_rank IS NOT NULL AND p.goal_grp > 0
                     AND COALESCE(MAX(p.acc2) OVER w, 0) >= p.cand_rank - 1 THEN p.cand_rank
           END AS acc3,
           COALESCE(MAX(p.acc2) OVER w, 0) AS prev_max,
           COUNT(*) FILTER (WHERE p.is_download) OVER w AS prev_downloads
    FROM pass2 p
    WINDOW w AS (PARTITION BY p.session, p.goal_grp ORDER BY p.seq ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
),

-- Final stage per row. A download is an MIP download when its file name says so,
-- when it is the first download inside a MIP, or when it repeats the file name of
-- an earlier MIP download in the session (the plan sent again).
dl0 AS (
    SELECT p.*,
           (p.is_download AND (p.download_name ~* st.mip_download_name_pattern
                               OR (p.goal_grp > 0 AND p.prev_max >= 1 AND p.prev_downloads = 0))) AS is_mip_download0
    FROM pass3 p
    CROSS JOIN settings st
),
dl AS (
    SELECT d.*,
           (d.is_mip_download0
            OR (d.is_download AND d.download_name <> ''
                AND bool_or(d.is_mip_download0) OVER (PARTITION BY d.session, d.download_name ORDER BY d.seq))) AS is_mip_download
    FROM dl0 d
),
staged AS (
    SELECT d.*,
           CASE WHEN d.is_mip_download THEN 'download'
                WHEN d.acc3 IS NOT NULL THEN d.cand_stage END AS stage,
           CASE WHEN d.is_mip_download THEN array_position(st.stage_order, 'download')
                ELSE d.acc3 END AS stage_rank
    FROM dl d
    CROSS JOIN settings st
),

-- MIP numbering: a goal group starts a new MIP unless the previous group never
-- got past the opening stage (i.e. it was a corrected / re-stated goal).
grp_stats AS (
    SELECT session, goal_grp, MAX(stage_rank) AS grp_max
    FROM staged
    GROUP BY session, goal_grp
    HAVING MAX(stage_rank) IS NOT NULL
),
grp_mip AS (
    SELECT g.session, g.goal_grp,
           SUM(CASE WHEN g.prev_grp_max IS NULL OR g.prev_grp_max >= 2 THEN 1 ELSE 0 END)
               OVER (PARTITION BY g.session ORDER BY g.goal_grp) AS mip_index
    FROM (SELECT gs.*, LAG(gs.grp_max) OVER (PARTITION BY gs.session ORDER BY gs.goal_grp) AS prev_grp_max
          FROM grp_stats gs) g
),
rows_mip AS (
    SELECT s.*, gm.mip_index,
           -- diagnostic-question runs: a Saathi row that is not a clarification breaks the run
           SUM(CASE WHEN s.is_saathi AND (NOT s.is_clarification OR s.stage IS NOT NULL OR s.is_error) THEN 1 ELSE 0 END)
               OVER (PARTITION BY s.session ORDER BY s.seq) AS run_no
    FROM staged s
    LEFT JOIN grp_mip gm ON gm.session = s.session AND gm.goal_grp = s.goal_grp
),

-- Per MIP: first and last stage rows.
mip AS (
    SELECT session, mip_index,
           MIN(seq) FILTER (WHERE stage IS NOT NULL) AS first_stage_seq,
           MAX(seq) FILTER (WHERE stage IS NOT NULL) AS last_stage_seq
    FROM rows_mip
    WHERE mip_index IS NOT NULL
    GROUP BY session, mip_index
),
-- Diagnostic questions = the run of Saathi question rows just before the MIP's
-- first stage row (last max_diag_questions of them). If some carry chips, the
-- run starts at the first chip-bearing one.
diag AS (
    SELECT x.session, x.mip_index,
           COALESCE(MIN(x.seq) FILTER (WHERE x.has_chips), MIN(x.seq)) AS first_diag_seq
    FROM (SELECT r.session, mp.mip_index, r.seq, r.has_chips,
                 ROW_NUMBER() OVER (PARTITION BY r.session, mp.mip_index ORDER BY r.seq DESC) AS back_no
          FROM mip mp
          JOIN rows_mip f ON f.session = mp.session AND f.seq = mp.first_stage_seq
          JOIN rows_mip r ON r.session = mp.session AND r.seq < mp.first_stage_seq
                         AND r.is_saathi AND r.run_no = f.run_no - 1
                         AND r.is_clarification AND r.stage IS NULL AND NOT r.is_error) x
    CROSS JOIN settings st
    WHERE x.back_no <= st.max_diag_questions
    GROUP BY x.session, x.mip_index
),
mip_seg AS (
    SELECT mp.session, mp.mip_index, mp.last_stage_seq,
           COALESCE((SELECT MAX(u.seq) FROM rows_mip u
                     WHERE u.session = mp.session AND NOT u.is_saathi
                       AND u.seq < COALESCE(d.first_diag_seq, mp.first_stage_seq)),
                    mp.first_stage_seq) AS asked_seq
    FROM mip mp
    LEFT JOIN diag d ON d.session = mp.session AND d.mip_index = mp.mip_index
),

-- Response labels.
labeled AS (
    SELECT r.*,
           LAG(r.is_saathi) OVER w AS prev_is_saathi,
           LAG(r.created_at) OVER w AS prev_created_at,
           LAG(r.is_question) OVER w AS prev_is_question,
           LAG(r.stage) OVER w AS prev_stage,
           LAG(r.chips) OVER w AS prev_chips,
           LAG(r.is_greeting, 2) OVER w AS prev2_is_greeting,
           LAG(r.is_error OR r.is_unable OR r.is_out_of_scope OR r.is_invite) OVER w AS prev_invites_query,
           LEAD(r.is_saathi) OVER w AS next_is_saathi
    FROM rows_mip r
    WINDOW w AS (PARTITION BY r.session ORDER BY r.seq)
),
labeled2 AS (
    SELECT l.*,
           CASE
               WHEN l.is_saathi THEN
                   CASE WHEN l.is_error                 THEN 'Technical error / no response'
                        WHEN l.is_unable                THEN 'Unable to understand / answer'
                        WHEN l.is_out_of_scope          THEN 'Out of scope rejection'
                        WHEN l.is_mip_download          THEN 'MIP Downloaded'
                        WHEN l.is_download              THEN 'Content download'
                        WHEN l.stage = 'plan'           THEN 'MIP generated'
                        WHEN l.stage = 'action_steps'   THEN 'Action steps generated'
                        WHEN l.stage = 'objectives'     THEN 'Objectives generated'
                        WHEN l.stage = 'goal'           THEN 'Goal generated'
                        WHEN l.is_onboarding_captured   THEN 'Onboarding captured'
                        WHEN l.is_clarification         THEN 'Clarification question'
                        ELSE 'Answer / solution'
                   END
               WHEN COALESCE(l.next_is_saathi, false) = false THEN 'Technical error / no response'
           END AS saathi_response_type,
           CASE
               WHEN l.is_saathi THEN NULL
               WHEN COALESCE(l.prev_is_saathi, false) AND jsonb_typeof(l.prev_chips) = 'array'
                    AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(l.prev_chips) ch
                                WHERE regexp_replace(lower(btrim(ch)), '[[:space:][:punct:]]+$', '')
                                      = regexp_replace(l.t, '[[:space:][:punct:]]+$', ''))
                    THEN 'User Response'
               WHEN l.is_greeting THEN 'Greeting / casual'
               -- Saathi's reply to a greeting ("Hi! How can I help?") invites a new query
               WHEN COALESCE(l.prev_is_saathi, false) AND COALESCE(l.prev2_is_greeting, false) THEN 'User Query'
               -- after a rejection, an error, "please rephrase" or "anything else?", the user asks anew
               WHEN COALESCE(l.prev_is_saathi, false) AND COALESCE(l.prev_invites_query, false) THEN 'User Query'
               -- a download closes the MIP, so it does not make the next message a response
               WHEN COALESCE(l.prev_is_saathi, false)
                    AND (COALESCE(l.prev_is_question, false) OR COALESCE(l.prev_stage <> 'download', false))
                    THEN 'User Response'
               WHEN l.t ~* ('^[^a-z0-9]*(' || array_to_string(st.casual_words, '|') || ')[^a-z0-9]*$')
                    THEN 'Greeting / casual'
               ELSE 'User Query'
           END AS user_response_type
    FROM labeled l
    CROSS JOIN settings st
),

-- Session flow type: MIP if >= 1 MIP; KQ if Saathi answered a real query outside
-- every MIP segment; Both if both. Blank for onboarding sessions.
-- KQ evidence rows: a Saathi answer to a real query, outside every MIP segment.
kq_ev AS (
    SELECT a.session, a.seq
    FROM labeled2 a
    JOIN labeled2 u ON u.session = a.session AND u.seq = a.seq - 1 AND NOT u.is_saathi
    WHERE a.is_saathi
      AND a.saathi_response_type IN ('Answer / solution', 'Content download')
      AND u.user_response_type IN ('User Query', 'User Response')
      AND NOT EXISTS (SELECT 1 FROM mip_seg ms
                      WHERE ms.session = a.session AND a.seq BETWEEN ms.asked_seq AND ms.last_stage_seq)
),
kq_rows AS (
    SELECT DISTINCT session FROM kq_ev
),
flow AS (
    SELECT s.session,
           CASE WHEN s.session_type = st.onboarding_session_type THEN NULL
                WHEN m.n_mips > 0 AND k.session IS NOT NULL THEN 'Both'
                WHEN m.n_mips > 0 THEN 'MIP'
                WHEN k.session IS NOT NULL THEN 'KQ'
           END AS session_flow_type
    FROM sess s
    CROSS JOIN settings st
    LEFT JOIN (SELECT session, MAX(mip_index) AS n_mips FROM rows_mip GROUP BY session) m ON m.session = s.session
    LEFT JOIN kq_rows k ON k.session = s.session
)
-- ===== SHARED DETECTION END =====
,

-- Session span: first / last message (zero-message sessions keep created_at as start).
sess_span AS (
    SELECT s.session, s.session_pk, s.session_type, s.session_created_at, s.session_user_id,
           MIN(r.created_at) AS first_at, MAX(r.created_at) AS last_at, MAX(r.seq) AS max_seq
    FROM sess s
    LEFT JOIN labeled2 r ON r.session = s.session
    GROUP BY s.session, s.session_pk, s.session_type, s.session_created_at, s.session_user_id
),

-- Per MIP: the first row of each stage (seq numbers). Onboarding sessions never get MIP rows.
mip_ms AS (
    SELECT ms.session, ms.mip_index, ms.asked_seq, ms.last_stage_seq,
           MIN(r.seq) FILTER (WHERE r.stage = 'goal')         AS goal_seq,
           MIN(r.seq) FILTER (WHERE r.stage = 'objectives')   AS obj_seq,
           MIN(r.seq) FILTER (WHERE r.stage = 'action_steps') AS steps_seq,
           MIN(r.seq) FILTER (WHERE r.stage = 'plan')         AS plan_seq,
           MIN(r.seq) FILTER (WHERE r.is_mip_download)        AS dl_seq
    FROM mip_seg ms
    JOIN sess s ON s.session = ms.session
    JOIN labeled2 r ON r.session = ms.session AND r.mip_index = ms.mip_index
    CROSS JOIN settings st
    WHERE s.session_type IS DISTINCT FROM st.onboarding_session_type
    GROUP BY ms.session, ms.mip_index, ms.asked_seq, ms.last_stage_seq
),
-- Selected goal / objective = the last user row before the first objectives /
-- action-steps row. Generated/downloaded = the first MIP download, else the first plan.
mip_sel AS (
    SELECT m.*,
           (SELECT MAX(u.seq) FROM labeled2 u
            WHERE u.session = m.session AND NOT u.is_saathi
              AND u.seq > m.goal_seq AND u.seq < m.obj_seq)                           AS goal_sel_seq,
           (SELECT MAX(u.seq) FROM labeled2 u
            WHERE u.session = m.session AND NOT u.is_saathi
              AND u.seq > COALESCE(m.obj_seq, m.goal_seq) AND u.seq < m.steps_seq)    AS obj_sel_seq,
           COALESCE(m.dl_seq, m.plan_seq)                                             AS done_seq,
           ROW_NUMBER() OVER (PARTITION BY m.session ORDER BY m.mip_index)            AS mip_no
    FROM mip_ms m
),

-- Slices: MIP row 1 starts at the session's first message, MIP row k at MIP k's
-- asked query (kept after MIP k-1's last stage row); each slice ends just before
-- the next one. A session without a MIP is a single slice.
slice0 AS (
    SELECT m.session, m.mip_no,
           CASE WHEN m.mip_no = 1 THEN 1
                ELSE GREATEST(m.asked_seq,
                              LAG(m.last_stage_seq) OVER (PARTITION BY m.session ORDER BY m.mip_no) + 1)
           END AS slice_from
    FROM mip_sel m
),
slices AS (
    SELECT sp.session, s0.mip_no,
           COALESCE(s0.slice_from, 1) AS slice_from,
           COALESCE(LEAD(s0.slice_from) OVER (PARTITION BY sp.session ORDER BY s0.mip_no) - 1,
                    sp.max_seq) AS slice_to
    FROM sess_span sp
    LEFT JOIN slice0 s0 ON s0.session = sp.session
),
-- Per slice: turn counts, conversation span, and whether a KQ answer falls in it.
slice_agg AS (
    SELECT sl.session, sl.mip_no,
           COUNT(r.seq) FILTER (WHERE NOT r.is_saathi)          AS user_turns,
           COUNT(r.seq) FILTER (WHERE r.is_saathi)              AS saathi_turns,
           MIN(r.created_at) FILTER (WHERE NOT r.is_saathi)     AS conv_from,
           MAX(r.created_at)                                    AS conv_to,
           COALESCE(bool_or(k.seq IS NOT NULL), false)          AS has_kq
    FROM slices sl
    LEFT JOIN labeled2 r ON r.session = sl.session AND r.seq BETWEEN sl.slice_from AND sl.slice_to
    LEFT JOIN kq_ev k ON k.session = r.session AND k.seq = r.seq
    GROUP BY sl.session, sl.mip_no
),

-- Onboarding sessions: started = first message; completed = the profile_extracted
-- row, else the first profile-history time the flag became true (only while the
-- profile still says onboarded, and only between this session's start and the
-- user's next session).
onb AS (
    SELECT x.session, x.onb_from,
           COALESCE(x.captured_at, x.history_at) AS onb_done,
           CASE WHEN x.captured_at IS NOT NULL THEN 'row'
                WHEN x.history_at IS NOT NULL THEN 'history' END AS onb_src
    FROM (
        SELECT sp.session,
               COALESCE(sp.first_at, sp.session_created_at) AS onb_from,
               (SELECT MIN(r.created_at) FROM labeled2 r
                WHERE r.session = sp.session AND r.is_onboarding_captured) AS captured_at,
               (SELECT MIN(h.history_date)
                FROM chatbot_historicalprofile h
                WHERE h.id = cs.profile_id
                  AND lower(COALESCE(h.other_params ->> 'is_onboarding_completed', '')) = 'true'
                  AND lower(COALESCE(p.other_params ->> 'is_onboarding_completed', '')) = 'true'
                  AND h.history_date >= sp.session_created_at
                  AND h.history_date < COALESCE(
                          (SELECT MIN(nx.created_at) FROM chatbot_chatsession nx
                           WHERE nx.profile_id = cs.profile_id AND nx.created_at > cs.created_at),
                          'infinity'::timestamptz)) AS history_at
        FROM sess_span sp
        JOIN chatbot_chatsession cs ON cs.id = sp.session_pk
        LEFT JOIN chatbot_profile p ON p.id = cs.profile_id
        CROSS JOIN settings st
        WHERE sp.session_type = st.onboarding_session_type
    ) x
),

-- One output row per slice, with every timestamp still a timestamptz.
ss_rows AS (
    SELECT sp.session_created_at, sp.session, sa.mip_no,
           sp.session_user_id, sp.session_pk, sp.session_type,
           (sp.session_type = st.onboarding_session_type) AS is_onboarding,
           COALESCE(sp.first_at, sp.session_created_at) AS session_from,
           sp.last_at AS session_to,
           o.onb_from, o.onb_done,
           sa.conv_from, CASE WHEN sa.conv_from IS NOT NULL THEN sa.conv_to END AS conv_to,
           ra.created_at AS asked_at, rg.created_at AS goal_at, rgs.created_at AS goal_sel_at,
           ro.created_at AS obj_at, ros.created_at AS obj_sel_at, rd.created_at AS done_at,
           ms.steps_seq, ms.plan_seq, ms.dl_seq, sa.has_kq,
           sa.user_turns, sa.saathi_turns
    FROM sess_span sp
    CROSS JOIN settings st
    JOIN slice_agg sa ON sa.session = sp.session
    LEFT JOIN mip_sel ms ON ms.session = sa.session AND ms.mip_no = sa.mip_no
    LEFT JOIN onb o ON o.session = sp.session
    LEFT JOIN labeled2 ra  ON ra.session  = ms.session AND ra.seq  = ms.asked_seq
    LEFT JOIN labeled2 rg  ON rg.session  = ms.session AND rg.seq  = ms.goal_seq
    LEFT JOIN labeled2 rgs ON rgs.session = ms.session AND rgs.seq = ms.goal_sel_seq
    LEFT JOIN labeled2 ro  ON ro.session  = ms.session AND ro.seq  = ms.obj_seq
    LEFT JOIN labeled2 ros ON ros.session = ms.session AND ros.seq = ms.obj_sel_seq
    LEFT JOIN labeled2 rd  ON rd.session  = ms.session AND rd.seq  = ms.done_seq
)
-- ===== FINAL SELECT =====

SELECT
    r.session_user_id                                                     AS "user_id",
    CAST(NULL AS text)                                                    AS "user_name",
    r.session                                                             AS "session_id",
    r.session_pk                                                          AS "chat_id",
    fx.f[1]                                                               AS "session_start_timestamp",
    fx.f[2]                                                               AS "session_end_timestamp",
    round(CAST(EXTRACT(EPOCH FROM (r.session_to - r.session_from)) AS numeric), 3)
                                                                          AS "session_duration_seconds",
    NULLIF(concat_ws(', ',
        CASE WHEN r.is_onboarding THEN 'Onboarding' END,
        CASE WHEN r.goal_at IS NOT NULL THEN 'MIP - Goal generated' END,
        CASE WHEN r.obj_at IS NOT NULL THEN 'MIP - Objective generated' END,
        CASE WHEN r.steps_seq IS NOT NULL THEN 'MIP - Action steps generated' END,
        CASE WHEN r.plan_seq IS NOT NULL THEN 'MIP generated' END,
        CASE WHEN r.dl_seq IS NOT NULL THEN 'MIP Downloaded' END,
        CASE WHEN r.has_kq AND NOT r.is_onboarding THEN 'Knowledge query' END), '')
                                                                          AS "Session _Stage ",
    fx.f[3]                                                               AS "Onboarding_started_timestamp",
    fx.f[4]                                                               AS "Onboarding_completed_timestamp",
    round(CAST(EXTRACT(EPOCH FROM (r.onb_done - r.onb_from)) AS numeric), 3)
                                                                          AS "Onboarding_duration_seconds",
    CASE WHEN NOT r.is_onboarding THEN fx.f[5] END                        AS "Converation_started_timestamp",
    CASE WHEN NOT r.is_onboarding THEN fx.f[6] END                        AS "Converation_ENDED_timestamp",
    CASE WHEN NOT r.is_onboarding
         THEN round(CAST(EXTRACT(EPOCH FROM (r.conv_to - r.conv_from)) AS numeric), 3) END
                                                                          AS "Conversation_duration_seconds",
    fx.f[7]                                                               AS "MIP_user asked query_timestamp",
    fx.f[8]                                                               AS "MIP_Goal_generated_timestamp",
    round(CAST(EXTRACT(EPOCH FROM (r.goal_at - r.asked_at)) AS numeric), 3)
                                                                          AS "MIP_saathi_Goal_generated_seconds",
    fx.f[9]                                                               AS "MIP_user selected goal_timestamp",
    fx.f[10]                                                              AS "MIP_saathi_objective_generated_timestamp",
    round(CAST(EXTRACT(EPOCH FROM (r.obj_at - r.asked_at)) AS numeric), 3)
                                                                          AS "MIP_objective_generated_seconds",
    fx.f[11]                                                              AS "MIP_user selected objective_timestamp",
    fx.f[12]                                                              AS "MIP_saathi_generated/downloaded_timestamp",
    round(CAST(EXTRACT(EPOCH FROM (r.done_at - r.asked_at)) AS numeric), 3)
                                                                          AS "MIP_generated/downloaded_seconds",
    r.user_turns                                                          AS "user_turn_count",
    r.saathi_turns                                                        AS "saathi_turn_count"
FROM ss_rows r
CROSS JOIN settings st
-- Format every timestamp the same way as the Message Log (ISO-8601 in tz, with offset).
CROSS JOIN LATERAL (
    SELECT array_agg(
               CASE WHEN u.v IS NULL THEN NULL
                    ELSE to_char(u.v AT TIME ZONE st.tz, 'YYYY-MM-DD"T"HH24:MI:SS')
                         || CASE WHEN (u.v AT TIME ZONE st.tz) = (u.v AT TIME ZONE 'UTC') THEN 'Z'
                                 WHEN (u.v AT TIME ZONE st.tz) < (u.v AT TIME ZONE 'UTC')
                                 THEN '-' || to_char((u.v AT TIME ZONE 'UTC') - (u.v AT TIME ZONE st.tz), 'HH24:MI')
                                 ELSE '+' || to_char((u.v AT TIME ZONE st.tz) - (u.v AT TIME ZONE 'UTC'), 'HH24:MI')
                            END
               END ORDER BY u.ord) AS f
    FROM unnest(ARRAY[r.session_from, r.session_to,                      -- 1, 2
                      r.onb_from, r.onb_done,                            -- 3, 4
                      r.conv_from, r.conv_to,                            -- 5, 6
                      r.asked_at, r.goal_at, r.goal_sel_at,              -- 7, 8, 9
                      r.obj_at, r.obj_sel_at, r.done_at])                -- 10, 11, 12
         WITH ORDINALITY AS u(v, ord)
) fx
ORDER BY r.session_created_at, r.session, r.mip_no NULLS FIRST;

-- ROLLBACK;
