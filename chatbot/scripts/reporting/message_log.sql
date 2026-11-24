-- =============================================================================
-- Saathi reporting: MESSAGE LOG  (one row per chat message)
-- =============================================================================
-- READ-ONLY. This file is a single WITH ... SELECT statement. It never writes.
--
-- How to run:
--   * pgAdmin Query Tool / psql : paste the whole file and run it. For an extra
--     safety net you may uncomment the BEGIN line below and the ROLLBACK line at
--     the very end (the database then refuses any write for this run).
--   * Metabase native question  : paste everything from "WITH settings AS" down
--     to the final ORDER BY (leave the BEGIN / ROLLBACK lines commented out).
--   * Server (SSH)               : python manage.py export_message_log --help
--     (runs this same file, read-only, and writes a CSV).
--
-- Edit ONLY the SETTINGS block. Everything below it is the extraction logic.
-- Sessions are selected by their START time (all messages of those sessions are
-- included, even ones after date_to). Dates are inclusive, in the tz setting.
--
-- Column-by-column logic and the detection rules are described in
-- chatbot/scripts/reporting/README.md.
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

SELECT
    COALESCE(up.userid, r.session_user_id)                                AS "user_id",
    CAST(NULL AS text)                                                    AS "user_name",
    CAST(NULL AS text)                                                    AS "Profile_ Status ",
    CAST(NULL AS text)                                                    AS "mapping_status",
    CAST(NULL AS text)                                                    AS "User_type /role",
    CAST(NULL AS text)                                                    AS "State name ",
    CAST(NULL AS text)                                                    AS "District name ",
    CASE lower(r.language)
        WHEN 'en' THEN 'English'  WHEN 'hi' THEN 'Hindi'    WHEN 'kn' THEN 'Kannada'
        WHEN 'ta' THEN 'Tamil'    WHEN 'te' THEN 'Telugu'   WHEN 'or' THEN 'Odia'
        WHEN 'mr' THEN 'Marathi'  WHEN 'bn' THEN 'Bengali'  WHEN 'gu' THEN 'Gujarati'
        WHEN 'ml' THEN 'Malayalam' WHEN 'pa' THEN 'Punjabi' WHEN 'as' THEN 'Assamese'
        WHEN 'ur' THEN 'Urdu'
        ELSE r.language
    END                                                                   AS "user_selected_language",
    r.session                                                             AS "session_id",
    r.chat_id                                                             AS "chat_id",
    r.seq                                                                 AS "Chat_sequence(optional)",
    to_char(r.created_at AT TIME ZONE st.tz, 'YYYY-MM-DD"T"HH24:MI:SS')
        || CASE WHEN tzo.off = interval '0' THEN 'Z'
                WHEN tzo.off < interval '0' THEN '-' || to_char(-tzo.off, 'HH24:MI')
                ELSE '+' || to_char(tzo.off, 'HH24:MI') END               AS "Chat_timestamp_utc",
    CASE WHEN r.is_saathi THEN 'Saathi' ELSE 'User' END                   AS "speaker",
    CASE WHEN r.session_type = st.onboarding_session_type
         THEN 'Onboarding' ELSE 'Conversation' END                        AS "conversation_stage",
    CASE WHEN r.is_saathi THEN COALESCE(NULLIF(r.translated_message, ''), r.message)
         ELSE r.message END                                               AS "user/saathi_message_original",
    CASE WHEN lower(r.language) = 'en' OR COALESCE(r.translated_message, '') = '' THEN NULL
         WHEN r.is_saathi THEN r.message
         ELSE r.translated_message END                                    AS "user/saathi_message_translated",
    r.saathi_response_type                                                AS "saathi_response_type",
    r.user_response_type                                                  AS "user_response_type",
    fl.session_flow_type                                                  AS "session_flow_type",
    CASE WHEN r.is_saathi THEN NULL
         WHEN COALESCE(btrim(r.file_url), '') <> '' THEN 'Voice'
         ELSE 'Text' END                                                  AS "input_mode",
    CASE WHEN r.is_saathi AND r.prev_is_saathi = false
         THEN round(CAST(EXTRACT(EPOCH FROM (r.created_at - r.prev_created_at)) AS numeric), 3) END
                                                                          AS "latency_seconds"
FROM labeled2 r
CROSS JOIN settings st
CROSS JOIN LATERAL (SELECT (r.created_at AT TIME ZONE st.tz) - (r.created_at AT TIME ZONE 'UTC') AS off) tzo
LEFT JOIN chatbot_profile up ON up.id = r.user_profile_id
LEFT JOIN flow fl ON fl.session = r.session
ORDER BY r.session_created_at, r.session, r.seq;

-- ROLLBACK;
