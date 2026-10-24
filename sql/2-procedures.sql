-- ╔══════════════════════════════════════════════════════════════╗
-- ║  registry.add_metadata                                       ║
-- ║  Registers a new series or movie in the catalogue            ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  TAKES         type (Movie or Series), title, year and       ║
-- ║                tmdb_id. Optional: country (default US),      ║
-- ║                extra info, runtime, genres. Series also take ║
-- ║                status, year completed, seasons, episodes and ║
-- ║                seasons watched before logging.               ║
-- ║  EXTRA INFO    the **platform** for a series, or the         ║
-- ║                **director** for a movie                      ║
-- ║  HOW IT WORKS  Checks the type and that tmdb_id is given.    ║
-- ║                Looks for the same tmdb_id in that library.   ║
-- ║                If it is already there, it prints a notice    ║
-- ║                and does nothing. If not, it adds the new     ║
-- ║                row.                                          ║
-- ║  STOPS WHEN    tmdb_id is missing, or the type is not Movie  ║
-- ║                or Series                                     ║
-- ║  NOTE          Type is not case sensitive. A series status   ║
-- ║                defaults to Returning. The movie or series    ║
-- ║                code is made by the trigger                   ║
-- ║                fn_process_metadata.                          ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE PROCEDURE registry.add_metadata(
    p_type           TEXT, 
    p_title          TEXT, 
    p_year           INTEGER, 
    p_country        TEXT DEFAULT 'US',
    p_extra_info     TEXT DEFAULT 'Unknown', -- Acts as Platform for Series and Director for movies
    p_runtime        INTEGER DEFAULT NULL,
    p_genres         TEXT[] DEFAULT NULL, 
    p_tmdb_id        INTEGER DEFAULT NULL,
    p_status         TEXT DEFAULT NULL,
    p_completed      INTEGER DEFAULT NULL, 
    p_seasons        INTEGER DEFAULT NULL, 
    p_episodes       INTEGER DEFAULT NULL, 
    p_seasons_pre_log INTEGER DEFAULT 0
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_exists BOOLEAN;
    v_type   TEXT := UPPER(p_type);
BEGIN
    IF p_tmdb_id IS NULL THEN
        RAISE EXCEPTION 'Registration failed: tmdb_id is required and cannot be NULL.';
    END IF;

    -- Duplicate check based on TMDB ID
    IF v_type = 'SERIES' THEN
        SELECT EXISTS (SELECT 1 FROM registry.series_metadata WHERE tmdb_id = p_tmdb_id) INTO v_exists;
    ELSIF v_type = 'MOVIE' THEN
        SELECT EXISTS (SELECT 1 FROM registry.movie_metadata WHERE tmdb_id = p_tmdb_id) INTO v_exists;
    ELSE
        RAISE EXCEPTION 'Invalid media type: %. Use "MOVIE" or "SERIES".', v_type;
    END IF;

    IF v_exists THEN
        RAISE NOTICE '% (%) is already in the % library.', p_title, p_year, v_type;
        RETURN;
    END IF;
    
    IF v_type = 'SERIES' THEN
        INSERT INTO registry.series_metadata (
            title, country, year_released, year_completed, total_seasons, total_episodes, 
            avg_runtime, genres, platform, status, seasons_pre_log, tmdb_id
        )
        VALUES (
            p_title, p_country, p_year::SMALLINT, p_completed::SMALLINT, p_seasons::SMALLINT, 
            p_episodes::SMALLINT, p_runtime::SMALLINT, p_genres, p_extra_info, 
            COALESCE(p_status, 'Returning'), p_seasons_pre_log::SMALLINT, p_tmdb_id
        );
    ELSE
        INSERT INTO registry.movie_metadata (
            title, year_released, country, director, 
            runtime_mins, genres, tmdb_id
        )
        VALUES (
            p_title, p_year::SMALLINT, p_country, p_extra_info, 
			p_runtime::SMALLINT,  p_genres, p_tmdb_id
        );
    END IF;

    RAISE NOTICE '% (%) registered successfully as %.', p_title, p_year, v_type;
END;
$procedure$;

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  watchlogs.series_watch                                      ║
-- ║  Updates an existing season log, or starts a new one         ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  TAKES         series code, season number, total episodes,   ║
-- ║                episodes watched, watch type and rating.      ║
-- ║                Optional: device (Laptop), review (TBA),      ║
-- ║                status (Ongoing), rewatch flag (false), start ║
-- ║                date (today), end date.                       ║
-- ║  HOW IT WORKS  Finds the series by code. Then looks for a    ║
-- ║                log of the same season with the same rewatch  ║
-- ║                flag that is not Finished, or that has the    ║
-- ║                same start date. If one is found, it is       ║
-- ║                updated. If not, a new log is added.          ║
-- ║  STOPS WHEN    the series code is not found                  ║
-- ║  NOTE          If several logs match, the one with the       ║
-- ║                newest start date is used. An update never    ║
-- ║                changes the start date or rewatch flag, and   ║
-- ║                keeps the old end date when no new one is     ║
-- ║                given. Afterwards the trigger                 ║
-- ║                fn_process_log_entry decides the final        ║
-- ║                status, dates and whether the rating is kept  ║
-- ║                (a season only becomes Finished when all      ║
-- ║                episodes are watched).                        ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE PROCEDURE watchlogs.series_watch(
    p_series_code      TEXT, 
    p_season_no        INTEGER, 
    p_total_episodes   INTEGER, 
    p_episodes_watched INTEGER, 
    p_watch_type       TEXT, 
    p_rating           NUMERIC, 
    p_device           TEXT DEFAULT 'Laptop',
    p_review           TEXT DEFAULT 'TBA', 
    p_watch_status     TEXT DEFAULT 'Ongoing', 
    p_is_rewatch       BOOLEAN DEFAULT FALSE, 
    p_start_date       DATE DEFAULT CURRENT_DATE, 
    p_end_date         DATE DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_log_id    INT;
    v_series_id INT;
BEGIN
    SELECT series_id INTO v_series_id 
      FROM registry.series_metadata 
     WHERE series_code = p_series_code;

    IF v_series_id IS NULL THEN
        RAISE EXCEPTION 'Series code % not found.', p_series_code;
    END IF;

    SELECT log_id
      INTO v_log_id
      FROM watchlogs.series_log
     WHERE series_id    = v_series_id
       AND season_no    = p_season_no::SMALLINT
       AND is_rewatch   = p_is_rewatch
       AND (start_date  = p_start_date OR watch_status != 'Finished')
     ORDER BY start_date DESC
     LIMIT 1;

    IF v_log_id IS NOT NULL THEN
        UPDATE watchlogs.series_log
           SET episodes_watched = p_episodes_watched::SMALLINT,
               total_episodes   = p_total_episodes::SMALLINT,
               watch_type       = p_watch_type,
               device           = p_device,
               watch_status     = p_watch_status,
               rating           = p_rating,
               review           = p_review,
               end_date         = COALESCE(p_end_date, end_date)
         WHERE log_id = v_log_id;
         
        RAISE NOTICE 'Updated record for % S% (Status: %).', p_series_code, p_season_no, p_watch_status;
    ELSE
        INSERT INTO watchlogs.series_log (
            series_id, season_no, total_episodes,
            episodes_watched, watch_type, device, watch_status, 
            rating, review, is_rewatch, start_date, end_date
        )
        VALUES (
            v_series_id, p_season_no::SMALLINT, p_total_episodes::SMALLINT, p_episodes_watched::SMALLINT,
            p_watch_type, p_device, p_watch_status, p_rating, p_review, p_is_rewatch, p_start_date, p_end_date
        );
        
        RAISE NOTICE 'New log entry created for % S%.', p_series_code, p_season_no;
    END IF;
END;
$procedure$;

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  watchlogs.movie_watch                                       ║
-- ║  Updates an existing movie log, or starts a new one          ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  TAKES         movie code. Optional: rating, review (TBA),   ║
-- ║                status (Ongoing), rewatch flag (false),       ║
-- ║                device (Laptop), start date (today), end      ║
-- ║                date.                                         ║
-- ║  HOW IT WORKS  Finds the movie by code. Then looks for a log ║
-- ║                with the same rewatch flag that is not        ║
-- ║                Finished, or that has the same start date. If ║
-- ║                one is found, it is updated. If not, a new    ║
-- ║                log is added.                                 ║
-- ║  STOPS WHEN    the movie code is not found                   ║
-- ║  NOTE          If several logs match, the one with the       ║
-- ║                newest start date is used. An update never    ║
-- ║                changes the start date or rewatch flag, and   ║
-- ║                keeps the old end date when no new one is     ║
-- ║                given. Afterwards the trigger                 ║
-- ║                fn_process_log_entry decides the final        ║
-- ║                status, dates and whether the rating is kept. ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE PROCEDURE watchlogs.movie_watch(
    p_movie_code        TEXT, 
    p_rating            NUMERIC DEFAULT NULL, 
    p_review            TEXT DEFAULT 'TBA', 
    p_watch_status      TEXT DEFAULT 'Ongoing',
    p_is_rewatch        BOOLEAN DEFAULT FALSE,
    p_device            TEXT DEFAULT 'Laptop', 
    p_start_date        DATE DEFAULT CURRENT_DATE,
    p_end_date          DATE DEFAULT NULL
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_movie_id INTEGER;
    v_log_id   INTEGER;
BEGIN
    SELECT movie_id INTO v_movie_id 
      FROM registry.movie_metadata 
     WHERE movie_code = p_movie_code;

    IF v_movie_id IS NULL THEN
        RAISE EXCEPTION 'Movie code "%" not found.', p_movie_code;
    END IF;

    SELECT log_id INTO v_log_id
      FROM watchlogs.movie_log
     WHERE movie_id   = v_movie_id
       AND is_rewatch = p_is_rewatch
       AND (start_date = p_start_date OR watch_status != 'Finished')
     ORDER BY start_date DESC
     LIMIT 1;

    IF v_log_id IS NOT NULL THEN
        UPDATE watchlogs.movie_log
           SET rating       = p_rating,
               review       = p_review,
               watch_status = p_watch_status,
               device       = p_device, 
               end_date     = COALESCE(p_end_date, end_date)
         WHERE log_id = v_log_id;
         
        RAISE NOTICE 'Updated existing watchlog for movie code: %', p_movie_code;
    ELSE
        INSERT INTO watchlogs.movie_log (
            movie_id, start_date, end_date, rating, 
            review, is_rewatch, watch_status, device
        )
        VALUES (
            v_movie_id, p_start_date, p_end_date, p_rating, 
            p_review, p_is_rewatch, p_watch_status, p_device
        );
        
        RAISE NOTICE 'Recorded new watchlog for movie code: %', p_movie_code;
    END IF;
END;
$procedure$;

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  public.extend_calendar                                      ║
-- ║  Adds new dates to the calendar up to the end of a year      ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  TAKES         the target year                               ║
-- ║  HOW IT WORKS  Finds the last date already in dates_table,   ║
-- ║                then adds every day after it up to 31         ║
-- ║                December of the target year. Each row gets    ║
-- ║                the year, quarter, month, day name, day of    ║
-- ║                week number and a weekend flag.               ║
-- ║  STOPS WHEN    the calendar already reaches that year. It    ║
-- ║                prints a notice and adds nothing, so no       ║
-- ║                duplicates are made.                          ║
-- ║  NOTE          Run this before logging a date in a new year, ║
-- ║                because logs can only use dates that exist in ║
-- ║                the calendar.                                 ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE PROCEDURE public.extend_calendar(target_year INT)
LANGUAGE plpgsql
AS $$
DECLARE
    current_max_date DATE;
    start_date DATE;
    end_date DATE;
BEGIN
    SELECT MAX(date_key) INTO current_max_date FROM public.dates_table;
    
    start_date := current_max_date + 1;
    end_date   := TO_DATE(target_year || '-12-31', 'YYYY-MM-DD');

    -- 3. Validation
    IF start_date > end_date THEN
        RAISE NOTICE 'The calendar is already populated through the end of %.', target_year;
        RETURN;
    END IF;

    INSERT INTO public.dates_table (
        date_key, 
        date_year, 
        quarters, 
        month_num, 
        month_short, 
        day_short, 
        day_of_week_index, 
        is_weekend
    )
    SELECT 
        gs::DATE AS date_key,
        EXTRACT(YEAR FROM gs)::SMALLINT AS date_year,
        EXTRACT(QUARTER FROM gs)::SMALLINT AS quarters,
        EXTRACT(MONTH FROM gs)::SMALLINT AS month_num,
        TO_CHAR(gs, 'Mon')::CHAR(3) AS month_short,
        TO_CHAR(gs, 'Dy')::CHAR(3) AS day_short,
        EXTRACT(ISODOW FROM gs)::SMALLINT AS day_of_week_index,
        CASE 
			WHEN EXTRACT(ISODOW FROM gs) IN (6, 7) THEN TRUE 
			ELSE FALSE 
		END AS is_weekend
    FROM generate_series(start_date, end_date, '1 day'::interval) AS gs;

    RAISE NOTICE 'Calendar successfully extended to % (% rows added).', end_date, (end_date - current_max_date);
END;
$$;

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  registry.remove_metadata                                    ║
-- ║  Safely deletes a series or movie from the catalogue         ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  TAKES         type (Movie or Series) and the item code      ║
-- ║  HOW IT WORKS  Finds the item by code. If it is not found,   ║
-- ║                it prints a notice and stops. If the item has ║
-- ║                an Ongoing log, it refuses. Otherwise it      ║
-- ║                deletes the item.                             ║
-- ║  STOPS WHEN    the type is not Movie or Series, or the item  ║
-- ║                has an Ongoing log                            ║
-- ║  NOTE          An audit trigger saves a copy of the deleted  ║
-- ║                row to the recycle bin automatically.         ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE PROCEDURE registry.remove_metadata(
    p_type TEXT,
    p_code TEXT
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_type      TEXT := UPPER(p_type);
    v_id        INTEGER;
    v_title     TEXT;
    v_ongoing   BOOLEAN;
BEGIN
    -- Resolve ID and title based on type
    IF v_type = 'MOVIE' THEN
        SELECT movie_id, title INTO v_id, v_title
          FROM registry.movie_metadata
         WHERE movie_code = p_code;

    ELSIF v_type = 'SERIES' THEN
        SELECT series_id, title INTO v_id, v_title
          FROM registry.series_metadata
         WHERE series_code = p_code;

    ELSE
        RAISE EXCEPTION 'Invalid type: %. Use "MOVIE" or "SERIES".', p_type;
    END IF;

    -- Record not found
    IF v_id IS NULL THEN
        RAISE NOTICE '% code "%" not found. Nothing to delete.', v_type, p_code;
        RETURN;
    END IF;

    -- Block deletion if active logs exist
    IF v_type = 'MOVIE' THEN
        SELECT EXISTS (
            SELECT 1 FROM watchlogs.movie_log
             WHERE movie_id = v_id AND watch_status = 'Ongoing'
        ) INTO v_ongoing;

    ELSIF v_type = 'SERIES' THEN
        SELECT EXISTS (
            SELECT 1 FROM watchlogs.series_log
             WHERE series_id = v_id AND watch_status = 'Ongoing'
        ) INTO v_ongoing;
    END IF;

    IF v_ongoing THEN
        RAISE EXCEPTION 'Cannot delete "%": there is an active Ongoing log entry.', v_title;
    END IF;

    -- Delete (audit trigger fires automatically)
    IF v_type = 'MOVIE' THEN
        DELETE FROM registry.movie_metadata WHERE movie_id = v_id;
    ELSIF v_type = 'SERIES' THEN
        DELETE FROM registry.series_metadata WHERE series_id = v_id;
    END IF;

    RAISE NOTICE '% "%" deleted successfully.', v_type, v_title;
END;
$procedure$;


-- ╔══════════════════════════════════════════════════════════════╗
-- ║  watchlogs.remove_log                                        ║
-- ║  Safely deletes one watch log                                ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  TAKES         type (Movie or Series) and the log id         ║
-- ║  HOW IT WORKS  Finds the log by id. If it is not found, it   ║
-- ║                prints a notice and stops. If the log is      ║
-- ║                still Ongoing, it refuses. Otherwise it       ║
-- ║                deletes the log.                              ║
-- ║  STOPS WHEN    the type is not Movie or Series, or the log   ║
-- ║                is Ongoing                                    ║
-- ║  NOTE          After the delete, the triggers                ║
-- ║                fn_sync_latest_log and fn_sync_media_status   ║
-- ║                run automatically.                            ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE PROCEDURE watchlogs.remove_log(
    p_type   TEXT,
    p_log_id INTEGER
)
LANGUAGE plpgsql
AS $procedure$
DECLARE
    v_type        TEXT := UPPER(p_type);
    v_watch_status TEXT;
    v_entity_id   INTEGER;
    v_label       TEXT;
BEGIN
    -- Resolve log entry based on type
    IF v_type = 'MOVIE' THEN
        SELECT watch_status, movie_id INTO v_watch_status, v_entity_id
          FROM watchlogs.movie_log
         WHERE log_id = p_log_id;

    ELSIF v_type = 'SERIES' THEN
        SELECT watch_status, series_id INTO v_watch_status, v_entity_id
          FROM watchlogs.series_log
         WHERE log_id = p_log_id;

    ELSE
        RAISE EXCEPTION 'Invalid type: %. Use "MOVIE" or "SERIES".', p_type;
    END IF;

    -- Record not found
    IF v_watch_status IS NULL THEN
        RAISE NOTICE '% log ID % not found. Nothing to delete.', v_type, p_log_id;
        RETURN;
    END IF;

    -- Block deletion if still Ongoing
    IF v_watch_status = 'Ongoing' THEN
        RAISE EXCEPTION 'Cannot delete log ID %: entry is still Ongoing.', p_log_id;
    END IF;

    -- Delete (fn_sync_latest_log and fn_sync_media_status fire automatically)
    IF v_type = 'MOVIE' THEN
        DELETE FROM watchlogs.movie_log WHERE log_id = p_log_id;
    ELSIF v_type = 'SERIES' THEN
        DELETE FROM watchlogs.series_log WHERE log_id = p_log_id;
    END IF;

    RAISE NOTICE '% log ID % deleted successfully.', v_type, p_log_id;
END;
$procedure$;