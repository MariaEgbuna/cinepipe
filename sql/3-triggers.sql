-- ╔══════════════════════════════════════════════════════════════╗
-- ║  archive.fn_audit_deletions                                  ║
-- ║  Saves a copy of every deleted record to the recycle bin     ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  RUNS          after a row is deleted from series_metadata,  ║
-- ║                movie_metadata, series_log or movie_log       ║
-- ║  WHAT IT DOES  Stores the deleted row as JSON. Metadata rows ║
-- ║                go to archive.metadata_audit and log rows go  ║
-- ║                to archive.log_audit.                         ║
-- ║  TRIGGERS      trg_audit_series_metadata,                    ║
-- ║                trg_audit_movie_metadata,                     ║
-- ║                trg_audit_series_log, trg_audit_movie_log     ║
-- ║  NOTE          The Recovery tools in v_admin_toolbox restore ║
-- ║                from these copies.                            ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE FUNCTION archive.fn_audit_deletions()
RETURNS trigger AS $$
BEGIN
    IF TG_TABLE_NAME = 'series_metadata' THEN
        INSERT INTO archive.metadata_audit (entity_id, content_type, original_data)
        VALUES (OLD.series_id, 'series', to_jsonb(OLD));

    ELSIF TG_TABLE_NAME = 'movie_metadata' THEN
        INSERT INTO archive.metadata_audit (entity_id, content_type, original_data)
        VALUES (OLD.movie_id, 'movie', to_jsonb(OLD));

    ELSIF TG_TABLE_NAME = 'series_log' THEN
        INSERT INTO archive.log_audit (log_id, entity_id, content_type, row_data)
        VALUES (OLD.log_id, OLD.series_id, 'series', to_jsonb(OLD));

    ELSIF TG_TABLE_NAME = 'movie_log' THEN
        INSERT INTO archive.log_audit (log_id, entity_id, content_type, row_data)
        VALUES (OLD.log_id, OLD.movie_id, 'movie', to_jsonb(OLD) );
    END IF;
    
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

-- Metadata Triggers (Registry Schema)
CREATE TRIGGER trg_audit_series_metadata
AFTER DELETE ON registry.series_metadata
FOR EACH ROW EXECUTE FUNCTION archive.fn_audit_deletions();

CREATE TRIGGER trg_audit_movie_metadata
AFTER DELETE ON registry.movie_metadata
FOR EACH ROW EXECUTE FUNCTION archive.fn_audit_deletions();

-- Log Triggers (Watchlogs Schema)
CREATE TRIGGER trg_audit_series_log
AFTER DELETE ON watchlogs.series_log
FOR EACH ROW EXECUTE FUNCTION archive.fn_audit_deletions();

CREATE TRIGGER trg_audit_movie_log
AFTER DELETE ON watchlogs.movie_log
FOR EACH ROW EXECUTE FUNCTION archive.fn_audit_deletions();


-- ╔══════════════════════════════════════════════════════════════╗
-- ║  public.fn_clean_dates_logic                                 ║
-- ║  Keeps every calendar row in step with its date              ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  RUNS          before a row is added to or changed in        ║
-- ║                dates_table                                   ║
-- ║  WHAT IT DOES  Recalculates the year, quarter, month number, ║
-- ║                short month name, short day name, day of week ║
-- ║                number and weekend flag from date_key, so     ║
-- ║                they can never disagree with the date.        ║
-- ║  TRIGGERS      trg_clean_dates                               ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE FUNCTION public.fn_clean_dates_logic()
RETURNS TRIGGER AS $$
BEGIN
    NEW.date_year := EXTRACT(YEAR FROM NEW.date_key)::SMALLINT;
    NEW.month_num := EXTRACT(MONTH FROM NEW.date_key)::SMALLINT;
    NEW.quarters  := EXTRACT(QUARTER FROM NEW.date_key)::SMALLINT;
    NEW.month_short := TO_CHAR(NEW.date_key, 'Mon');
    NEW.day_short   := TO_CHAR(NEW.date_key, 'Dy');
    NEW.day_of_week_index := EXTRACT(ISODOW FROM NEW.date_key)::SMALLINT;
    NEW.is_weekend := NEW.day_of_week_index IN (6, 7);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_clean_dates 
BEFORE INSERT OR UPDATE ON public.dates_table 
FOR EACH ROW EXECUTE FUNCTION public.fn_clean_dates_logic();

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  watchlogs.fn_sync_media_status                              ║
-- ║  Marks a series or movie as Logged or Backlog                ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  RUNS          after a log is added, changed or deleted      ║
-- ║  WHAT IT DOES  If the movie or series has at least one log,  ║
-- ║                its log_status becomes Logged. If it has      ║
-- ║                none, it goes back to Backlog.                ║
-- ║  TRIGGERS      trg_sync_movie_status, trg_sync_series_status ║
-- ║  NOTE          Only logs are counted. seasons_pre_log is not ║
-- ║                checked here.                                 ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE FUNCTION watchlogs.fn_sync_media_status()
RETURNS TRIGGER AS $$
DECLARE
    v_id INTEGER;
BEGIN
    -- Movie Logic
    IF TG_TABLE_NAME = 'movie_log' THEN
        v_id := COALESCE(NEW.movie_id, OLD.movie_id);
        
        IF EXISTS (SELECT 1 FROM watchlogs.movie_log WHERE movie_id = v_id) THEN
            UPDATE registry.movie_metadata SET log_status = 'Logged' WHERE movie_id = v_id AND log_status != 'Logged';
        ELSE
            UPDATE registry.movie_metadata SET log_status = 'Backlog' WHERE movie_id = v_id AND log_status != 'Backlog';
        END IF;

    -- Series Logic
    ELSIF TG_TABLE_NAME = 'series_log' THEN
        v_id := COALESCE(NEW.series_id, OLD.series_id);
        
        IF EXISTS (SELECT 1 FROM watchlogs.series_log WHERE series_id = v_id) THEN
            UPDATE registry.series_metadata SET log_status = 'Logged' WHERE series_id = v_id AND log_status != 'Logged';
        ELSE
            UPDATE registry.series_metadata SET log_status = 'Backlog' WHERE series_id = v_id AND log_status != 'Backlog';
        END IF;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sync_movie_status
AFTER INSERT OR UPDATE OR DELETE ON watchlogs.movie_log
FOR EACH ROW EXECUTE FUNCTION watchlogs.fn_sync_media_status();

CREATE TRIGGER trg_sync_series_status
AFTER INSERT OR UPDATE OR DELETE ON watchlogs.series_log
FOR EACH ROW EXECUTE FUNCTION watchlogs.fn_sync_media_status();

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  watchlogs.fn_sync_latest_log                                ║
-- ║  Keeps latest_log_id pointing at the newest log              ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  RUNS          after a log is added, changed or deleted      ║
-- ║  WHAT IT DOES  Sets latest_log_id on the movie or series to  ║
-- ║                its highest log_id. If its last log is        ║
-- ║                deleted, the link is cleared.                 ║
-- ║  TRIGGERS      trg_sync_movie_latest_log,                    ║
-- ║                trg_sync_series_latest_log                    ║
-- ║  NOTE          Newest means the highest log_id, not the      ║
-- ║                latest date.                                  ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE FUNCTION watchlogs.fn_sync_latest_log()
RETURNS TRIGGER AS $$
DECLARE
    v_id INTEGER;
BEGIN
    -- Movie Logic
    IF TG_TABLE_NAME = 'movie_log' THEN
        v_id := COALESCE(NEW.movie_id, OLD.movie_id);

        UPDATE registry.movie_metadata
        SET latest_log_id = (
            SELECT MAX(log_id)
            FROM watchlogs.movie_log
            WHERE movie_id = v_id
        )
        WHERE movie_id = v_id;

    -- Series Logic
    ELSIF TG_TABLE_NAME = 'series_log' THEN
        v_id := COALESCE(NEW.series_id, OLD.series_id);

        UPDATE registry.series_metadata
        SET latest_log_id = (
            SELECT MAX(log_id)
            FROM watchlogs.series_log
            WHERE series_id = v_id
        )
        WHERE series_id = v_id;

    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sync_movie_latest_log
AFTER INSERT OR UPDATE OR DELETE ON watchlogs.movie_log
FOR EACH ROW EXECUTE FUNCTION watchlogs.fn_sync_latest_log();

CREATE TRIGGER trg_sync_series_latest_log
AFTER INSERT OR UPDATE OR DELETE ON watchlogs.series_log
FOR EACH ROW EXECUTE FUNCTION watchlogs.fn_sync_latest_log();

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  Latest log backfill                                         ║
-- ║  One-time recalculation of latest_log_id for all movies and  ║
-- ║  series                                                      ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  RUNS          once, each time this file is run              ║
-- ║  WHAT IT DOES  Sets latest_log_id to each movie's and        ║
-- ║                series' highest log_id.                       ║
-- ║  NOTE          The trigger above keeps the value correct     ║
-- ║                afterwards. This is safe to run again if the  ║
-- ║                values ever look wrong.                       ║
-- ╚══════════════════════════════════════════════════════════════╝
UPDATE registry.movie_metadata AS mm
SET latest_log_id = sub.max_log_id
FROM (
    -- Get the highest log_id per movie_id from the log table
    SELECT movie_id, MAX(log_id) AS max_log_id
    FROM watchlogs.movie_log
    GROUP BY movie_id
) AS sub
WHERE mm.movie_id = sub.movie_id;

UPDATE registry.series_metadata AS sm
SET latest_log_id = sub.max_log_id
FROM (
    -- Get the highest log_id per series_id from the log table
    SELECT series_id, MAX(log_id) AS max_log_id
    FROM watchlogs.series_log
    GROUP BY series_id
) AS sub
WHERE sm.series_id = sub.series_id;


-- ╔══════════════════════════════════════════════════════════════╗
-- ║  watchlogs.fn_process_log_entry                              ║
-- ║  Checks and tidies every watch log before it is saved        ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  RUNS          before a row is added to or changed in        ║
-- ║                series_log or movie_log                       ║
-- ║  CHECKS        Start date cannot be in the future (Lagos     ║
-- ║                time). End date cannot be before start date.  ║
-- ║                A season number cannot be above the series'   ║
-- ║                total seasons.                                ║
-- ║  REWATCH       Set automatically. Movie: another Finished or ║
-- ║                Ongoing log exists. Series: the season is     ║
-- ║                within seasons_pre_log, or another Finished   ║
-- ║                or Ongoing log of that season exists.         ║
-- ║  SERIES        Dropped and On-Hold clear the rating. All     ║
-- ║                episodes watched makes it Finished. Anything  ║
-- ║                else becomes Ongoing with no rating or end    ║
-- ║                date. Episodes watched are capped at the      ║
-- ║                total.                                        ║
-- ║  MOVIES        Dropped clears the rating. An end date or     ║
-- ║                Finished status makes it Finished. Anything   ║
-- ║                else is Ongoing with no rating. Pace: Stalled ║
-- ║                (Dropped), Ongoing, Normal (same day), Split  ║
-- ║                View (1 to 2 days), Slow (longer).            ║
-- ║  VERDICT       From the rating: 8.5+ Excellent, 7+ Good, 5+  ║
-- ║                Average, 3+ Subpar, below 3 Poor. A Dropped   ║
-- ║                log with no rating gets N/A.                  ║
-- ║  ALSO          Dropped and Finished logs with no end date    ║
-- ║                get today's date. Fills days_to_finish (end   ║
-- ║                minus start plus 1) and refreshes             ║
-- ║                last_updated on updates.                      ║
-- ║  TRIGGERS      trg_process_series_log, trg_process_movie_log ║
-- ║  NOTE          A rewatch flag you set to TRUE stays TRUE.    ║
-- ║                Seasons up to seasons_pre_log count as        ║
-- ║                rewatches even on their first logged watch,   ║
-- ║                so the rating views show them as Original     ║
-- ║                (Not Logged).                                 ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE FUNCTION watchlogs.fn_process_log_entry()
RETURNS trigger AS $$
DECLARE
    v_today DATE := (now() AT TIME ZONE 'Africa/Lagos')::DATE; 
    v_max_seasons INT;
    v_pre_log INT;
BEGIN
    -- Block future dates
    IF NEW.start_date > v_today THEN
        RAISE EXCEPTION 'Start date (%) cannot be in the future.', NEW.start_date;
    END IF;

    -- Metadata Validation (Stopping me from logging a wrong season number)
    IF TG_TABLE_NAME = 'series_log' THEN
        SELECT total_seasons, seasons_pre_log INTO v_max_seasons, v_pre_log
        FROM registry.series_metadata WHERE series_id = NEW.series_id;
        
        IF NEW.season_no > v_max_seasons THEN
            RAISE EXCEPTION 'Season % does not exist. Limit is %.', NEW.season_no, v_max_seasons;
        END IF;
    END IF;

   -- Automatic Rewatch Detection
		IF (TG_OP = 'INSERT') OR (OLD.watch_status IS DISTINCT FROM NEW.watch_status) THEN
		
		    IF (NEW.watch_status IN ('Finished', 'Ongoing')) THEN
		
		        -- Only auto-detect if is_rewatch is not already TRUE
		        IF (COALESCE(NEW.is_rewatch, FALSE) = FALSE) THEN
		            IF TG_TABLE_NAME = 'movie_log' THEN
		                IF EXISTS (
		                    SELECT 1 
		                    FROM watchlogs.movie_log 
		                    WHERE movie_id = NEW.movie_id 
		                      AND watch_status IN ('Finished', 'Ongoing')
		                      -- IMPORTANT: Exclude the current record strictly by primary key
		                      AND log_id <> NEW.log_id 
		                ) THEN
		                    NEW.is_rewatch := TRUE;
		                END IF;
		
		            ELSIF TG_TABLE_NAME = 'series_log' THEN
		                IF NEW.season_no <= COALESCE(v_pre_log, 0) OR EXISTS (
		                    SELECT 1 
		                    FROM watchlogs.series_log 
		                    WHERE series_id = NEW.series_id 
		                      AND season_no = NEW.season_no 
		                      AND watch_status IN ('Finished', 'Ongoing')
		                      AND log_id <> NEW.log_id 
		                ) THEN
		                    NEW.is_rewatch := TRUE;
		                END IF;
		            END IF;
		        END IF;
		    END IF;
		END IF;

    -- Watch Status & Episode Logic
	  IF TG_TABLE_NAME = 'series_log' THEN
		    IF NEW.episodes_watched > NEW.total_episodes AND NEW.total_episodes > 0 THEN
		        NEW.episodes_watched := NEW.total_episodes;
		    END IF;
		
		    -- 2. State-based logic
		    IF NEW.watch_status = 'Dropped' THEN
		        NEW.rating := NULL;
		        NEW.end_date := COALESCE(NEW.end_date, v_today);
		    ELSIF NEW.watch_status = 'On-Hold' THEN
		        NEW.rating := NULL;
		        NEW.end_date := NULL;
		    ELSIF (NEW.episodes_watched = NEW.total_episodes AND NEW.total_episodes > 0) THEN
		        NEW.watch_status := 'Finished';
		        NEW.end_date := COALESCE(NEW.end_date, v_today);
		    ELSE
		        NEW.watch_status := 'Ongoing';
		        NEW.end_date := NULL;
		        NEW.rating := NULL;
		    END IF;

    ELSIF TG_TABLE_NAME = 'movie_log' THEN
	    IF NEW.watch_status = 'Dropped' THEN
	        NEW.rating := NULL; 
	        NEW.end_date := COALESCE(NEW.end_date, v_today);
	    
	    ELSIF NEW.end_date IS NOT NULL OR NEW.watch_status = 'Finished' THEN 
	        NEW.watch_status := 'Finished';
	        NEW.end_date := COALESCE(NEW.end_date, v_today);

	    ELSE
	        NEW.watch_status := 'Ongoing';
	        NEW.rating := NULL; 
	    END IF;

	        -- Watch Pace Logic
        NEW.watch_pace := CASE 
            WHEN NEW.watch_status = 'Dropped' THEN 'Stalled'
            WHEN NEW.watch_status = 'Ongoing' THEN 'Ongoing'
            WHEN (NEW.end_date - NEW.start_date) = 0 THEN 'Normal'
            WHEN (NEW.end_date - NEW.start_date) <= 2 THEN 'Split View' 
            ELSE 'Slow'
        END;

	END IF;

	-- Score Verdict (Cos I am too lazy to manually write it)
	IF NEW.rating IS NOT NULL THEN
	    NEW.score_verdict := CASE 
	        WHEN NEW.rating >= 8.5 THEN 'Excellent'
	        WHEN NEW.rating >= 7.0 THEN 'Good'
	        WHEN NEW.rating >= 5.0 THEN 'Average'
	        WHEN NEW.rating >= 3.0 THEN 'Subpar'
	        ELSE 'Poor'
	    END;
	ELSE
	    IF NEW.watch_status = 'Dropped' THEN
	        NEW.score_verdict := 'N/A';
	    ELSE
	        NEW.score_verdict := NULL;
	    END IF;
	END IF;

    -- Block future dates (for end date)
    IF NEW.end_date IS NOT NULL THEN
        IF NEW.end_date < NEW.start_date THEN 
            RAISE EXCEPTION 'End date (%) cannot be before start date (%).', NEW.end_date, NEW.start_date; 
        END IF;
    END IF;

	-- Days used to complete a show or movie
	IF NEW.end_date IS NOT NULL AND NEW.start_date IS NOT NULL
		THEN NEW.days_to_finish := (NEW.end_date - NEW.start_date) + 1;
	ELSE NEW.days_to_finish := NULL;
	END IF; 

    -- Update Timestamp
    IF TG_OP = 'UPDATE' THEN
        NEW.last_updated := CURRENT_TIMESTAMP;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_process_series_log
BEFORE INSERT OR UPDATE ON watchlogs.series_log
FOR EACH ROW EXECUTE FUNCTION watchlogs.fn_process_log_entry();

CREATE TRIGGER trg_process_movie_log
BEFORE INSERT OR UPDATE ON watchlogs.movie_log
FOR EACH ROW EXECUTE FUNCTION watchlogs.fn_process_log_entry();


-- ╔══════════════════════════════════════════════════════════════╗
-- ║  registry.fn_process_metadata                                ║
-- ║  Tidies titles, genres and details, and creates the movie    ║
-- ║  or series code                                              ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  RUNS          before a row is added to or changed in        ║
-- ║                series_metadata or movie_metadata             ║
-- ║  TITLES        Trimmed and Title Cased. A letter after an    ║
-- ║                apostrophe is lowercased. II, III and IV are  ║
-- ║                fixed, and Vs becomes vs.                     ║
-- ║  GENRES        Split on &, trimmed, Title Cased, any Sci-Fi  ║
-- ║                spelling becomes SciFi, and duplicates are    ║
-- ║                removed.                                      ║
-- ║  OTHER         Series platform is uppercased. Movie director ║
-- ║                is Title Cased and movie country is           ║
-- ║                uppercased.                                   ║
-- ║  CODE          Made on insert, like AVA-26: the first 3      ║
-- ║                letters of the title (ignoring a leading The, ║
-- ║                A or An, padded with X) plus the last 2       ║
-- ║                digits of the year. If a movie or series      ║
-- ║                already has that code, a number is added,     ║
-- ║                like KIL-23-1.                                ║
-- ║  ALSO          Refreshes last_updated on updates. A movie    ║
-- ║                with the same title and year as an existing   ║
-- ║                one reuses its code, which the unique rule on ║
-- ║                movie_code then rejects.                      ║
-- ║  TRIGGERS      trg_process_series_metadata,                  ║
-- ║                trg_process_movie_metadata                    ║
-- ║  NOTE          The added number is counted within each       ║
-- ║                table, so a movie and a series can end up     ║
-- ║                with the same numbered code.                  ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE OR REPLACE FUNCTION registry.fn_process_metadata()
RETURNS TRIGGER AS $$
DECLARE
    -- Sanitization Variables
    v_title_parts   TEXT[];
    v_dir_parts     TEXT[];
    v_genre_item    TEXT;
    v_split_genre   TEXT;
    v_cleaned_genres TEXT[] := '{}';
    -- ID Generation Variables
    v_clean_title   TEXT;
    v_base_prefix   TEXT;
    v_base_code     TEXT;
    v_final_code    TEXT;
    v_next_num      INTEGER;
    v_existing_id   TEXT;
BEGIN
    NEW.title := INITCAP(TRIM(NEW.title));
    v_title_parts := STRING_TO_ARRAY(NEW.title, '''');
    IF ARRAY_LENGTH(v_title_parts, 1) > 1 THEN
        FOR i IN 2..ARRAY_LENGTH(v_title_parts, 1) LOOP
            v_title_parts[i] := LOWER(LEFT(v_title_parts[i], 1)) || SUBSTR(v_title_parts[i], 2);
        END LOOP;
        NEW.title := ARRAY_TO_STRING(v_title_parts, '''');
    END IF;

    NEW.title := REGEXP_REPLACE(NEW.title, '\yIii\y', 'III', 'g');
    NEW.title := REGEXP_REPLACE(NEW.title, '\yIi\y', 'II', 'g');
    NEW.title := REGEXP_REPLACE(NEW.title, '\yIv\y', 'IV', 'g');
    NEW.title := REGEXP_REPLACE(NEW.title, '\yVs\y', 'vs', 'g');

    IF NEW.genres IS NOT NULL THEN
        FOREACH v_genre_item IN ARRAY NEW.genres LOOP
            FOREACH v_split_genre IN ARRAY STRING_TO_ARRAY(v_genre_item, '&') LOOP
                v_split_genre := TRIM(v_split_genre);
                IF v_split_genre ~* 'Sci-Fi|Sci Fi|SciFi|Science Fiction' THEN
                    v_split_genre := 'SciFi';
                ELSE
                    v_split_genre := INITCAP(v_split_genre);
                END IF;
                IF NOT (v_cleaned_genres @> ARRAY[v_split_genre]) THEN
                    v_cleaned_genres := ARRAY_APPEND(v_cleaned_genres, v_split_genre);
                END IF;
            END LOOP;
        END LOOP;
        NEW.genres := v_cleaned_genres;
    END IF;

    IF TG_TABLE_NAME = 'series_metadata' THEN
        IF NEW.platform IS NOT NULL THEN
            NEW.platform := UPPER(TRIM(NEW.platform));
        END IF;
    ELSIF TG_TABLE_NAME = 'movie_metadata' THEN
        IF NEW.director IS NOT NULL THEN
            NEW.director := INITCAP(TRIM(NEW.director));
            v_dir_parts := STRING_TO_ARRAY(NEW.director, '''');
            IF ARRAY_LENGTH(v_dir_parts, 1) > 1 THEN
                FOR i IN 2..ARRAY_LENGTH(v_dir_parts, 1) LOOP
                    v_dir_parts[i] := LOWER(LEFT(v_dir_parts[i], 1)) || SUBSTR(v_dir_parts[i], 2);
                END LOOP;
                NEW.director := ARRAY_TO_STRING(v_dir_parts, '''');
            END IF;
        END IF;
        IF NEW.country IS NOT NULL THEN
            NEW.country := UPPER(TRIM(NEW.country));
        END IF;
    END IF;

    -- ==========================================
    IF TG_OP = 'INSERT' THEN

        IF TG_TABLE_NAME = 'movie_metadata' THEN
            SELECT movie_code INTO v_existing_id FROM registry.movie_metadata
             WHERE title = NEW.title AND year_released = NEW.year_released LIMIT 1;
            
            IF v_existing_id IS NOT NULL THEN
                NEW.movie_code := v_existing_id;
            END IF;
            
            IF NEW.movie_code IS NULL OR TRIM(NEW.movie_code) = '' THEN
                v_clean_title := REGEXP_REPLACE(TRIM(NEW.title), '^\s*(the|a|an)\s+', '', 'i');
                v_clean_title := REGEXP_REPLACE(v_clean_title, '[^a-zA-Z0-9]', '', 'g');
                v_base_prefix := UPPER(RPAD(LEFT(v_clean_title, 3), 3, 'X'));
                v_base_code   := v_base_prefix || '-' || RIGHT(NEW.year_released::TEXT, 2);

                -- Global Collision Check
                IF EXISTS (SELECT 1 FROM registry.movie_metadata WHERE movie_code = v_base_code
                           UNION ALL
                           SELECT 1 FROM registry.series_metadata WHERE series_code = v_base_code) THEN
                    SELECT COALESCE(MAX(CAST(SUBSTRING(movie_code FROM '-([0-9]+)$') AS INTEGER)), 0) + 1
                      INTO v_next_num FROM registry.movie_metadata
                     WHERE movie_code ~ ('^' || v_base_code || '-[0-9]+$');
                    NEW.movie_code := v_base_code || '-' || COALESCE(v_next_num, 1);
                ELSE
                    NEW.movie_code := v_base_code;
                END IF;
            END IF;

        ELSIF TG_TABLE_NAME = 'series_metadata' THEN
            IF NEW.series_code IS NULL OR TRIM(NEW.series_code) = '' THEN
                v_clean_title := REGEXP_REPLACE(TRIM(NEW.title), '^\s*(the|a|an)\s+', '', 'i');
                v_clean_title := REGEXP_REPLACE(v_clean_title, '[^a-zA-Z0-9]', '', 'g');
                v_base_prefix := UPPER(RPAD(LEFT(v_clean_title, 3), 3, 'X'));
                v_base_code   := v_base_prefix || '-' || RIGHT(NEW.year_released::TEXT, 2);

                -- Global Collision Check
                IF EXISTS (SELECT 1 FROM registry.series_metadata WHERE series_code = v_base_code
                           UNION ALL
                           SELECT 1 FROM registry.movie_metadata WHERE movie_code = v_base_code) THEN
                    SELECT COALESCE(MAX(CAST(SUBSTRING(series_code FROM '-([0-9]+)$') AS INTEGER)), 0) + 1
                      INTO v_next_num FROM registry.series_metadata
                     WHERE series_code ~ ('^' || v_base_code || '-[0-9]+$');
                    NEW.series_code := v_base_code || '-' || COALESCE(v_next_num, 1);
                ELSE
                    NEW.series_code := v_base_code;
                END IF;
            END IF;
        END IF;
    END IF;

		-- Handling last_updated timestamp
	IF TG_OP = 'UPDATE' THEN
	    NEW.last_updated := CURRENT_TIMESTAMP;
	END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_process_series_metadata
BEFORE INSERT OR UPDATE ON registry.series_metadata
FOR EACH ROW EXECUTE FUNCTION registry.fn_process_metadata();

CREATE TRIGGER trg_process_movie_metadata
BEFORE INSERT OR UPDATE ON registry.movie_metadata
FOR EACH ROW EXECUTE FUNCTION registry.fn_process_metadata();