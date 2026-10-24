# System Audit and Operational Logging

This document covers how the database protects itself: the recycle bin that captures deleted rows, how to restore them, how timestamps and statuses are kept up to date automatically, and how to check that every trigger is in place. For everything else, see the [full documentation](database-documentation.md).

---

## 1. The Recycle Bin

When a row is deleted from one of the four main tables, the `fn_audit_deletions` trigger fires and saves the full row as a JSONB object in the `archive` schema. This means no deletion is truly permanent: the original record can always be rebuilt exactly as it was.

| Deleted from | Saved in | What is stored |
|---|---|---|
| `series_metadata`, `movie_metadata` | `archive.metadata_audit` | `entity_id` (the series or movie id), `content_type` (series or movie), `deleted_at`, `deleted_by`, and the full row in `original_data` |
| `series_log`, `movie_log` | `archive.log_audit` | `log_id`, `entity_id`, `content_type`, `deleted_at`, `deleted_by`, and the full row in `row_data` |

The procedures `remove_log` and `remove_metadata` are the safe way to delete. `remove_log` refuses to delete a log that is still `Ongoing`, and `remove_metadata` refuses to delete a title that has an `Ongoing` log. A series or movie that still has any logs cannot be deleted until its logs are gone.

---

## 2. Restoring a Deleted Record

Ready-made restore queries live in one place, a view called the admin toolbox:

```sql
SELECT category, tool, query FROM registry.v_admin_toolbox;
```

| Category | Tool | What it does |
|---|---|---|
| Recovery | Series Metadata Restore, Movie Metadata Restore | Brings back a deleted series or movie |
| Recovery | Series Log Restore, Movie Log Restore | Brings back a deleted log |
| Maintenance | Empty Recycle Bin | Clears both archive tables for good |
| Maintenance | Extend Calendar Table | Adds a new year to the calendar |
| Audit | List Functions and Triggers | Shows every function and the triggers that use it |
| Audit | Drop Procedure Tool | Prints the commands to drop the stored procedures |

Pick the restore tool you need, copy its query, and replace `[ID]` (a series or movie id) or `[LOG_ID]` with the real number. Each query reads the saved JSONB back into the table's row type with `jsonb_populate_record`. For example, the series metadata restore looks like this:

```sql
INSERT INTO registry.series_metadata
SELECT * FROM jsonb_populate_record(
    NULL::registry.series_metadata,
    (SELECT original_data || jsonb_build_object('latest_log_id', NULL)
     FROM archive.metadata_audit
     WHERE entity_id = [ID] AND content_type = 'series'
     LIMIT 1)
);
```

This restores the record with all original attributes intact, including the genre array. `latest_log_id` is set back to empty on purpose, because the log it pointed to may no longer exist. The audit row itself is kept as a permanent record of the deletion.

Three things to remember:

- **Restore the title before its logs.** A log cannot be put back until the series or movie it belongs to exists again.
- **Empty Recycle Bin is permanent.** After it runs, nothing can be restored.
- **Restoring the same row twice.** If a row has been deleted, restored and deleted again, the bin holds one snapshot for each deletion. `deleted_at` tells them apart.

### Try it: delete a log and bring it back

This walkthrough uses a log of your own, so run it on test data (the sample data is perfect for this).

1. Find a finished log and note its `log_id`:

```sql
SELECT log_id, series_id, season_no, rating FROM watchlogs.series_log WHERE watch_status = 'Finished';
```

2. Delete it with the procedure, then look in the recycle bin:

```sql
CALL watchlogs.remove_log('Series', 9);   -- use your log_id

SELECT log_id, content_type, row_data->>'rating' AS rating
FROM archive.log_audit WHERE log_id = 9;
```

3. Restore it with the Series Log Restore query from the toolbox, with `[LOG_ID]` replaced:

```sql
INSERT INTO watchlogs.series_log
SELECT * FROM jsonb_populate_record(
    NULL::watchlogs.series_log,
    (SELECT row_data FROM archive.log_audit WHERE log_id = 9 LIMIT 1)
);
```

4. Check that the log is back, with the same rating and verdict, and that the recycle bin still holds its snapshot:

```sql
SELECT log_id, season_no, watch_status, rating, score_verdict FROM watchlogs.series_log WHERE log_id = 9;
```

---

## 3. Trigger Health Check

You can verify that all triggers are correctly attached to their tables by querying `information_schema.triggers`. This is useful after any schema change or if you suspect a trigger isn't firing.

```sql
SELECT
    event_object_schema AS schema_name,
    event_object_table  AS table_name,
    trigger_name,
    event_manipulation  AS event
FROM information_schema.triggers
WHERE trigger_schema IN ('registry', 'watchlogs', 'public')
ORDER BY schema_name, table_name, trigger_name, event;
```

A healthy database returns 26 rows. That is 13 triggers, and a trigger that fires on several events shows one row for each:

| Table | Trigger | Fires on |
|---|---|---|
| `public.dates_table` | `trg_clean_dates` | insert, update |
| `registry.series_metadata` | `trg_process_series_metadata` | insert, update |
| `registry.series_metadata` | `trg_audit_series_metadata` | delete |
| `registry.movie_metadata` | `trg_process_movie_metadata` | insert, update |
| `registry.movie_metadata` | `trg_audit_movie_metadata` | delete |
| `watchlogs.series_log` | `trg_process_series_log` | insert, update |
| `watchlogs.series_log` | `trg_sync_series_status` | insert, update, delete |
| `watchlogs.series_log` | `trg_sync_series_latest_log` | insert, update, delete |
| `watchlogs.series_log` | `trg_audit_series_log` | delete |
| `watchlogs.movie_log` | `trg_process_movie_log` | insert, update |
| `watchlogs.movie_log` | `trg_sync_movie_status` | insert, update, delete |
| `watchlogs.movie_log` | `trg_sync_movie_latest_log` | insert, update, delete |
| `watchlogs.movie_log` | `trg_audit_movie_log` | delete |

If a trigger is missing, it was either not installed or was accidentally dropped. Run its `CREATE TRIGGER` statement again from `3-triggers.sql`. Don't run the whole file a second time, because the triggers that already exist would cause errors.

---

## 4. Automatic Timestamps

The `last_updated` column is refreshed automatically whenever a metadata or log row is updated. `fn_process_metadata` does this for the catalogue tables and `fn_process_log_entry` does it for the logs. Both use the database server clock, so the time is reliable whichever tool or script made the change.

This is intentionally handled at the database level rather than in the scripts. It also makes it easy to find everything that changed since a given moment.

To verify timestamps are being recorded correctly:

```sql
SELECT title, series_code, last_updated
FROM registry.series_metadata
ORDER BY last_updated DESC
LIMIT 5;
```

---

## 5. Status Automation: `fn_process_log_entry`

This trigger fires before every insert or update on `series_log` and `movie_log`. It checks the entry, then decides the status for me. It also flags rewatches, works out `days_to_finish` and turns the rating into a score verdict.

### Series

The rules are checked in this order:

| Status | Condition | Automated result |
|--------|-----------|-----------------|
| `Dropped` | Set through the `series_watch` procedure | Rating cleared; `end_date` set to today if empty |
| `On-Hold` | Set through the `series_watch` procedure | Rating and `end_date` cleared |
| `Finished` | `episodes_watched` equals `total_episodes` | Status set to `Finished`; `end_date` set to today if empty |
| `Ongoing` | Anything else | Rating and `end_date` cleared |

`Dropped` and `On-Hold` are set on purpose and skip the progress check. Anything else is judged only by the episode count, so a season only becomes `Finished` when every episode has been watched, and a rating is only kept on a `Finished` season.

### Movies

| Status | Condition | Automated result |
|--------|-----------|-----------------|
| `Dropped` | Set through the `movie_watch` procedure | Rating cleared; `end_date` set to today if empty; pace `Stalled` |
| `Finished` | An end date is given, or the status is `Finished` | `end_date` set to today if empty |
| `Ongoing` | Anything else | Rating cleared |

For a finished movie, `watch_pace` is `Normal` if it ended the day it started, `Split View` if it took 1 to 2 days, and `Slow` if it took longer.

### Checks that reject a save

- The start date cannot be in the future (Lagos time).
- The end date cannot be before the start date.
- A series season number cannot be above the series' `total_seasons`.

The full list of automatic rules, including the rewatch flag and the score verdict thresholds, is in the [full documentation](database-documentation.md#5-automatic-behaviour-triggers).