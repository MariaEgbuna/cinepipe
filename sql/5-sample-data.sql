-- ╔══════════════════════════════════════════════════════════════╗
-- ║  Sample data                                                 ║
-- ║  A small test library to try the database with               ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  RUN ORDER     Run last, after the tables, procedures,       ║
-- ║                trigger functions and views files.            ║
-- ║  USE ONLY ON   an empty database. The script stops and       ║
-- ║                undoes itself if any series or movie already  ║
-- ║                exists, so it cannot touch real data.         ║
-- ║  ADDS          A calendar for 2025, 5 series, 7 movies and   ║
-- ║                their watch logs. Everything is written       ║
-- ║                through the stored procedures, like real use. ║
-- ║  SHOWS         Seasons watched before logging, rewatches, a  ║
-- ║                dropped season, a dropped movie, an on-hold   ║
-- ║                season, an ongoing season and movie, and      ║
-- ║                titles still in the backlog.                  ║
-- ║  NOTE          TMDB ids only need to be unique here. Dates   ║
-- ║                are fixed in 2025, so the results are the     ║
-- ║                same every time.                              ║
-- ╚══════════════════════════════════════════════════════════════╝

BEGIN;

-- ------------------------------------------------------------
-- 0. SAFETY CHECK
-- Stops everything if the database already holds real titles.
-- Because the script is one transaction, a stop here undoes it all.
-- ------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM registry.series_metadata)
       OR EXISTS (SELECT 1 FROM registry.movie_metadata) THEN
        RAISE EXCEPTION 'Sample data stopped: this database already has series or movies. Use an empty database.';
    END IF;
END $$;


-- ------------------------------------------------------------
-- 1. CALENDAR
-- Logs can only use dates that exist in dates_table.
-- A trigger fills in the year, month and weekday columns.
-- ------------------------------------------------------------
INSERT INTO public.dates_table (date_key) VALUES ('2025-01-01')
ON CONFLICT (date_key) DO NOTHING;

CALL public.extend_calendar(2025);


-- ------------------------------------------------------------
-- 2. SERIES CATALOGUE
-- add_metadata(type, title, year, country, platform, avg runtime,
--              genres, tmdb id, status, year completed,
--              seasons, episodes, seasons watched before logging)
-- ------------------------------------------------------------
-- Seasons 1 to 14 were watched before logging started
CALL registry.add_metadata('Series', 'Bob''s Burgers', 2011, 'US', 'FOX', 22,
     ARRAY['Comedy', 'Animation'], 32726, 'Returning', NULL, 16, 313, 14);

CALL registry.add_metadata('Series', 'Breaking Bad', 2008, 'US', 'AMC', 47,
     ARRAY['Drama', 'Crime'], 1396, 'Ended', 2013, 5, 62, 0);

-- An anime and a kdrama, to show that country is just a detail of a series
CALL registry.add_metadata('Series', 'Attack on Titan', 2013, 'JP', 'MBS', 24,
     ARRAY['Animation', 'Action & Adventure', 'Drama'], 1429, 'Ended', 2023, 4, 94, 0);

CALL registry.add_metadata('Series', 'Squid Game', 2021, 'KR', 'Netflix', 55,
     ARRAY['Drama', 'Mystery', 'Action & Adventure'], 93405, 'Ended', 2025, 3, 22, 0);

-- Never logged, so it stays in the backlog
CALL registry.add_metadata('Series', 'Severance', 2022, 'US', 'Apple TV+', 50,
     ARRAY['Drama', 'Mystery', 'Sci-Fi & Fantasy'], 95396, 'Returning', NULL, 2, 19, 0);


-- ------------------------------------------------------------
-- 3. MOVIE CATALOGUE
-- add_metadata(type, title, year, country, director, runtime,
--              genres, tmdb id, watched_pre_log)
-- ------------------------------------------------------------
CALL registry.add_metadata('Movie', 'Inception', 2010, 'US', 'Christopher Nolan', 148,
     ARRAY['Action', 'Science Fiction', 'Adventure'], 27205, false);

CALL registry.add_metadata('Movie', 'Inglourious Basterds', 2009, 'US', 'Quentin Tarantino', 153,
     ARRAY['Drama', 'Thriller', 'War'], 16869, false);

CALL registry.add_metadata('Movie', 'Jurassic Park', 1993, 'US', 'Steven Spielberg', 127,
     ARRAY['Adventure', 'Science Fiction'], 329, true);

CALL registry.add_metadata('Movie', 'Parasite', 2019, 'KR', 'Bong Joon Ho', 133,
     ARRAY['Comedy', 'Thriller', 'Drama'], 496243), true;

CALL registry.add_metadata('Movie', 'Morbius', 2022, 'US', 'Daniel Espinosa', 104,
     ARRAY['Action', 'Fantasy', 'Science Fiction'], 526896, false);

CALL registry.add_metadata('Movie', 'Dune', 2021, 'US', 'Denis Villeneuve', 155,
     ARRAY['Science Fiction', 'Adventure'], 438631, false);

-- Never logged, so it stays in the backlog
CALL registry.add_metadata('Movie', 'Everything Everywhere All at Once', 2022, 'US', 'Daniel Kwan', 139,
     ARRAY['Action', 'Adventure', 'Science Fiction'], 545611, false);


-- ------------------------------------------------------------
-- 4. SERIES LOGS
-- series_watch(code, season, season episodes, episodes watched,
--              watch type, rating, device, review, status,
--              is rewatch, start date, end date)
-- Logs are added in the order they happened. The rating views
-- compare each rewatch with the log before it.
-- ------------------------------------------------------------
-- Finished seasons, first watches
CALL watchlogs.series_watch('BRE-08', 1, 7, 7, 'Binge', 9.0, 'Laptop',
     'Slow start, then it hooks you.', 'Finished', FALSE, '2025-01-05', '2025-01-09');

CALL watchlogs.series_watch('BRE-08', 2, 13, 13, 'Binge', 8.8, 'Laptop',
     'Gets darker and better.', 'Finished', FALSE, '2025-01-12', '2025-01-20');

CALL watchlogs.series_watch('ATT-13', 1, 25, 25, 'Binge', 9.0, 'Both',
     'The first season sets the tone perfectly.', 'Finished', FALSE, '2025-02-01', '2025-02-14');

CALL watchlogs.series_watch('SQU-21', 1, 9, 9, 'Binge', 8.5, 'Phone',
     'Tense from the first episode.', 'Finished', FALSE, '2025-02-20', '2025-02-22');

-- Bob's Burgers Season 1 was watched before logging, so this first LOGGED
-- watch is already a rewatch (the trigger sets the flag by itself)
CALL watchlogs.series_watch('BOB-11', 1, 13, 13, 'Daily', 8.0, 'Both',
     'Still funny.', 'Finished', TRUE, '2025-03-01', '2025-03-30');

CALL watchlogs.series_watch('BOB-11', 2, 22, 22, 'Daily', 7.5, 'Both',
     'A bit uneven, but the good episodes are great.', 'Finished', TRUE, '2025-04-01', '2025-05-15');

CALL watchlogs.series_watch('SQU-21', 2, 7, 7, 'Binge', 7.0, 'Phone',
     'Fine, but the first season was stronger.', 'Finished', FALSE, '2025-05-20', '2025-05-21');

-- On hold: 6 of 12 episodes watched, no end date, no rating
CALL watchlogs.series_watch('ATT-13', 2, 12, 6, 'Casual', NULL, 'Laptop',
     'TBA', 'On-Hold', FALSE, '2025-06-01', NULL);

-- A second finished watch of the same season: the trigger flags it as a
-- rewatch automatically, even though it is passed as FALSE
CALL watchlogs.series_watch('BRE-08', 1, 7, 7, 'Binge', 9.5, 'Laptop',
     'Even better the second time.', 'Finished', FALSE, '2025-07-10', '2025-07-13');

CALL watchlogs.series_watch('BOB-11', 1, 13, 13, 'Daily', 9.5, 'Both',
     'Better than I remembered.', 'Finished', FALSE, '2025-08-10', '2025-08-24');

-- A dropped rewatch: 6 of 23 episodes, no rating. Dropped logs skip the
-- automatic rewatch check, so the flag is passed as TRUE here.
CALL watchlogs.series_watch('BOB-11', 3, 23, 6, 'Casual', NULL, 'Phone',
     'Not in the mood for this season.', 'Dropped', TRUE, '2025-09-01', '2025-09-05');

-- Still watching: 5 of 13 episodes. Shows up in the watchlist view.
CALL watchlogs.series_watch('BRE-08', 3, 13, 5, 'Casual', NULL, 'Laptop',
     'TBA', 'Ongoing', FALSE, '2025-10-01', NULL);


-- ------------------------------------------------------------
-- 5. MOVIE LOGS
-- movie_watch(code, rating, review, status, is rewatch,
--             device, start date, end date)
-- Watch pace is worked out from the dates: same day is Normal,
-- 1 to 2 days is Split View, longer is Slow.
-- ------------------------------------------------------------
CALL watchlogs.movie_watch('INC-10', 9.0, 'Mind-bending and still holds up.',
     'Finished', FALSE, 'Laptop', '2025-01-10', '2025-01-10');

CALL watchlogs.movie_watch('ING-09', 8.5, 'Great opening scene.',
     'Finished', FALSE, 'Both', '2025-01-25', '2025-01-26');

CALL watchlogs.movie_watch('JUR-93', 8.0, 'A classic.',
     'Finished', TRUE, 'Laptop', '2025-02-02', '2025-02-07');

CALL watchlogs.movie_watch('PAR-19', 9.5, 'Every scene matters.',
     'Finished', TRUE, 'Phone', '2025-03-08', '2025-03-08');

-- Dropped: no rating, pace becomes Stalled
CALL watchlogs.movie_watch('MOR-22', NULL, 'Switched it off early.',
     'Dropped', FALSE, 'Laptop', '2025-04-12', '2025-04-12');

-- Rewatches: the trigger flags them because a finished log already exists
CALL watchlogs.movie_watch('INC-10', 9.5, 'Noticed more the second time.',
     'Finished', FALSE, 'Laptop', '2025-06-14', '2025-06-14');

CALL watchlogs.movie_watch('ING-09', 9.0, 'Rated it higher on the rewatch.',
     'Finished', FALSE, 'Laptop', '2025-09-20', '2025-09-20');

-- Still watching: no end date, no rating. Shows up in the movie watchlist.
CALL watchlogs.movie_watch('DUN-21', NULL, 'TBA',
     'Ongoing', FALSE, 'Laptop', '2025-12-20', NULL);

COMMIT;


-- ------------------------------------------------------------
-- 6. CHECKS (run these one at a time and compare)
-- ------------------------------------------------------------
-- a) Row counts: expect 5 series, 7 movies, 12 series logs, 8 movie logs
SELECT (SELECT COUNT(*) FROM registry.series_metadata) AS series,
       (SELECT COUNT(*) FROM registry.movie_metadata)  AS movies,
       (SELECT COUNT(*) FROM watchlogs.series_log)     AS series_logs,
       (SELECT COUNT(*) FROM watchlogs.movie_log)      AS movie_logs;

-- b) Codes made by the trigger, and the log status it kept up to date
--    (Severance and Everything Everywhere should still be Backlog)
SELECT series_code AS code, title, log_status FROM registry.series_metadata
UNION ALL
SELECT movie_code, title, log_status FROM registry.movie_metadata
ORDER BY 3, 1;

-- c) Status automation and rewatch detection on the series logs
SELECT series_code, season_no, watch_status, is_rewatch, rating, score_verdict
FROM watchlogs.series_log sl
JOIN registry.series_metadata sm ON sm.series_id = sl.series_id
ORDER BY sl.log_id;

-- d) Rating changes by season (expect 5 rows, including one Dropped)
SELECT * FROM watchlogs.v_season_rating_changes;

-- e) Rating changes by series (expect Bob's Burgers 8.0 to 9.5 and Breaking Bad 9.0 to 9.5)
SELECT * FROM watchlogs.v_series_rating_changes;

-- f) Rating changes by movie (expect Inception and Inglourious Basterds)
SELECT * FROM watchlogs.v_rewatch_rating_changes;

-- g) What is in progress (expect Breaking Bad S3, Attack on Titan S2, and Dune)
SELECT * FROM watchlogs.v_series_watchlist;
SELECT * FROM watchlogs.v_movie_watchlist;
