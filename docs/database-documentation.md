# CinePipe: Database Documentation

A PostgreSQL database that logs everything I watch: series and movies. Kdramas, j-dramas and anime are not treated as separate types. They are series or movies, with a country on each title.

This document describes what is in this repo: the SQL files in `sql/` and the Python scripts in `py/`. I also keep a second copy of the database online and use a few personal helper scripts. Those are tied to my own setup and are not part of the repo, so they only get a short mention at the end (see [Beyond this repo](#10-beyond-this-repo)).

## Contents

1. [Overview](#1-overview)
2. [Quick start](#2-quick-start)
3. [How the tables connect](#3-how-the-tables-connect)
4. [Tables](#4-tables)
5. [Automatic behaviour (triggers)](#5-automatic-behaviour-triggers)
6. [Procedures](#6-procedures)
7. [Views](#7-views)
8. [Python scripts](#8-python-scripts)
9. [Files and rebuild order](#9-files-and-rebuild-order)
10. [Beyond this repo](#10-beyond-this-repo)
11. [Known quirks](#11-known-quirks)

Other documents: the [setup guide](getting-started.md), the [system audit](system-audit.md) (recycle bin and recovery) and [view architecture and indexing](view-indexing.md).

---

## 1. Overview

The data is split into schemas, which are folders that group related tables.

| Schema | Holds |
|---|---|
| `registry` | The catalogue: one row per series and per movie (details only, no watching history) |
| `watchlogs` | The watch history: one row per season watched or per movie watched, plus most of the reporting views |
| `archive` | The recycle bin: a copy of every deleted row |
| `public` | The calendar table (`dates_table`) and the `extend_calendar` procedure |

**How data moves through the system**

1. A title is added to the catalogue, usually by a script that looks it up on TMDB (The Movie Database).
2. Each watch is logged. A series is logged one season at a time. A movie is logged once per watch. A rewatch gets its own row.
3. Database triggers tidy and check every row before it is saved (see section 5).
4. Views turn the logs into answers: what I am watching, where each title stands, and how my ratings changed (see section 7).

---

## 2. Quick start

1. **Set up the database.** Follow the [setup guide](getting-started.md): run the four SQL files in order, then fill the calendar.
2. **Optional: load the sample data.** `5-sample-data.sql` adds 5 series, 7 movies and their logs, so every view has something to show.
3. **Add a title.** Use `py/add_metadata.py` (it looks the title up on TMDB), or call the procedure yourself:

```sql
CALL registry.add_metadata('Movie', 'Inception', 2010, 'US', 'Christopher Nolan', 148,
                           ARRAY['Action', 'Science Fiction', 'Adventure'], 27205);
```

4. **Log a watch.** Always through a procedure, one for series and one for movies:

```sql
CALL watchlogs.movie_watch('INC-10', 9.0, 'Mind-bending.', 'Finished', FALSE, 'Laptop',
                           '2025-01-10', '2025-01-10');
```

5. **Ask a question.** For example `SELECT * FROM watchlogs.v_series_watchlist;`.

---

## 3. How the tables connect

```
series_metadata  1 ----- many  series_log  many ----- 1  dates_table
movie_metadata   1 ----- many  movie_log   many ----- 1  dates_table
                                      (start_date and end_date must exist in dates_table)

series_metadata.latest_log_id  ->  newest series_log row for that series
movie_metadata.latest_log_id   ->  newest movie_log row for that movie

Any deleted row  ->  copied by a trigger into archive.metadata_audit or archive.log_audit
```

- A series or movie that still has logs cannot be deleted. The logs must be deleted first.
- If the newest log is deleted, `latest_log_id` moves to the next newest one. When no logs are left it becomes empty and the title goes back to `Backlog`.

---

## 4. Tables

### Allowed values

These lists are enforced by the database. Anything else is rejected.

| Field | Where | Allowed values |
|---|---|---|
| `status` | series_metadata | Returning, Ended, Cancelled, TBD |
| `log_status` | both metadata tables | Backlog, Logged |
| `watch_type` | series_log | Background, Binge, Casual, Batch, Daily, Live |
| `watch_status` | series_log | Ongoing, Finished, On-Hold, Dropped |
| `watch_status` | movie_log | Ongoing, Finished, Dropped (movies have no On-Hold) |
| `device` | both logs | Phone, Laptop, Both |
| `watch_pace` | movie_log | Stalled, Ongoing, Normal, Split View, Slow |
| `score_verdict` | both logs | Excellent, Good, Average, Subpar, Poor, N/A |
| `rating` | series_log | 1 to 10, one decimal |
| `rating` | movie_log | above 0 up to 10, one decimal |

### registry.series_metadata

One row per series.

| Column | Meaning |
|---|---|
| `series_id` | Automatic number, the primary key |
| `series_code` | Short unique code like `BOB-11` (made by a trigger, see section 5) |
| `title`, `country`, `year_released`, `year_completed` | Basic details. `year_completed` is filled only when the show has ended or been cancelled |
| `total_seasons`, `total_episodes` | Counts of what has aired |
| `avg_runtime` | Average episode length in minutes |
| `genres` | A list of genres |
| `platform` | Network or streaming service, always uppercase |
| `status` | Where the show stands (see allowed values) |
| `seasons_pre_log` | How many seasons, counted from Season 1, I watched before logging started. Default 0 |
| `log_status` | Logged if at least one log exists, otherwise Backlog (kept up to date by a trigger) |
| `tmdb_id` | The TMDB number. Must be unique. This is how duplicates are caught |
| `last_updated` | Refreshed on every change |
| `latest_log_id` | Newest log of this series (kept up to date by a trigger) |

Example row (Bob's Burgers from the sample data):

| Column | Value |
|---|---|
| series_id / series_code | 1 / BOB-11 |
| title / country / year_released | Bob's Burgers / US / 2011 |
| total_seasons / total_episodes / avg_runtime | 16 / 313 / 22 |
| genres / platform / status | Comedy, Animation / FOX / Returning |
| seasons_pre_log / log_status | 14 / Logged |
| tmdb_id / latest_log_id | 32726 / 11 |

### registry.movie_metadata

One row per movie. It has the same ideas as the series table, with these columns: `movie_id`, `movie_code` (unique), `title`, `year_released`, `country`, `director`, `runtime_mins`, `genres`, `tmdb_id` (unique), `log_status`, `last_updated` and `latest_log_id`. There is no seasons or platform information. Movies have no `seasons_pre_log`, so there is no way to mark a movie as watched before logging.

### watchlogs.series_log

One row per season watch. A rewatch of the same season is a new row.

| Column | Meaning |
|---|---|
| `log_id` | Automatic number, the primary key |
| `series_id` | Which series (links to series_metadata) |
| `season_no` | Which season. Cannot be higher than the series' `total_seasons` |
| `total_episodes`, `episodes_watched` | Season size and progress. Watched cannot exceed total |
| `start_date`, `end_date` | Must exist in `dates_table`. End cannot be before start |
| `days_to_finish` | End minus start plus 1. Filled automatically |
| `watch_type`, `watch_status`, `device` | See allowed values |
| `is_rewatch` | True for a rewatch. Usually set automatically (see section 5) |
| `rating`, `score_verdict`, `review` | Rating, a word for it (automatic) and my review. Review defaults to TBA |
| `last_updated` | Refreshed on every change |

### watchlogs.movie_log

One row per movie watch. It shares these columns with series_log: `log_id`, `start_date`, `end_date`, `days_to_finish`, `watch_status`, `device`, `is_rewatch`, `rating`, `score_verdict`, `review`, `last_updated`. Differences:

- It links to `movie_metadata` through `movie_id`, and has no season, episode or watch type columns.
- It adds `watch_pace`, which is filled automatically.
- A rating is only allowed on a Finished log. Any other status must have no rating.
- `start_date` defaults to today.
- `is_rewatch` is allowed to be empty, but the trigger treats empty as false.

### public.dates_table

A calendar with one row per day. Logs can only use dates that exist here.

Columns: `date_key` (the date), `date_year`, `quarters`, `month_num`, `month_short`, `day_short`, `day_of_week_index` (1 is Monday, 7 is Sunday) and `is_weekend`. The year must be 2025 or later. A trigger recalculates every column from `date_key`, so they can never disagree with the date.

The table starts empty. Add the first day, then add each new year with `CALL public.extend_calendar(YYYY)` (see the [setup guide](getting-started.md)).

### archive.metadata_audit and archive.log_audit

The recycle bin. Every deleted row is saved here as JSON by a trigger.

| Table | Stores |
|---|---|
| `metadata_audit` | `entity_id` (the series or movie id), `content_type` (series or movie), `deleted_at`, `deleted_by`, `original_data` (the full row) |
| `log_audit` | `log_id`, `entity_id`, `content_type`, `deleted_at`, `deleted_by`, `row_data` (the full row) |

How to restore from it is in the [system audit](system-audit.md).

### Indexes

Indexes speed up lookups and are listed in `1-tables.sql`. They cover the calendar (year and month, day of week), the catalogue (country, genres, years) and the logs (title id, watch status, start date, end date). The genre lists use GIN indexes, which are explained in [view architecture and indexing](view-indexing.md). Primary keys and unique columns get an index automatically.

---

## 5. Automatic behaviour (triggers)

A trigger is a rule that runs by itself whenever a row is added, changed or deleted. Nothing here needs to be run by hand.

| Function | Runs | What it does |
|---|---|---|
| `registry.fn_process_metadata` | Before insert or update on both metadata tables | Cleans text and makes the code (see below) |
| `watchlogs.fn_process_log_entry` | Before insert or update on both logs | Checks the entry and fills in status, dates, pace and verdict (see below) |
| `watchlogs.fn_sync_media_status` | After any change to a log | Sets the title's `log_status` to Logged if it has any log, or Backlog if none |
| `watchlogs.fn_sync_latest_log` | After any change to a log | Sets `latest_log_id` to the highest `log_id` of the title. Newest means highest id, not latest date |
| `archive.fn_audit_deletions` | After a delete on any of the four main tables | Saves the deleted row to the recycle bin |
| `public.fn_clean_dates_logic` | Before insert or update on `dates_table` | Recalculates the calendar columns from the date |

The full list of 13 triggers and the query to check them is in the [system audit](system-audit.md).

### What fn_process_metadata cleans

- **Titles:** trimmed and Title Cased. A letter right after an apostrophe is lowercased (Bob's, not Bob'S). II, III and IV are kept as capitals, and Vs becomes vs.
- **Genres:** split on `&`, trimmed and Title Cased. Any spelling of Sci-Fi becomes SciFi. Duplicates are removed.
- **Other fields:** a series platform is uppercased. A movie director is Title Cased, and a movie country is uppercased.
- **Codes:** made on insert only. The code is the first 3 letters of the title (ignoring a leading The, A or An, and anything that is not a letter or number, padded with X if short) plus the last 2 digits of the year. Bob's Burgers from 2011 becomes `BOB-11`. If that code is already used by any movie or series, a number is added, like `KIL-23-1`.
- **Timestamp:** `last_updated` is refreshed on every update.

### What fn_process_log_entry does

**Checks (the save is rejected if one fails)**

- The start date cannot be in the future, using Lagos time.
- The end date cannot be before the start date.
- A series season number cannot be above the series' `total_seasons`.

**Rewatch flag.** When a log is added, or its status changes to Finished or Ongoing, the trigger sets `is_rewatch` to true if:

- Movie: another Finished or Ongoing log of that movie exists.
- Series: the season number is within `seasons_pre_log`, or another Finished or Ongoing log of that season exists.

A flag already set to true is never switched back to false.

**Series status rules** (checked in this order)

1. Dropped: the rating is cleared and the end date is set to today if empty.
2. On-Hold: the rating and end date are cleared.
3. All episodes watched: the status becomes Finished and the end date is set to today if empty.
4. Anything else: the status becomes Ongoing, with no rating and no end date.

Episodes watched are capped at the season total. This means a season only becomes Finished when every episode is watched, and a rating is only kept on a Finished season.

**Movie status rules**

1. Dropped: the rating is cleared and the end date is set to today if empty.
2. An end date given, or status Finished: the status becomes Finished and the end date is set to today if empty.
3. Anything else: the status becomes Ongoing with no rating.

**Watch pace (movies only)**

| Pace | When |
|---|---|
| Stalled | Dropped |
| Ongoing | Still ongoing |
| Normal | Finished on the same day it started |
| Split View | Finished 1 to 2 days after it started |
| Slow | Finished more than 2 days after it started |

**Score verdict.** From the rating: 8.5 and above is Excellent, 7 and above is Good, 5 and above is Average, 3 and above is Subpar, and anything lower is Poor. A Dropped log with no rating gets N/A. Otherwise the verdict stays empty.

---

## 6. Procedures

A procedure is a saved action that is run with `CALL`. All writes go through these. The Python scripts call `add_metadata` for me.

| Procedure | Purpose | Notes |
|---|---|---|
| `registry.add_metadata` | Adds a series or movie to the catalogue | Parameters: type (Movie or Series), title, year, country, platform or director, runtime, genres, TMDB id, and for a series also status, year completed, seasons, episodes and seasons watched before logging. If the `tmdb_id` already exists it prints a notice and does nothing. Country defaults to US |
| `watchlogs.series_watch` | Updates a season log, or starts a new one | Parameters: series code, season, season episodes, episodes watched, watch type, rating, device, review, status, rewatch flag, start date, end date. It looks for a log of the same series, season and rewatch flag that is not Finished or has the same start date. If found it is updated, otherwise a new log is added. An update never changes the start date or rewatch flag |
| `watchlogs.movie_watch` | Updates a movie log, or starts a new one | Parameters: movie code, rating, review, status, rewatch flag, device, start date, end date. Same matching idea as series_watch, without the season |
| `registry.remove_metadata` | Deletes a series or movie | Parameters: type and code. Refuses if it has an Ongoing log. Any remaining logs still block the delete, so remove them first |
| `watchlogs.remove_log` | Deletes one log | Parameters: type and log id. Refuses if the log is still Ongoing |
| `public.extend_calendar` | Adds calendar days up to 31 December of a year | Does nothing if the calendar already reaches that year |

After any save, the triggers in section 5 decide the final status, dates and rating.

---

## 7. Views

A view is a saved question that always shows fresh answers. Most live in `watchlogs`. The three marked `registry` live in the catalogue schema. Nine views in total.

### Progress and lists

| View | One row per | Shows |
|---|---|---|
| `v_series_watchlist` | Season I am in the middle of (Ongoing or On-Hold, newest log) | Episodes watched, season size, percent complete, device. Sorted by percent complete |
| `v_movie_watchlist` | Ongoing movie log | Title, dates, rewatch flag, status, device |
| `registry.v_series_status` | Series | Progress like `3 / 5` and a status (see below) |
| `registry.v_movie_status` | Movie | Runtime, log status and watch status. Movies with no logs show Pending |

**v_series_status labels** (checked in this order): Watching (a first watch is Ongoing), Rewatching (a rewatch is Ongoing), Caught Up (every aired season done and the show is still Returning), Finished (every season done), Dropped, Pending (some seasons done, not all), Not Started. Seasons done is the larger of `seasons_pre_log` and the highest season I finished.

### Rating changes

These three views answer one question: did I like it more or less the next time?

**v_season_rating_changes** has one row per rewatch of a season. **v_rewatch_rating_changes** does the same for movies. Both show the rewatch number, where the old rating came from, the old and new rating, the change and a verdict. Only rewatches that are rated or Dropped appear. The old rating is always the most recent earlier log of that season (or movie) that has a rating, so a dropped log in between is skipped.

| `old_watch` value | Meaning |
|---|---|
| Original Watch | The old rating came from my first logged watch (not a rewatch) |
| Rewatch 1, Rewatch 2, ... | The old rating came from that numbered rewatch |
| Original (Not Logged) | There is no earlier rated log. For a series this means a season within `seasons_pre_log`. For a movie it applies to any rewatch with no earlier rated log |
| None | Series only: no earlier log, and the season is above `seasons_pre_log`. This points to a gap in the data |

| `verdict` value | Meaning |
|---|---|
| Went Up, Went Down, No Change | New rating compared with the old one |
| Dropped | The rewatch was dropped, so there is no new rating |
| No Rating To Compare | There is no old rating. For a series this is a season within `seasons_pre_log` (a series season above it says No Earlier Log) |

Rewatch numbers count only the rewatches that appear in the view. An unrated Ongoing rewatch is not counted until it is rated or dropped.

Example: Bob's Burgers Season 1 (seasons 1 to 14 were watched before logging started).

| series_code | season_no | rewatch_no | old_watch | old_rating | new_rating | change | verdict |
|---|---|---|---|---|---|---|---|
| BOB-11 | 1 | 1 | Original (Not Logged) | | 8.0 | | No Rating To Compare |
| BOB-11 | 1 | 2 | Rewatch 1 | 8.0 | 9.5 | 1.5 | Went Up |

Rows are sorted by title, then season (or year for movies), then rewatch number.

**v_series_rating_changes** summarises the season view, one row per series. For each season it compares the rating before the first rated rewatch with the latest rated rewatch. If there is no earlier rating, the first rated rewatch is the starting point. A season is skipped unless it has two real ratings to compare. It then averages across the compared seasons and shows `seasons_compared`, `old_avg`, `new_avg`, `change` and a verdict. It reads from `v_season_rating_changes`, so that view must exist first.

### Binge patterns

| View | One row per | Shows |
|---|---|---|
| `v_binge_patterns` | Day of the week | For seasons logged as Binge: count, average length in days, average episode length, average season size, hours per session and share of all binges. Days with no binges are not listed |

Each column is explained in [view architecture and indexing](view-indexing.md).

### Admin toolbox

`registry.v_admin_toolbox` is a menu of ready-to-copy queries. Replace `[ID]`, `[LOG_ID]` or `[YEAR]` with real values before running one.

| Category | Tool | Purpose |
|---|---|---|
| Recovery | Series Metadata Restore, Movie Metadata Restore | Bring a deleted series or movie back from the recycle bin |
| Recovery | Series Log Restore, Movie Log Restore | Bring a deleted log back |
| Maintenance | Empty Recycle Bin | Clears both archive tables for good |
| Maintenance | Extend Calendar Table | Runs `extend_calendar` for a year |
| Audit | Drop Procedure Tool | Prints the commands to drop the six procedures |
| Audit | List Functions and Triggers | Lists every function and the triggers that use it |

---

## 8. Python scripts

Three scripts in `py/` talk to the TMDB API. They need a TMDB API key and a database login, which they read from environment variables, so nothing private is stored in the code. The [setup guide](getting-started.md) shows how to set them up.

| Script | Purpose |
|---|---|
| `add_metadata.py` | Adds one title. Usage: Movie or Series, then a title or a TMDB id |
| `update_series.py` | Refreshes one series from TMDB, chosen by searching the local catalogue |
| `update_all.py` | Refreshes every series that has a `tmdb_id` |

| Variable | Used for | Default |
|---|---|---|
| `TMDB_API_KEY` | Your TMDB key | None, required |
| `PGPASSWORD` | Database password | None, required |
| `PGDATABASE`, `PGUSER`, `PGHOST`, `PGPORT` | Database connection | `cinepipe`, `postgres`, `localhost`, `5432` |

**add_metadata.py** searches TMDB and lists up to 10 matches to choose from. It stops if the `tmdb_id` already exists. It then fetches the details and maps them:

- Movie: year, first production country, runtime and director.
- Series: first origin country, seasons, episodes, average episode length, and the first network (or production company) as the platform. TMDB status maps as Returning Series to Returning, In Production to Returning, Ended to Ended and Canceled to Cancelled. The year completed is set for Ended and Cancelled shows.
- For a series it also asks how many seasons were watched before logging.

It shows a summary, asks for confirmation and then calls `add_metadata`. Exit codes: 0 registered, 2 duplicate skipped, 3 aborted, anything else is an error.

**update_series.py and update_all.py** refresh title, seasons, episodes, status, year released and year completed. They count only seasons that have already started airing. They never lower the season count below what is stored (the "Frieren Rule"), so a manual override survives. Other TMDB statuses map as Planned to Returning, and Pilot or anything unknown to TBD. `update_all.py` pauses half a second between titles and prints a list of any failures at the end.

---

## 9. Files and rebuild order

The SQL is split into five files, and the first four must be run in this order.

| File | Contains |
|---|---|
| `sql/1-tables.sql` | Schemas, tables and indexes |
| `sql/2-procedures.sql` | The six procedures |
| `sql/3-triggers.sql` | All trigger functions and triggers, plus a one-time backfill of `latest_log_id` |
| `sql/4-views.sql` | All nine views. `v_season_rating_changes` comes before `v_series_rating_changes` |
| `sql/5-sample-data.sql` | Optional. A small sample library for an empty database. It stops by itself if any series or movie already exists |

---

## 10. Beyond this repo

I keep the local database as the one I log into, and a second copy on Supabase. A script of mine pushes new and changed rows to the online copy every couple of days, with a dated backup taken first. A handful of Bash functions wrap everyday jobs like switching between the two databases, and cron schedules the backups and the sync. All of that is specific to my machine, so none of it is in this repo. The practical effect is that I only log on the local copy, and the online one is a one-way mirror.

---

## 11. Known quirks

- **Seasons watched before logging count as rewatches.** The trigger flags any season within `seasons_pre_log` as a rewatch, even on its first logged watch. That is why such a log appears in the rating-change views, labelled Original (Not Logged).
- **Movies have no pre-log marker.** A movie rewatched with no earlier rated log is labelled Original (Not Logged), even if the original was logged but dropped.
- **`seasons_pre_log` is a single number.** It assumes the pre-log seasons are always 1 to N. Skipped seasons cannot be described.
- **Rating-change views need ratings.** An unrated Ongoing rewatch does not appear until it is rated or dropped.
- **v_movie_status with several logs.** The watch status shown is the one that sorts last alphabetically, not the newest.
- **v_series_status and dropped logs.** If a series has a dropped log, it shows Dropped unless one of the earlier rules (Watching, Rewatching, Caught Up, Finished) applies. This is true even when only a rewatch was dropped.
- **Code numbers.** The added number on a duplicate code is counted within each table, so a movie and a series can both end up with the same numbered code. A movie with the same title and year as an existing movie reuses its code, and the unique rule then rejects it.
- **Season limit.** A log is rejected if its season number is above `total_seasons`. If a new season airs, refresh the series with `update_series.py` or `update_all.py` before logging it.