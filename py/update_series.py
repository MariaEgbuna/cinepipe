import requests
import psycopg2
from datetime import datetime
import sys
import os

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

def search_local_database(query):
    """Search registry.series_metadata and display results."""
    conn = None
    try:
        conn = psycopg2.connect(**DB_PARAMS)
        cur = conn.cursor()

        search_sql = """
            SELECT tmdb_id, title, year_released, total_seasons
            FROM registry.series_metadata
            WHERE title ILIKE %s;
        """
        cur.execute(search_sql, (f'%{query}%',))
        results = cur.fetchall()

        if not results:
            print(f"No matches in registry for '{query}'.")
            return None

        print("--- Local Registry Results ---")
        for i, (t_id, title, year, seasons) in enumerate(results):
            print(f"[{i+1}] {title} ({year}) | ID: {t_id} | Seasons: {seasons}")

        print(f"({len(results)} match(es) found)")

        choice = input("Select show to sync (or 'q'): ").strip().lower()
        if choice.isdigit() and 1 <= int(choice) <= len(results):
            return results[int(choice)-1][0]

    except Exception as e:
        print(f"Local DB Search Error: {e}")
    finally:
        if conn:
            cur.close()
            conn.close()
    return None

def get_tmdb_details(tmdb_id):
    """Fetch live data from TMDB API."""
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

def update_database(tmdb_id, api_data):
    conn = None
    try:
        conn = psycopg2.connect(**DB_PARAMS)
        cur = conn.cursor()

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

        if ep_diff > 0:
            diff_str = f"(+{ep_diff} new)"
        elif ep_diff < 0:
            diff_str = f"({ep_diff} fewer -- check TMDB manually)"
        else:
            diff_str = "(No change)"

        print(f"SUCCESS: '{api_data['title']}' synced.")
        print(f"Update: {final_seasons} Seasons | {api_data['episodes']} Episodes {diff_str}")
        print(f"Status: {api_data['status']} | Released: {api_data['year_released']}")

    except Exception as e:
        if conn:
            conn.rollback()
        print(f"Update Error: {e}")
    finally:
        if conn:
            cur.close()
            conn.close()

def main():
    query = sys.argv[1] if len(sys.argv) > 1 else input("Enter local show name to sync: ").strip()
    tmdb_id = search_local_database(query)

    if tmdb_id:
        print(f"Contacting TMDB for ID {tmdb_id}...")
        api_data = get_tmdb_details(tmdb_id)
        if api_data:
            update_database(tmdb_id, api_data)
            sys.exit(0)
        else:
            sys.exit(1)
    else:
        sys.exit(1)

if __name__ == "__main__":
    main()
