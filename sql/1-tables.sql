-- ╔══════════════════════════════════════════════════════════════╗
-- ║  Schemas                                                     ║
-- ║  Creates the three schemas that group the tables             ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  REGISTRY      series and movie details (the catalogue)      ║
-- ║  WATCHLOGS     the watch history for series and movies       ║
-- ║  ARCHIVE       recycle bin for deleted records               ║
-- ║  NOTE          dates_table and sync_state live in the        ║
-- ║                default public schema.                        ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE SCHEMA registry;
CREATE SCHEMA archive;
CREATE SCHEMA watchlogs;

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  public.dates_table                                          ║
-- ║  Calendar lookup with one row for every day                  ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  STORES        date, year, quarter, month number and short   ║
-- ║                name, short day name, day of week number,     ║
-- ║                weekend flag                                  ║
-- ║  ONE ROW PER   calendar day                                  ║
-- ║  USED BY       series_log and movie_log (start and end dates)║
-- ║  RULES         Year must be 2025 or later. Logs can only use ║
-- ║                dates that exist in this table.               ║
-- ║  NOTE          Add new years with CALL                       ║
-- ║                public.extend_calendar([YYYY]).               ║
-- ╚══════════════════════════════════════════════════════════════╝
CREATE TABLE public.dates_table (
    date_key DATE PRIMARY KEY,
    date_year SMALLINT NOT NULL CHECK (date_year >= 2025),
    quarters SMALLINT NOT NULL CHECK (quarters BETWEEN 1 AND 4), 
    month_num SMALLINT NOT NULL CHECK (month_num BETWEEN 1 AND 12),
    month_short CHAR(3) NOT NULL,
    day_short CHAR(3) NOT NULL,
    day_of_week_index SMALLINT NOT NULL CHECK (day_of_week_index BETWEEN 1 AND 7),
    is_weekend BOOLEAN NOT NULL
); 

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  registry.series_metadata                                    ║
-- ║  Details of every series I track (the catalogue)             ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  STORES        title, country, years, seasons and episodes,  ║
-- ║                average episode length, genres, platform,     ║
-- ║                status                                        ║
-- ║  ONE ROW PER   series                                        ║
-- ║  KEYS          series_code and tmdb_id must each be unique   ║
-- ║  RULES         Status is Returning, Ended, Cancelled or TBD. ║
-- ║                Log status is Backlog or Logged.              ║
-- ║  NOTE          seasons_pre_log counts seasons I watched      ║
-- ║                before I started logging.                     ║
-- ║  TRIGGERS      fn_process_metadata makes the series_code and ║
-- ║                tidies title, genres and platform. Log status ║
-- ║                and latest_log_id are kept up to date         ║
-- ║                automatically.                                ║
-- ║  NOTE          poster_path is the end of the TMDB image      ║
-- ║                address, like /abc123.jpg. The picture itself ║
-- ║                is never stored.                              ║
-- ╚══════════════════════════════════════════════════════════════╝

CREATE TABLE registry.series_metadata (
    series_id SERIAL PRIMARY KEY, 
    series_code VARCHAR(20) UNIQUE NOT NULL,
    title VARCHAR(255) NOT NULL,
    country VARCHAR(10), 
    year_released SMALLINT,
    year_completed SMALLINT,
    total_seasons SMALLINT,
    total_episodes SMALLINT,
    avg_runtime SMALLINT,
    genres TEXT[],
    platform VARCHAR(50),
    status VARCHAR(50) NOT NULL DEFAULT 'Returning' CHECK (status IN ('Returning', 'Ended', 'Cancelled', 'TBD')),
    seasons_pre_log SMALLINT NOT NULL DEFAULT 0 CONSTRAINT seasons_pre_log_check CHECK (seasons_pre_log >= 0),
    log_status  VARCHAR(20) NOT NULL DEFAULT 'Backlog' CHECK (log_status IN ('Backlog', 'Logged')),
    tmdb_id INTEGER UNIQUE NOT NULL,
    poster_path TEXT CONSTRAINT series_poster_path_check CHECK (poster_path IS NULL OR poster_path ~ '^/[A-Za-z0-9_.-]+$'),    
    last_updated TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  registry.movie_metadata                                     ║
-- ║  Details of every movie I track (the catalogue)              ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  STORES        title, year, country, director, runtime,      ║
-- ║                genres, and whether I watched it before       ║
-- ║                I started logging                             ║
-- ║  ONE ROW PER   movie                                         ║
-- ║  KEYS          movie_code and tmdb_id must each be unique    ║
-- ║  RULES         Log status is Backlog or Logged.              ║
-- ║  NOTE          watched_pre_log marks a movie I watched       ║
-- ║                before I started logging. I set it by         ║
-- ║                hand, and it defaults to false. When it is    ║
-- ║                true, the first log of that movie is set as   ║
-- ║                a rewatch automatically.                      ║
-- ║  TRIGGERS      fn_process_metadata makes the movie_code and  ║
-- ║                tidies title, genres, director and country.   ║
-- ║                fn_process_log_entry reads watched_pre_log    ║
-- ║                to decide the rewatch flag. Log status and    ║
-- ║                latest_log_id are kept up to date             ║
-- ║                automatically.                                ║
-- ║  NOTE          poster_path is the end of the TMDB image      ║
-- ║                address, like /abc123.jpg. The picture itself ║
-- ║                is never stored.                              ║
-- ╚══════════════════════════════════════════════════════════════╝

CREATE TABLE registry.movie_metadata ( 
    movie_id SERIAL PRIMARY KEY,
    movie_code VARCHAR(20) UNIQUE NOT NULL,
    title TEXT NOT NULL,
    year_released SMALLINT,
    country VARCHAR(10),
    director TEXT NULL,
    runtime_mins SMALLINT,
    genres TEXT[],
    tmdb_id INTEGER UNIQUE NOT NULL,
    log_status VARCHAR(20) NOT NULL DEFAULT 'Backlog' CHECK (log_status IN ('Backlog', 'Logged')),
    watched_pre_log BOOLEAN NOT NULL DEFAULT FALSE,
    poster_path TEXT CONSTRAINT movie_poster_path_check CHECK (poster_path IS NULL OR poster_path ~ '^/[A-Za-z0-9_.-]+$'),
    last_updated TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  watchlogs.series_log                                        ║
-- ║  the watch history for series, one full season at a time     ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  STORES        season number, episode counts, dates, watch   ║
-- ║                type, status, device, rating, review          ║
-- ║  ONE ROW PER   season watch (a rewatch gets its own row)     ║
-- ║  LINKS TO      series_metadata and dates_table               ║
-- ║  RULES         A series that still has logs cannot be        ║
-- ║                deleted. End date cannot be before start      ║
-- ║                date. Episodes watched cannot be more than    ║
-- ║                total episodes. Rating is 1 to 10.            ║
-- ║  NOTE          Watch type: Background, Binge, Casual, Batch, ║
-- ║                Daily or Live. Status: Ongoing, Finished, On- ║
-- ║                Hold or Dropped. Device: Phone, Laptop or     ║
-- ║                Both.                                         ║
-- ║  TRIGGERS      fn_process_log_entry decides the rewatch      ║
-- ║                flag, status, end date, days_to_finish and    ║
-- ║                score_verdict, and clears the rating unless   ║
-- ║                the season is Finished. Deleted rows are      ║
-- ║                copied to the recycle bin.                    ║
-- ╚══════════════════════════════════════════════════════════════╝

CREATE TABLE watchlogs.series_log (
    log_id SERIAL PRIMARY KEY,
    series_id INTEGER NOT NULL REFERENCES registry.series_metadata(series_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    start_date DATE NOT NULL REFERENCES public.dates_table(date_key) ON DELETE RESTRICT,
    end_date DATE REFERENCES public.dates_table(date_key) ON DELETE RESTRICT,
    season_no SMALLINT NOT NULL,
    total_episodes SMALLINT NOT NULL,
    episodes_watched SMALLINT NOT NULL DEFAULT 0,
    days_to_finish INTEGER,
    watch_type VARCHAR(30) DEFAULT 'Casual' NOT NULL CHECK (watch_type IN ('Background', 'Binge', 'Casual', 'Batch', 'Daily', 'Live')),
    watch_status VARCHAR(20) DEFAULT 'Ongoing' NOT NULL CHECK (watch_status IN ('Ongoing', 'Finished', 'On-Hold', 'Dropped')),
    device VARCHAR(20) DEFAULT 'Laptop' NOT NULL CHECK (device IN ('Phone', 'Laptop', 'Both')),
    is_rewatch BOOLEAN NOT NULL DEFAULT FALSE,
    rating NUMERIC(3,1) CHECK (rating >= 1 AND rating <= 10),
    score_verdict VARCHAR(10) CHECK (score_verdict IN ('Excellent', 'Good', 'Average', 'Subpar', 'Poor', 'N/A')),
    review TEXT DEFAULT 'TBA' NOT NULL,
    last_updated TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT check_dates CHECK (end_date IS NULL OR end_date >= start_date),
    CONSTRAINT limit_episodes_watched CHECK (episodes_watched <= total_episodes)
);

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  watchlogs.movie_log                                         ║
-- ║  the watch history for movies                                ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  STORES        dates, watch status, pace, device, rating,    ║
-- ║                review                                        ║
-- ║  ONE ROW PER   movie watch (a rewatch gets its own row)      ║
-- ║  LINKS TO      movie_metadata and dates_table                ║
-- ║  RULES         A movie that still has logs cannot be         ║
-- ║                deleted. End date cannot be before start      ║
-- ║                date. A rating is only allowed on Finished    ║
-- ║                logs, and must be above 0 up to 10.           ║
-- ║  NOTE          Status: Ongoing, Finished or Dropped (movies  ║
-- ║                have no On-Hold). Pace: Stalled, Ongoing,     ║
-- ║                Normal, Split View or Slow. Device: Phone,    ║
-- ║                Laptop or Both.                               ║
-- ║  TRIGGERS      fn_process_log_entry decides the rewatch      ║
-- ║                flag, status, end date, pace, days_to_finish  ║
-- ║                and score_verdict, and clears the rating      ║
-- ║                unless the movie is Finished. Deleted rows    ║
-- ║                are copied to the recycle bin.                ║
-- ╚══════════════════════════════════════════════════════════════╝

CREATE TABLE watchlogs.movie_log (
    log_id SERIAL PRIMARY KEY,
    movie_id INTEGER NOT NULL REFERENCES registry.movie_metadata(movie_id) ON UPDATE CASCADE ON DELETE RESTRICT,
    start_date DATE NOT NULL DEFAULT CURRENT_DATE REFERENCES public.dates_table(date_key),
    end_date DATE REFERENCES public.dates_table(date_key),
    days_to_finish INTEGER,
    is_rewatch BOOLEAN DEFAULT FALSE,
    watch_status VARCHAR(20) DEFAULT 'Ongoing' NOT NULL CHECK (watch_status IN ('Finished', 'Dropped', 'Ongoing')),
    device VARCHAR(20) DEFAULT 'Laptop' NOT NULL CHECK (device IN ('Phone', 'Laptop', 'Both')),
	watch_pace VARCHAR(20) CHECK (watch_pace IN ('Stalled', 'Ongoing', 'Normal', 'Split View', 'Slow')),
	rating NUMERIC(3, 1) CHECK (rating > 0 AND rating <= 10),
	score_verdict VARCHAR(10) CHECK (score_verdict IN ('Excellent', 'Good', 'Average', 'Subpar', 'Poor', 'N/A')),
    review TEXT DEFAULT 'TBA' NOT NULL,
    last_updated TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_rating_only_if_finished CHECK ((watch_status = 'Finished' AND rating IS NOT NULL) OR (rating IS NULL)),
    CONSTRAINT chk_movie_finish_date CHECK (end_date IS NULL OR end_date >= start_date)
);

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  archive.metadata_audit                                      ║
-- ║  Recycle bin for deleted movies and series                   ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  STORES        the id, type (series or movie), when and by   ║
-- ║                whom it was deleted, and a full copy of the   ║
-- ║                original row as JSON                          ║
-- ║  ONE ROW PER   deleted movie or series                       ║
-- ║  NOTE          The Recovery tools in v_admin_toolbox read    ║
-- ║                from here.                                    ║
-- ╚══════════════════════════════════════════════════════════════╝

CREATE TABLE archive.metadata_audit (
    audit_id      BIGSERIAL PRIMARY KEY,
    entity_id     INTEGER NOT NULL,
    content_type  TEXT NOT NULL CHECK (content_type IN ('series', 'movie')),
    deleted_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_by    TEXT NOT NULL DEFAULT CURRENT_USER,
    original_data JSONB
);

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  archive.log_audit                                           ║
-- ║  Recycle bin for deleted logs                                ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  STORES        the log id, the movie or series id, type,     ║
-- ║                when and by whom it was deleted, and a full   ║
-- ║                copy of the row as JSON                       ║
-- ║  ONE ROW PER   deleted log                                   ║
-- ║  NOTE          The Recovery tools in v_admin_toolbox read    ║
-- ║                from here.                                    ║
-- ╚══════════════════════════════════════════════════════════════╝

CREATE TABLE archive.log_audit (
    audit_id      BIGSERIAL PRIMARY KEY,
    log_id        INTEGER NOT NULL,
    entity_id     INTEGER NOT NULL,
    content_type  TEXT NOT NULL CHECK (content_type IN ('series', 'movie')),
    deleted_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_by    TEXT NOT NULL DEFAULT CURRENT_USER,
    row_data      JSONB
);

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  Indexes                                                     ║
-- ║  Speed up common lookups, grouped by schema below            ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  PUBLIC        dates_table by year and month, and by day of  ║
-- ║                week                                          ║
-- ║  REGISTRY      country, genres and years for both catalogue  ║
-- ║                tables                                        ║
-- ║  WATCHLOGS     series or movie id, watch status, start date  ║
-- ║                and end date for both logs                    ║
-- ║  ARCHIVE       type with entity id, and log id               ║
-- ║  NOTE          Primary keys and unique columns get an index  ║
-- ║                automatically, so they are not listed.        ║
-- ╚══════════════════════════════════════════════════════════════╝

-- Public Schema (dates_table)
CREATE INDEX idx_dates_year_month ON public.dates_table (date_year, month_num);
CREATE INDEX idx_dates_day_of_week ON public.dates_table (day_of_week_index);

-- Registry Schema (series_metadata and movie_metadata)
CREATE INDEX idx_series_country ON registry.series_metadata (country);
CREATE INDEX idx_series_genres ON registry.series_metadata USING GIN (genres);
CREATE INDEX idx_series_years ON registry.series_metadata (year_released, year_completed);

CREATE INDEX idx_movie_country ON registry.movie_metadata (country);
CREATE INDEX idx_movie_years ON registry.movie_metadata (year_released);
CREATE INDEX idx_movie_genres ON registry.movie_metadata USING GIN (genres);

-- Watchlogs Schema (series_log, movie_log)
CREATE INDEX idx_series_id ON watchlogs.series_log (series_id);
CREATE INDEX idx_series_watch_status ON watchlogs.series_log (watch_status);
CREATE INDEX idx_series_log_dates ON watchlogs.series_log (start_date);
CREATE INDEX idx_series_log_end_date ON watchlogs.series_log (end_date);


CREATE INDEX idx_movie_id ON watchlogs.movie_log (movie_id);
CREATE INDEX idx_movie_watch_status ON watchlogs.movie_log (watch_status);
CREATE INDEX idx_movie_log_dates ON watchlogs.movie_log (start_date);
CREATE INDEX idx_movie_log_end_date ON watchlogs.movie_log (end_date);

-- Archive Schema (metadata_audit, log_audit)
CREATE INDEX idx_metadata_audit_lookup ON archive.metadata_audit(content_type, entity_id);

CREATE INDEX idx_log_audit_log_id ON archive.log_audit(log_id);
CREATE INDEX idx_log_audit_lookup ON archive.log_audit(content_type, entity_id);


-- ╔══════════════════════════════════════════════════════════════╗
-- ║  Reset ID sequences                                          ║
-- ║  Run these after importing data                              ║
-- ╠══════════════════════════════════════════════════════════════╣
-- ║  WHY           An import can bring its own ids, and the      ║
-- ║                counters that hand out new ids do not know    ║
-- ║                about them. The next new row could then get   ║
-- ║                an id that is already taken.                  ║
-- ║  WHAT IT DOES  moves each counter up to the highest id in    ║
-- ║                its table                                     ║
-- ║  TABLES        movie_metadata, series_metadata, series_log,  ║
-- ║                movie_log                                     ║
-- ╚══════════════════════════════════════════════════════════════╝

-- For Metadata Tables
SELECT setval(pg_get_serial_sequence('registry.movie_metadata', 'movie_id'), (SELECT MAX(movie_id) FROM registry.movie_metadata));
SELECT setval(pg_get_serial_sequence('registry.series_metadata', 'series_id'), (SELECT MAX(series_id) FROM registry.series_metadata));

-- For Log Tables
SELECT setval(pg_get_serial_sequence('watchlogs.series_log', 'log_id'), (SELECT MAX(log_id) FROM watchlogs.series_log));
SELECT setval(pg_get_serial_sequence('watchlogs.movie_log', 'log_id'), (SELECT MAX(log_id) FROM watchlogs.movie_log));
