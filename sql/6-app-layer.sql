-- ╔══════════════════════════════════════════════════════════════╗
-- ║  6 - App Layer                                               ║
-- ║  The only views the website is allowed to see                ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  WHAT THIS IS  A small schema named app. Each view reads     ║
-- ║                from your real views and tables and shows     ║
-- ║                only what one screen needs. The website never ║
-- ║                touches watchlogs or registry directly.       ║
-- ║  RUN ON        Supabase, and local too if you want them to   ║
-- ║                match. Safe to run again: nothing is dropped  ║
-- ║                or deleted.                                   ║
-- ║  NEEDS         The poster_path column from file 8 (or from   ║
-- ║                files 1 and 2 on a fresh build).              ║
-- ║  ACCESS        Set in file 7 - App Access, not here.         ║
-- ║  NOTE          These views run with the owner's rights. That ║
-- ║                is on purpose: it lets the website read       ║
-- ║                through them without any rights on the real   ║
-- ║                tables.                                       ║
-- ╚══════════════════════════════════════════════════════════════╝

CREATE SCHEMA IF NOT EXISTS app;

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  app.now_watching_series                                     ║
-- ║  Seasons you are in the middle of right now                  ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  READS FROM    v_series_watchlist, series_metadata,          ║
-- ║                series_log                                    ║
-- ║  ONE ROW PER   season being watched (Ongoing or On-Hold)     ║
-- ║  SHOWS         progress, percent complete, platform, poster, ║
-- ║                and whether it is On-Hold or a rewatch        ║
-- ║  SORTED BY     percent complete, then title                  ║
-- ╚══════════════════════════════════════════════════════════════╝

CREATE OR REPLACE VIEW app.now_watching_series AS
SELECT
    w.log_id,
    w.series_code,
    w.title,
    sm.year_released,
    sm.country,
    sm.platform,
    w.season_no,
    w.episodes_watched,
    w.season_episodes,
    w.season_percent_complete,
    sl.watch_status,
    sl.is_rewatch,
    sl.start_date,
    w.device,
    sm.poster_path
FROM watchlogs.v_series_watchlist AS w
INNER JOIN registry.series_metadata AS sm ON sm.series_id = w.series_id
INNER JOIN watchlogs.series_log AS sl ON sl.log_id = w.log_id
ORDER BY w.season_percent_complete DESC NULLS LAST, w.title;

COMMENT ON VIEW app.now_watching_series IS 'Seasons you are in the middle of right now';

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  app.now_watching_movies                                     ║
-- ║  Movies you are watching right now                           ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  READS FROM    v_movie_watchlist, movie_metadata             ║
-- ║  ONE ROW PER   movie log with the status Ongoing             ║
-- ║  SHOWS         movie code, year, country, runtime, start     ║
-- ║                date, poster, and whether it is a rewatch     ║
-- ║  SORTED BY     newest start date, then title                 ║
-- ╚══════════════════════════════════════════════════════════════╝

CREATE OR REPLACE VIEW app.now_watching_movies AS
SELECT
    w.log_id,
    mm.movie_code,
    w.title,
    mm.year_released,
    mm.country,
    mm.runtime_mins,
    w.start_date,
    w.is_rewatch,
    w.device,
    mm.poster_path
FROM watchlogs.v_movie_watchlist AS w
INNER JOIN registry.movie_metadata AS mm ON mm.movie_id = w.movie_id
ORDER BY w.start_date DESC, w.title;

COMMENT ON VIEW app.now_watching_movies IS 'Movies you are watching right now';

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  app.library_series                                          ║
-- ║  Every series and where it stands                            ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  READS FROM    v_series_status, series_metadata              ║
-- ║  ONE ROW PER   series                                        ║
-- ║  SHOWS         year, country, genres, platform, poster,      ║
-- ║                progress like 3 / 5, watch status, season     ║
-- ║                count, and show_status (is the show still     ║
-- ║                airing)                                       ║
-- ║  SORTED BY     title                                         ║
-- ╚══════════════════════════════════════════════════════════════╝

CREATE OR REPLACE VIEW app.library_series AS
SELECT
    ss.series_code,
    ss.title,
    sm.year_released,
    sm.country,
    sm.genres,
    ss.platform,
    ss.progress,
    ss.watch_status,
    sm.total_seasons,
    sm.status AS show_status,
    sm.poster_path
FROM registry.v_series_status AS ss
INNER JOIN registry.series_metadata AS sm ON sm.series_id = ss.series_id
ORDER BY ss.title;

COMMENT ON VIEW app.library_series IS 'Every series and where it stands';

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  app.library_movies                                          ║
-- ║  Every movie and where it stands                             ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  READS FROM    movie_metadata, movie_log                     ║
-- ║  ONE ROW PER   movie                                         ║
-- ║  SHOWS         year, country, director, runtime, genres,     ║
-- ║                poster, watch status, and seen_before_logging ║
-- ║  NOTE          The watch status comes from the newest log    ║
-- ║                (the highest log id), not the one that sorts  ║
-- ║                last alphabetically. Movies with no logs show ║
-- ║                Pending.                                      ║
-- ║  SORTED BY     title                                         ║
-- ╚══════════════════════════════════════════════════════════════╝

CREATE OR REPLACE VIEW app.library_movies AS
WITH newest_log AS (
    SELECT DISTINCT ON (ml.movie_id)
        ml.movie_id,
        ml.watch_status
    FROM watchlogs.movie_log AS ml
    ORDER BY ml.movie_id, ml.log_id DESC
)
SELECT
    mm.movie_code,
    mm.title,
    mm.year_released,
    mm.country,
    mm.director,
    mm.runtime_mins,
    mm.genres,
    COALESCE(nl.watch_status, 'Pending') AS watch_status,
    mm.watched_pre_log AS seen_before_logging,
    mm.poster_path
FROM registry.movie_metadata AS mm
LEFT JOIN newest_log AS nl ON nl.movie_id = mm.movie_id
ORDER BY mm.title;

COMMENT ON VIEW app.library_movies IS 'Every movie and where it stands';

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  app.rewatch_movies                                          ║
-- ║  How your movie ratings changed on a rewatch                 ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  READS FROM    v_rewatch_rating_changes, movie_metadata      ║
-- ║  ONE ROW PER   movie rewatch (rated or dropped)              ║
-- ║  SHOWS         old rating, new rating, change, a verdict,    ║
-- ║                and the poster                                ║
-- ╚══════════════════════════════════════════════════════════════╝

CREATE OR REPLACE VIEW app.rewatch_movies AS
SELECT
    r.movie_code,
    r.title,
    r.year_released,
    r.rewatch_no,
    r.old_watch,
    r.old_rating,
    r.new_rating,
    r.change,
    r.verdict,
    mm.poster_path
FROM watchlogs.v_rewatch_rating_changes AS r
LEFT JOIN registry.movie_metadata AS mm ON mm.movie_code = r.movie_code;

COMMENT ON VIEW app.rewatch_movies IS 'How your movie ratings changed on a rewatch';

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  app.rewatch_series                                          ║
-- ║  How each series changed on rewatch, in one row              ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  READS FROM    v_series_rating_changes, series_metadata      ║
-- ║  ONE ROW PER   series with at least one compared season      ║
-- ║  SHOWS         seasons compared, old average, new average,   ║
-- ║                change, a verdict, and the poster             ║
-- ╚══════════════════════════════════════════════════════════════╝

CREATE OR REPLACE VIEW app.rewatch_series AS
SELECT
    r.series_code,
    r.title,
    r.seasons_compared,
    r.old_avg,
    r.new_avg,
    r.change,
    r.verdict,
    sm.poster_path
FROM watchlogs.v_series_rating_changes AS r
LEFT JOIN registry.series_metadata AS sm ON sm.series_code = r.series_code;

COMMENT ON VIEW app.rewatch_series IS 'How each series changed on rewatch, in one row';

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  app.rewatch_seasons                                         ║
-- ║  Season by season detail of a rewatch                        ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  READS FROM    v_season_rating_changes                       ║
-- ║  ONE ROW PER   season rewatch                                ║
-- ║  SHOWS         old rating, new rating, change, and a         ║
-- ║                verdict. The series screen opens this when    ║
-- ║                you tap a series.                             ║
-- ╚══════════════════════════════════════════════════════════════╝

CREATE OR REPLACE VIEW app.rewatch_seasons AS
SELECT
    series_code,
    title,
    season_no,
    rewatch,
    old_watch,
    old_rating,
    new_rating,
    change,
    verdict
FROM watchlogs.v_season_rating_changes;

COMMENT ON VIEW app.rewatch_seasons IS 'Season by season detail of a rewatch';
