import requests
import psycopg2
from datetime import datetime
import sys
import os
import time

# --- CONFIGURATION ---
TMDB_API_KEY = os.getenv("TMDB_API_KEY")

if not TMDB_API_KEY:
    print("Error: TMDB_API_KEY not found. Make sure it's set in ~/.psql_secrets.env")
    sys.exit(1)

DB_PARAMS = {
    "dbname": os.getenv("PGDATABASE", "cinepipe"),
    "user":     os.getenv("PGUSER", "postgres"),
    "password": os.getenv("PGPASSWORD"),
    "host":     os.getenv("PGHOST", "localhost"),
    "port":     os.getenv("PGPORT", "5432"),
    "options":  os.getenv("PGOPTIONS", "-c search_path=registry")
}

if not DB_PARAMS["password"]:
    print("Error: PGPASSWORD not set. Make sure you've run dbctx (cinepipe|supabase) first.")
    sys.exit(1)

REQUEST_DELAY = 0.5

def map_status(tmdb_status):
    """Maps TMDB status to registry constraints."""
    mapping = {
        "Returning Series": "Returning",
        "Planned": "Returning",
        "In Production": "Returning",
        "Ended": "Ended",
        "Canceled": "Cancelled",
        "Pilot": "TBD"
    }
    return mapping.get(tmdb_status, "TBD")


def get_all_tmdb_ids(conn):
    """
    Pull every series in the registry that has a tmdb_id set.
    Returns a list of (tmdb_id, title) tuples, used to drive the full sync loop.
    Raises the original exception up to main(), which is responsible for
    closing the connection if this fails, since this function did not open it.
    """
    cur = conn.cursor()
    try:
        cur.execute("""
            SELECT tmdb_id, title
            FROM registry.series_metadata
            WHERE tmdb_id IS NOT NULL;
        """)
        rows = cur.fetchall()
    finally:
        # Always close the cursor, whether the query succeeded or failed
        cur.close()
    return rows


def get_tmdb_details(tmdb_id):
    """Fetch live data from TMDB API. Unchanged from the single-show version."""
    try:
        url = f"https://api.themoviedb.org/3/tv/{tmdb_id}"
        params = {"api_key": TMDB_API_KEY}
        res = requests.get(url, params=params, timeout=30).json()
    except Exception as e:
        print(f"TMDB API Error: {e}")
        return None

    today = datetime.now().strftime('%Y-%m-%d')
    mapped_status = map_status(res.get("status"))

    # Filter: Only count seasons that have actually started airing
    aired_seasons = [
        s for s in res.get("seasons", [])
        if s.get("air_date") and s.get("air_date") <= today and s.get("season_number") > 0
    ]

    total_aired_episodes = sum(s.get("episode_count", 0) for s in aired_seasons)

    first_air = res.get("first_air_date")
    last_air = res.get("last_air_date")

    year_released = int(first_air[:4]) if first_air else None
    year_completed = int(last_air[:4]) if mapped_status in ["Ended", "Cancelled"] and last_air else None

    return {
        "title": res.get("name"),
        "seasons": len(aired_seasons),
        "episodes": total_aired_episodes,
        "status": mapped_status,
        "year_released": year_released,
        "year_completed": year_completed
    }


def update_database(conn, tmdb_id, api_data):
    """
    Updates a single series row using a connection passed in from main(),
    instead of opening and closing its own connection. Logic is otherwise
    identical to the single-show version, including the Frieren Rule.
    The cursor is now closed in a finally block, so it can't be left open
    if the UPDATE statement itself raises an exception.
    """
    cur = conn.cursor()
    try:
        cur.execute("""
            SELECT total_seasons, total_episodes
            FROM registry.series_metadata
            WHERE tmdb_id = %s;
        """, (tmdb_id,))
        result = cur.fetchone()
        local_seasons, local_episodes = result if result else (0, 0)

        # Frieren Rule: Protect local manual season overrides
        final_seasons = max(local_seasons, api_data['seasons'])
        local_ep_count = local_episodes or 0
        ep_diff = api_data['episodes'] - local_ep_count

        update_query = """
            UPDATE registry.series_metadata
            SET title = %s,
                total_seasons = %s,
                total_episodes = %s,
                status = %s,
                year_released = %s,
                year_completed = %s
            WHERE tmdb_id = %s;
        """
        cur.execute(update_query, (
            api_data['title'],
            final_seasons,
            api_data['episodes'],
            api_data['status'],
            api_data['year_released'],
            api_data['year_completed'],
            tmdb_id
        ))

        conn.commit()
    finally:
        # Always close the cursor, even if the UPDATE above raised an exception.
        # The caller in main() still handles conn.rollback() on failure.
        cur.close()

    if ep_diff > 0:
        diff_str = f"(+{ep_diff} new)"
    elif ep_diff < 0:
        diff_str = f"({ep_diff} fewer -- check TMDB manually)"
    else:
        diff_str = "(No change)"

    print(f"SUCCESS: '{api_data['title']}' synced.")
    print(f"Update: {final_seasons} Seasons | {api_data['episodes']} Episodes {diff_str}")
    print(f"Status: {api_data['status']} | Released: {api_data['year_released']}")


def main():
    conn = None
    succeeded = []
    failed = []

    try:
        conn = psycopg2.connect(**DB_PARAMS)
    except Exception as e:
        print(f"Could not connect to database: {e}")
        sys.exit(1)

    # Wrapped so a failed query here still closes the connection we just opened,
    # instead of leaving it dangling before the script exits.
    try:
        series_list = get_all_tmdb_ids(conn)
    except Exception as e:
        print(f"Could not retrieve series list: {e}")
        conn.close()
        sys.exit(1)

    total = len(series_list)
    print(f"Found {total} series with a tmdb_id. Starting full sync.\n")

    for index, (tmdb_id, local_title) in enumerate(series_list, start=1):
        print(f"[{index}/{total}] Contacting TMDB for '{local_title}' (ID {tmdb_id})...")

        try:
            api_data = get_tmdb_details(tmdb_id)
            if api_data is None:
                raise ValueError("No data returned from TMDB.")

            update_database(conn, tmdb_id, api_data)
            succeeded.append(local_title)

        except Exception as e:
            conn.rollback()
            print(f"FAILED: '{local_title}' (ID {tmdb_id}) -- {e}")
            failed.append((local_title, tmdb_id, str(e)))

        print("")  # blank line between entries for readability
        time.sleep(REQUEST_DELAY)

    conn.close()

    # --- Final summary ---
    print("=" * 40)
    print(f"Sync complete: {len(succeeded)} succeeded, {len(failed)} failed.")
    if failed:
        print("\nFailed series:")
        for title, tmdb_id, reason in failed:
            print(f"  - {title} (ID {tmdb_id}): {reason}")


if __name__ == "__main__":
    main()
