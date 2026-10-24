# Deployment and Setup Guide

This guide walks you through setting up the database from scratch. For what every table, trigger, procedure and view does, see the [full documentation](database-documentation.md).

**What you will do**

1. Create an empty database.
2. Run the four SQL files, in order.
3. Fill the calendar.
4. Check that everything works with four short tests.
5. Optional: load the sample data.
6. Optional: set up the Python scripts (these need a free TMDB API key).

---

## Prerequisites

Before you start, make sure you have the following:

- **PostgreSQL 17** installed and running locally
- An empty database, for example `cinepipe` (`CREATE DATABASE cinepipe;`)
- A PostgreSQL client to run the SQL files: psql, DBeaver, or similar
- **Only for the optional Python scripts:** Python 3 and a TMDB API key (see step 6)

Don't create **ANY** schemas by hand. The first SQL file creates `registry`, `watchlogs` and `archive` itself, and it will fail if they already exist.

---

## 1. Database Setup

Run the SQL files in this exact order. Each file depends on the one before it, so running them out of order will cause errors.

1. `1-tables.sql`: Creates the three schemas, the calendar table, the catalogue and log tables, constraints, foreign keys, indexes (including the GIN indexes for genres) and the recycle bin tables.
2. `2-procedures.sql`: Installs the stored procedures used as the write API.
3. `3-triggers.sql`: Installs the trigger functions and attaches the triggers (cleaning, checks, status automation, audit logging, timestamps).
4. `4-views.sql`: Creates the views for lists, statistics and rating changes. `v_season_rating_changes` has to exist before `v_series_rating_changes`, and the file already runs them in that order.

From the project folder, you can run these with `psql`:

```bash
psql -U your_user -d cinepipe -f sql/1-tables.sql
psql -U your_user -d cinepipe -f sql/2-procedures.sql
psql -U your_user -d cinepipe -f sql/3-triggers.sql
psql -U your_user -d cinepipe -f sql/4-views.sql
```

In DBeaver or another client, open each file and run it as a script, in the same order.

---

## 2. Fill the Calendar

Every log points to a date in `public.dates_table`, and the table starts empty. A log can only use a date that exists in it. Add the first day, then extend the calendar to the end of the current year:

```sql
INSERT INTO public.dates_table (date_key) VALUES ('2025-01-01')
ON CONFLICT (date_key) DO NOTHING;

CALL public.extend_calendar(EXTRACT(YEAR FROM CURRENT_DATE)::INT);
```

A trigger fills in the year, month, weekday and weekend columns for you, so the date is all you need to give. `extend_calendar` adds every day after the last one in the table, up to 31 December of the year you give it. Run it again at the start of each new year, with the new year as the number. The year must be 2025 or later.

---

## 3. Verifying the Setup

These four tests use the procedures to confirm that the core automation works. They create one test show and then delete it again. Run them on a fresh database, **before** loading the sample data. Test 4 deletes logs by number (1 and 2), and those numbers only belong to the test show on a database with no other logs.

**Test 1: Code generation**

```sql
CALL registry.add_metadata('Series', 'Test Show', 2020, 'US', 'FOX', 22,
                           ARRAY['Comedy'], 999999, 'Returning', NULL, 2, 20, 0);

SELECT series_code, title, platform, log_status
FROM registry.series_metadata WHERE tmdb_id = 999999;
```

You should see the code `TES-20` (the first three letters of the title plus the last two digits of the year), and the platform in capitals. `log_status` is `Backlog` because nothing has been logged yet. The code is made by the `fn_process_metadata` trigger, with no manual input.

**Test 2: Status automation**

```sql
CALL watchlogs.series_watch('TES-20', 1, 10, 10, 'Casual', 8.0, 'Laptop', 'Test',
                            'Ongoing', FALSE, CURRENT_DATE, NULL);

SELECT watch_status, end_date, score_verdict, is_rewatch FROM watchlogs.series_log;

SELECT log_status FROM registry.series_metadata WHERE series_code = 'TES-20';
```

The call asks for `Ongoing`, but all 10 of 10 episodes are watched. The `fn_process_log_entry` trigger should have changed the status to `Finished`, set the end date to today, and turned the 8.0 rating into the verdict `Good`. The second query should now show `Logged`.

**Test 3: Rewatch detection**

```sql
CALL watchlogs.series_watch('TES-20', 1, 10, 10, 'Casual', 9.0, 'Laptop', 'Test',
                            'Ongoing', FALSE, CURRENT_DATE - 1, NULL);

SELECT log_id, start_date, rating, is_rewatch FROM watchlogs.series_log ORDER BY log_id;
```

The second call has a different start date, so it creates a new log. The trigger notices a Finished log of the same season already exists, so the new row has `is_rewatch` set to true even though the call said FALSE. The rating views pick it up too:

```sql
SELECT * FROM watchlogs.v_season_rating_changes;
```

You should get one row: rewatch 1, old watch `Original Watch`, old rating 8.0, new rating 9.0, change 1.0, verdict `Went Up`.

**Test 4: Audit logging, and cleaning up**

```sql
CALL watchlogs.remove_log('Series', 1);
CALL watchlogs.remove_log('Series', 2);
CALL registry.remove_metadata('Series', 'TES-20');

SELECT content_type, row_data->>'rating' AS rating FROM archive.log_audit;
SELECT content_type, original_data->>'series_code' AS code FROM archive.metadata_audit;
```

Both queries should return rows. They show the deleted logs and the deleted show, saved as JSONB snapshots by the `fn_audit_deletions` trigger. Logs are removed before the show, because a show that still has logs cannot be deleted. To bring the test show back, see the recovery steps in the [System Audit](system-audit.md).

If all four tests gave the results above, the setup is working.

---

## 4. Optional: Load the Sample Data

`5-sample-data.sql` adds a small library to play with: 5 series, 7 movies and their watch logs, including rewatches, a dropped season, a dropped movie and titles still in the backlog. It is written through the same stored procedures, so it also works as an example of how to use them.

```bash
psql -U your_user -d cinepipe -f sql/5-sample-data.sql
```

Use it on an empty database only. If any series or movie already exists, the script stops and undoes itself, so it cannot touch real data. The checks at the bottom of the file show what each part should look like.

---

## 5. Using the System

Once the SQL files are loaded and verified, the database is fully operational. Data is written through the stored procedures, using any PostgreSQL client (psql, DBeaver, etc.). If you'd rather not type the details of every title yourself, the Python scripts in the next step fetch them from TMDB and call the same procedures for you.

---

## 6. Optional: The Python Scripts

The three scripts in `py/` fetch information from [TMDB](https://www.themoviedb.org) (The Movie Database), so you need a TMDB API key to use them. The database works fine without them.

| Script | What it does |
|---|---|
| `add_metadata.py` | Looks up a movie or series on TMDB and registers it in the database |
| `update_series.py` | Refreshes one series already in the database |
| `update_all.py` | Refreshes every series in the database |

**What you need**

1. **Python 3 and two packages.**

```bash
pip install psycopg2-binary requests
```

2. **A TMDB API key.** Create a free account on themoviedb.org, then request an API key from the API section of your account settings. The scripts use the standard (v3) API key. Treat the key like a password and never commit it to a repository.

3. **Environment variables.** The scripts read the database login and the key from environment variables, so nothing private is stored in the code. On Linux or macOS:

```bash
export TMDB_API_KEY="your_tmdb_key"
export PGPASSWORD="your_database_password"
```

On Windows PowerShell, use `$env:TMDB_API_KEY = "your_tmdb_key"` and `$env:PGPASSWORD = "your_database_password"`.

The scripts also read `PGDATABASE`, `PGUSER`, `PGHOST` and `PGPORT`. If you don't set them, they default to the database `cinepipe`, the user `postgres`, `localhost` and port `5432`. Two of the scripts' error messages point to the author's own setup. A message about `~/.psql_secrets.env` only means `TMDB_API_KEY` isn't set, and a message that mentions `dbctx` only means `PGPASSWORD` isn't set. Setting the variables above fixes both.

**Running them**

```bash
python3 py/add_metadata.py Series "Bob's Burgers"
python3 py/add_metadata.py Movie "Inception"
python3 py/update_series.py "bob"
python3 py/update_all.py
```

`add_metadata.py` shows up to 10 matches from TMDB, asks you to pick one, and (for a series) asks how many seasons you watched before logging started. It then shows a summary and asks for a final `y` before saving anything. You can also pass a TMDB id instead of a title. Titles that are already in the database are skipped.

`update_series.py` searches your own database for the title, lets you pick the series, then updates its seasons, episode count and status from TMDB. It never lowers a season count that is already stored, so a number you set by hand is safe.