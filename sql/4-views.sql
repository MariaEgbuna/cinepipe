-- ╔══════════════════════════════════════════════════════════════╗
-- ║  watchlogs.v_binge_patterns                                  ║
-- ║  Which days of the week you start my binges                  ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  READS FROM    series_log, series_metadata, dates_table      ║
-- ║  ONE ROW PER   day of the week                               ║
-- ║  SHOWS         binge count, average length, average season   ║
-- ║                size, hours per session, share of all binges  ║
-- ║  NOTE          Only seasons logged with the Binge watch type ║
-- ║                are counted.                                  ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE VIEW watchlogs.v_binge_patterns AS
WITH session_metrics AS (
    SELECT 
        dt.day_short,
        dt.day_of_week_index,
        sm.avg_runtime,
        sl.total_episodes,
        GREATEST(COALESCE(sl.end_date, sl.start_date) - sl.start_date + 1, 1) AS span_days
    FROM watchlogs.series_log AS sl
    INNER JOIN public.dates_table AS dt ON sl.start_date = dt.date_key
    INNER JOIN registry.series_metadata AS sm ON sl.series_id = sm.series_id
    WHERE sl.watch_type = 'Binge'
)
SELECT 
    day_short,
    COUNT(*) AS binge_count,
    ROUND(AVG(span_days)::NUMERIC, 2) AS avg_binge_span,
    ROUND(AVG(avg_runtime)::NUMERIC, 2) AS avg_ep_length,
    ROUND(AVG(total_episodes)::NUMERIC, 2) AS avg_season_size,
    ROUND((AVG(avg_runtime) * AVG(total_episodes)) / 60.0, 1) AS avg_hours_per_session,
    ROUND((COUNT(*)::NUMERIC * 100.0) / SUM(COUNT(*)) OVER (), 1) AS share_pct
FROM session_metrics
GROUP BY day_short, day_of_week_index
ORDER BY day_of_week_index;

COMMENT ON VIEW watchlogs.v_binge_patterns IS 'Which days of the week you start my binges';

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  watchlogs.v_rewatch_rating_changes                          ║
-- ║  How the rating changed with each movie rewatch              ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  READS FROM    movie_log, movie_metadata                     ║
-- ║  ONE ROW PER   movie rewatch (rated or dropped)              ║
-- ║  SHOWS         old rating (last rated log before), new       ║
-- ║                rating, change, and a verdict                 ║
-- ║  SORTED BY     title, then year released, then rewatch       ║
-- ║                number                                        ║
-- ║  OLD WATCH     Names the log the old rating came from:       ║
-- ║                Original Watch, Rewatch 1, Rewatch 2 and so   ║
-- ║                on, or Original (Not Logged) if there is no   ║
-- ║                earlier rated log.                            ║
-- ║  NOTE          Dropped rewatches show up with no new rating  ║
-- ║                and a verdict of "Dropped".                   ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE VIEW watchlogs.v_rewatch_rating_changes AS
WITH numbered AS (
    SELECT
        movie_id,
        log_id,
        rating,
        is_rewatch,
        -- Is this a rewatch that should appear in the view? (rated or dropped)
        (is_rewatch IS TRUE AND (rating IS NOT NULL OR watch_status = 'Dropped')) AS is_kept,
        -- Running count of kept rewatches for this movie, in log order.
        -- The original watch gets 0, the first kept rewatch gets 1, and so on.
        COUNT(*) FILTER (
            WHERE is_rewatch IS TRUE AND (rating IS NOT NULL OR watch_status = 'Dropped')
        ) OVER (PARTITION BY movie_id ORDER BY log_id) AS rewatch_no
    FROM watchlogs.movie_log
)
SELECT
    mm.movie_code,
    mm.title,
    mm.year_released,
    r.rewatch_no,
    CASE
        -- No earlier rated log at all
        WHEN prev.log_id IS NULL THEN 'Original (Not Logged)'
        -- The old rating came from an earlier rewatch: name it by its number
        WHEN prev.is_rewatch IS TRUE THEN 'Rewatch ' || prev.rewatch_no
        -- Otherwise it came from the original watch
        ELSE 'Original Watch'
    END AS old_watch,
    prev.rating AS old_rating,
    r.rating AS new_rating,
    ROUND((r.rating - prev.rating)::NUMERIC, 1) AS change,
    CASE
        -- A kept rewatch with no rating can only be a dropped one
        WHEN r.rating IS NULL THEN 'Dropped'
        WHEN prev.rating IS NULL THEN 'No Rating To Compare'
        WHEN r.rating > prev.rating THEN 'Went Up'
        WHEN r.rating < prev.rating THEN 'Went Down'
        ELSE 'No Change'
    END AS verdict
FROM numbered r
INNER JOIN registry.movie_metadata mm ON mm.movie_id = r.movie_id
-- For each row, find the most recent earlier log of the same movie that has a rating
LEFT JOIN LATERAL (
    SELECT p.log_id, p.rating, p.is_rewatch, p.rewatch_no
    FROM numbered p
    WHERE p.movie_id = r.movie_id
      AND p.log_id < r.log_id
      AND p.rating IS NOT NULL
    ORDER BY p.log_id DESC
    LIMIT 1
) prev ON TRUE
-- Show only the kept rewatches (the original watches were only needed for lookback)
WHERE r.is_kept
-- Default sort: title A to Z, then year (remakes), then rewatch order
ORDER BY mm.title, mm.year_released, r.rewatch_no;

COMMENT ON VIEW watchlogs.v_rewatch_rating_changes IS 'How the rating changed with each movie rewatch, including dropped rewatches';

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  watchlogs.v_season_rating_changes                           ║
-- ║  How the rating changed with each rewatch of a season        ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  READS FROM    series_log, series_metadata                   ║
-- ║  ONE ROW PER   season rewatch (rated or dropped)             ║
-- ║  SHOWS         old rating (last rated log before), new       ║
-- ║                rating, change, and a verdict                 ║
-- ║  SORTED BY     title, then season number, then rewatch       ║
-- ║                number                                        ║
-- ║  OLD WATCH     Names the log the old rating came from:       ║
-- ║                Original Watch, Rewatch 1, Rewatch 2 and so   ║
-- ║                on, or Original (Not Logged) if the season    ║
-- ║                was watched before logging started.           ║
-- ║  NOTE          Each season is tracked on its own, so Season 1║
-- ║                is never mixed with Season 2. Dropped         ║
-- ║                rewatches show up with no new rating and a    ║
-- ║                verdict of "Dropped".                         ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE VIEW watchlogs.v_season_rating_changes AS
WITH numbered AS (
    SELECT
        series_id,
        season_no,
        log_id,
        rating,
        is_rewatch,
        -- Is this a rewatch that should appear in the view? (rated or dropped)
        (is_rewatch AND (rating IS NOT NULL OR watch_status = 'Dropped')) AS is_kept,
        -- Running count of kept rewatches for this season, in log order.
        -- The original watch gets 0, the first kept rewatch gets 1, and so on.
        COUNT(*) FILTER (
            WHERE is_rewatch AND (rating IS NOT NULL OR watch_status = 'Dropped')
        ) OVER (PARTITION BY series_id, season_no ORDER BY log_id) AS rewatch_no
    FROM watchlogs.series_log
)
SELECT
    sm.series_code,
    sm.title,
    r.season_no,
    r.rewatch_no,
    CASE
        -- No earlier rated log: was the season watched before logging began?
        WHEN prev.log_id IS NULL AND r.season_no <= COALESCE(sm.seasons_pre_log, 0) THEN 'Original (Not Logged)'
        WHEN prev.log_id IS NULL THEN 'None'
        -- The old rating came from an earlier rewatch: name it by its number
        WHEN prev.is_rewatch THEN 'Rewatch ' || prev.rewatch_no
        -- Otherwise it came from the original watch
        ELSE 'Original Watch'
    END AS old_watch,
    prev.rating AS old_rating,
    r.rating AS new_rating,
    ROUND((r.rating - prev.rating)::NUMERIC, 1) AS change,
    CASE
        -- A kept rewatch with no rating can only be a dropped one
        WHEN r.rating IS NULL THEN 'Dropped'
        WHEN prev.rating IS NULL AND r.season_no <= COALESCE(sm.seasons_pre_log, 0) THEN 'No Rating To Compare'
        WHEN prev.rating IS NULL THEN 'No Earlier Log'
        WHEN r.rating > prev.rating THEN 'Went Up'
        WHEN r.rating < prev.rating THEN 'Went Down'
        ELSE 'No Change'
    END AS verdict
FROM numbered r
INNER JOIN registry.series_metadata sm ON sm.series_id = r.series_id
-- For each row, find the most recent earlier log of the same season that has a rating
LEFT JOIN LATERAL (
    SELECT p.log_id, p.rating, p.is_rewatch, p.rewatch_no
    FROM numbered p
    WHERE p.series_id = r.series_id
      AND p.season_no = r.season_no
      AND p.log_id < r.log_id
      AND p.rating IS NOT NULL
    ORDER BY p.log_id DESC
    LIMIT 1
) prev ON TRUE
-- Show only the kept rewatches (the original watches were only needed for lookback)
WHERE r.is_kept
-- Default sort: title A to Z, then season, then rewatch order
ORDER BY sm.title, r.season_no, r.rewatch_no;

COMMENT ON VIEW watchlogs.v_season_rating_changes IS 'How my rating changed with each rewatch of a season, including dropped rewatches';

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  watchlogs.v_series_rating_changes                           ║
-- ║  Did you like a series more or less after rewatching it?     ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  READS FROM    v_season_rating_changes                       ║
-- ║  ONE ROW PER   series                                        ║
-- ║  SHOWS         seasons compared, old and new average, change,║
-- ║                verdict                                       ║
-- ║  SORTED BY     title                                         ║
-- ║  NOTE          Create v_season_rating_changes first. For each║
-- ║                season it compares the rating before my       ║
-- ║                first rated rewatch with my latest rated      ║
-- ║                rewatch. Dropped rewatches are ignored. A     ║
-- ║                season is skipped unless it has two real      ║
-- ║                ratings to compare.                           ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE VIEW watchlogs.v_series_rating_changes AS
WITH rated AS (
    -- Keep only rewatches that have a rating (this removes dropped ones)
    SELECT
        series_code,
        title,
        season_no,
        rewatch_no,
        old_rating,
        new_rating
    FROM watchlogs.v_season_rating_changes
    WHERE new_rating IS NOT NULL
),
compared AS (
    -- One row per season: starting rating and latest rating
    SELECT
        series_code,
        title,
        -- Rating before the first rated rewatch; if none (pre-log season),
        -- use the first rated rewatch itself as the starting point
        COALESCE(
            (ARRAY_AGG(old_rating ORDER BY rewatch_no))[1],
            (ARRAY_AGG(new_rating ORDER BY rewatch_no))[1]
        ) AS old_rating,
        -- Latest rated rewatch
        (ARRAY_AGG(new_rating ORDER BY rewatch_no DESC))[1] AS new_rating
    FROM rated
    GROUP BY series_code, title, season_no
    -- Keep a season only if there are two real ratings to compare:
    -- either an earlier rating exists, or there are 2+ rated rewatches
    HAVING COUNT(*) > 1
        OR (ARRAY_AGG(old_rating ORDER BY rewatch_no))[1] IS NOT NULL
),
averages AS (
    -- Average across the compared seasons of each series
    SELECT
        series_code,
        title,
        COUNT(*) AS seasons_compared,
        ROUND(AVG(old_rating), 1) AS old_avg,
        ROUND(AVG(new_rating), 1) AS new_avg
    FROM compared
    GROUP BY series_code, title
)
SELECT
    series_code,
    title,
    seasons_compared,
    old_avg,
    new_avg,
    new_avg - old_avg AS change,
    CASE
        WHEN new_avg > old_avg THEN 'Went Up'
        WHEN new_avg < old_avg THEN 'Went Down'
        ELSE 'No Change'
    END AS verdict
FROM averages
-- Default sort: title A to Z
ORDER BY title;

COMMENT ON VIEW watchlogs.v_series_rating_changes IS 'Did you like a series more or less after rewatching it?';

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  watchlogs.v_series_watchlist                                ║
-- ║  Seasons you are in the middle of right now                  ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  READS FROM    series_log, series_metadata                   ║
-- ║  ONE ROW PER   season that is Ongoing or On-Hold (its latest ║
-- ║                log)                                          ║
-- ║  SHOWS         episodes watched, season size, percent        ║
-- ║                complete, device                              ║
-- ║  NOTE          Sorted by percent complete, highest first.    ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE VIEW watchlogs.v_series_watchlist AS
WITH ranked_logs AS (
    SELECT 
        sl.log_id,
        sl.series_id,
        sl.season_no,
        sl.episodes_watched,
        sl.total_episodes,
        sl.watch_status,
        sl.device, 
        ROW_NUMBER() OVER (
            PARTITION BY sl.series_id, sl.season_no 
            ORDER BY sl.log_id DESC
        ) AS rn
    FROM watchlogs.series_log sl
    WHERE sl.watch_status IN ('Ongoing', 'On-Hold')
)
SELECT 
    rl.log_id,
    sm.series_id,             
    sm.series_code,          
    sm.title,
    rl.season_no,
    rl.episodes_watched,
    rl.total_episodes AS season_episodes,
    rl.device, 
    ROUND( ( (rl.episodes_watched::NUMERIC / NULLIF(rl.total_episodes, 0)::NUMERIC) * 100), 1 ) AS season_percent_complete
FROM registry.series_metadata sm
JOIN ranked_logs rl ON sm.series_id = rl.series_id
WHERE rl.rn = 1
ORDER BY season_percent_complete DESC, sm.title ASC;

COMMENT ON VIEW watchlogs.v_series_watchlist IS 'Seasons you are in the middle of right now';

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  watchlogs.v_movie_watchlist                                 ║
-- ║  Movies you are watching right now                           ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  READS FROM    movie_log, movie_metadata                     ║
-- ║  ONE ROW PER   movie log marked Ongoing                      ║
-- ║  SHOWS         title, dates, rating, rewatch flag, watch     ║
-- ║                status, device                                ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE VIEW watchlogs.v_movie_watchlist AS
SELECT
    ml.log_id,
    ml.movie_id,
    mm.title,
    ml.start_date,
    ml.end_date,
    ml.rating,
    ml.is_rewatch,
    ml.watch_status,
    ml.device
FROM watchlogs.movie_log AS ml
INNER JOIN registry.movie_metadata AS mm ON ml.movie_id = mm.movie_id
WHERE ml.watch_status = 'Ongoing';

COMMENT ON VIEW watchlogs.v_movie_watchlist IS 'Movies you are watching right now';

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  registry.v_movie_status                                     ║
-- ║  Where every movie stands in my watch progress               ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  READS FROM    movie_metadata, movie_log                     ║
-- ║  ONE ROW PER   movie                                         ║
-- ║  SHOWS         runtime, log status, watch status             ║
-- ║  NOTE          Movies with no logs show Pending. With several║
-- ║                logs, the status shown is the one that sorts  ║
-- ║                last alphabetically, not the newest.          ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE VIEW registry.v_movie_status AS
SELECT 
    mm.movie_id,
    movie_code,
    title,
    runtime_mins,
    log_status,
    COALESCE(MAX(ml.watch_status), 'Pending') AS watch_status
FROM registry.movie_metadata mm
LEFT JOIN watchlogs.movie_log ml ON mm.movie_id = ml.movie_id
GROUP BY mm.movie_id, movie_code, title, runtime_mins, log_status
ORDER BY mm.title;

COMMENT ON VIEW registry.v_movie_status IS 'Where every movie stands in my watch progress';

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  registry.v_series_status                                    ║
-- ║  Where every series stands, from Not Started to Finished     ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  READS FROM    series_metadata, series_log                   ║
-- ║  ONE ROW PER   series                                        ║
-- ║  SHOWS         progress like 3 / 5, and a status: Watching,  ║
-- ║                Rewatching, Caught Up, Finished, Dropped,     ║
-- ║                Pending or Not Started                        ║
-- ║  NOTE          Seasons you watched before you started logging║
-- ║                count toward progress.                        ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE VIEW registry.v_series_status AS
WITH series_agg AS (
    SELECT
        sm.series_id,
        sm.series_code,
        sm.title,
        sm.total_seasons,
        sm.platform,
        sm.status,
        -- Calculate total seasons finished (Legacy + Logged)
        GREATEST(
            sm.seasons_pre_log::INTEGER,
            COALESCE(MAX(sl.season_no) FILTER (WHERE sl.watch_status = 'Finished'), 0)
        ) AS seasons_completed,
        -- Detect status flags
        BOOL_OR(sl.watch_status = 'Ongoing' AND sl.is_rewatch = FALSE) AS is_actively_watching,
        BOOL_OR(sl.watch_status = 'Ongoing' AND sl.is_rewatch = TRUE) AS is_currently_rewatching,
        BOOL_OR(sl.watch_status = 'Dropped') AS dropped
    FROM registry.series_metadata sm
    LEFT JOIN watchlogs.series_log sl ON sm.series_id = sl.series_id
    GROUP BY sm.series_id, sm.series_code, sm.title, sm.total_seasons, sm.seasons_pre_log, sm.platform
)
SELECT
    series_id,
    series_code,
    title,
    platform,
    seasons_completed || ' / ' || total_seasons AS progress,
    CASE
        WHEN is_actively_watching THEN 'Watching'
        WHEN is_currently_rewatching THEN 'Rewatching'
        WHEN seasons_completed >= total_seasons AND total_seasons > 0 AND status = 'Returning' THEN 'Caught Up'
        WHEN seasons_completed >= total_seasons AND total_seasons > 0 THEN 'Finished'
        WHEN dropped THEN 'Dropped'
        WHEN seasons_completed > 0 AND seasons_completed < total_seasons THEN 'Pending'
        ELSE 'Not Started'
    END AS watch_status
FROM series_agg
ORDER BY title;

COMMENT ON VIEW registry.v_series_status IS 'Where every series stands, from Not Started to Finished';

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  registry.v_admin_toolbox                                    ║
-- ║  A menu of ready-to-copy admin queries                       ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  READS FROM    nothing, it is a fixed list                   ║
-- ║  ONE ROW PER   tool                                          ║
-- ║  SHOWS         category (Recovery, Maintenance or Audit),    ║
-- ║                tool name and the query to run                ║
-- ║  NOTE          Replace [ID], [LOG_ID] and [YEAR] with real   ║
-- ║                values before running a query.                ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE VIEW registry.v_admin_toolbox AS
SELECT
    'Recovery'::TEXT AS category,
    'Series Metadata Restore'::TEXT AS tool,
    'INSERT INTO registry.series_metadata SELECT * FROM jsonb_populate_record(NULL::registry.series_metadata, (SELECT original_data || jsonb_build_object(''latest_log_id'', NULL) FROM archive.metadata_audit WHERE entity_id = [ID] AND content_type = ''series'' LIMIT 1));'::TEXT AS query
UNION ALL
SELECT
    'Recovery',
    'Movie Metadata Restore',
    'INSERT INTO registry.movie_metadata SELECT * FROM jsonb_populate_record(NULL::registry.movie_metadata, (SELECT original_data || jsonb_build_object(''latest_log_id'', NULL) FROM archive.metadata_audit WHERE entity_id = [ID] AND content_type = ''movie'' LIMIT 1));'
UNION ALL
SELECT
    'Recovery',
    'Series Log Restore',
    'INSERT INTO watchlogs.series_log SELECT * FROM jsonb_populate_record(NULL::watchlogs.series_log, (SELECT row_data FROM archive.log_audit WHERE log_id = [LOG_ID] LIMIT 1));'
UNION ALL
SELECT
    'Recovery',
    'Movie Log Restore',
    'INSERT INTO watchlogs.movie_log SELECT * FROM jsonb_populate_record(NULL::watchlogs.movie_log, (SELECT row_data FROM archive.log_audit WHERE log_id = [LOG_ID] LIMIT 1));'
UNION ALL
SELECT
    'Maintenance',
    'Empty Recycle Bin',
    'TRUNCATE TABLE archive.log_audit, archive.metadata_audit;'
UNION ALL
SELECT
    'Maintenance',
    'Extend Calendar Table',
    'CALL public.extend_calendar([YEAR]);'
UNION ALL
SELECT
    'Audit',
    'Drop Procedure Tool',
    'SELECT proname, ''DROP PROCEDURE '' || oid::regprocedure || '';'' AS drop_procedure FROM pg_proc WHERE proname IN (''series_watch'', ''movie_watch'', ''add_metadata'', ''extend_calendar'', ''remove_metadata'', ''remove_log'');'
UNION ALL
SELECT
    'Audit',
    'List Functions and Triggers',
    'SELECT n.nspname AS schema, p.proname AS function_name, t.event_object_table AS table_name, t.trigger_name, string_agg(t.event_manipulation, '', '' ORDER BY t.event_manipulation) AS trigger_events, CASE WHEN t.trigger_name IS NULL THEN ''utility'' ELSE ''trigger function'' END AS function_type FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace LEFT JOIN information_schema.triggers t ON t.action_statement ILIKE ''%'' || p.proname || ''%'' WHERE n.nspname IN (''registry'', ''watchlogs'', ''public'', ''archive'') AND p.prokind = ''f'' GROUP BY n.nspname, p.proname, t.event_object_table, t.trigger_name ORDER BY 1, 2;';

COMMENT ON VIEW registry.v_admin_toolbox IS 'A menu of ready-to-copy admin queries';