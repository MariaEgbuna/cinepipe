import sys
import requests
import psycopg2
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

def add_media():
    # --- STEP 1: VALIDATE TYPE AND QUERY ---
    if len(sys.argv) < 3:
        print("Usage: python add_metadata.py <Movie|Series> <Title/ID>")
        sys.exit(1)

    media_type = sys.argv[1].strip().capitalize()
    query = sys.argv[2].strip()

    if media_type not in ['Movie', 'Series']:
        print(f"Error: Invalid media type '{media_type}'.")
        sys.exit(1)

    # --- STEP 2: TMDB SEARCH ---
    is_id = query.isdigit()
    tmdb_id = int(query) if is_id else None

    if not is_id:
        endpoint = "movie" if media_type == 'Movie' else "tv"
        search_url = f"https://api.themoviedb.org/3/search/{endpoint}"
        params = {"api_key": TMDB_API_KEY, "query": query, "language": "en-US"}

        try:
            res = requests.get(search_url, params=params, timeout=30).json()
            results = res.get('results', [])
        except Exception as e:
            print(f"API Connection Error: {e}")
            sys.exit(1)

        if not results:
            print(f"Error: {media_type} '{query}' not found on TMDB.")
            sys.exit(1)

        title_key = 'title' if media_type == 'Movie' else 'name'
        date_key = 'release_date' if media_type == 'Movie' else 'first_air_date'

        if results:
            print(f"Matches found for '{query}':")
            display_count = min(len(results), 10)
            for i in range(display_count):
                r = results[i]
                year = r.get(date_key, '????')[:4]
                print(f" [{i}] {r.get(title_key)} ({year}) - ID: {r.get('id')}")

            choice = input(f"Selection (0-{display_count-1}, default 0): ").strip()
            idx = int(choice) if (choice.isdigit() and int(choice) < display_count) else 0
        else:
            print(f"Error: No matches found for '{query}'.")
            sys.exit(1)

        selected_item = results[idx]
        tmdb_id = selected_item['id']

    # --- STEP 3: DUPLICATE CHECK ---
    table_name = "movie_metadata" if media_type == 'Movie' else "series_metadata"
    conn = None
    try:
        conn = psycopg2.connect(**DB_PARAMS)
        cur = conn.cursor()
        cur.execute(f"SELECT title FROM registry.{table_name} WHERE tmdb_id = %s", (tmdb_id,))
        existing = cur.fetchone()

        if existing:
            print(f"[!] ALERT: ID {tmdb_id} ({existing[0]}) already exists. Skipping.")
            cur.close()
            conn.close()
            sys.exit(2)
    except Exception as e:
        print(f"Database Check Error: {e}")
        sys.exit(1)

    # --- STEP 4: FETCH DEEP METADATA ---
    detail_endpoint = "movie" if media_type == 'Movie' else "tv"
    detail_params = {"api_key": TMDB_API_KEY, "language": "en-US", "append_to_response": "credits"}
    d = requests.get(f"https://api.themoviedb.org/3/{detail_endpoint}/{tmdb_id}", params=detail_params, timeout=30).json()

    # --- STEP 5: MAPPING DATA ---
    official_title = d.get('title' if media_type == 'Movie' else 'name')
    genres_list = [g.get('name') for g in d.get('genres', [])]
    p_poster_path = d.get('poster_path')  # like /abc123.jpg, or None if TMDB has no poster

    # Initialize all parameters to prevent NameErrors
    p_year, p_country, p_extra_info, p_runtime = None, 'US', 'Unknown', 0
    p_status = 'Backlog' if media_type == 'Movie' else 'Returning'
    p_completed, p_seasons, p_episodes, p_pre_log = None, None, None, 0
    p_watched_pre_log = False  # movies only

    if media_type == 'Movie':
        p_year = int(d.get('release_date', '0000')[:4])
        p_country = d.get('production_countries', [{}])[0].get('iso_3166_1', '??')
        p_runtime = d.get('runtime', 0)
        crew = d.get('credits', {}).get('crew', [])
        p_extra_info = next((m.get('name') for m in crew if m.get('job') == 'Director'), "Unknown")

        watched_input = input("Confirm you've seen this movie BEFORE you save it [y/N]: ").strip().lower()
        p_watched_pre_log = watched_input == 'y'

    else:
        p_year = int(d.get('first_air_date', '0000')[:4])
        p_country = d.get('origin_country', ['??'])[0]
        p_seasons = d.get('number_of_seasons')
        p_episodes = d.get('number_of_episodes')

        networks = d.get('networks', [])
        companies = d.get('production_companies', [])
        if networks:
            p_extra_info = networks[0].get('name', 'Unknown')
        elif companies:
            p_extra_info = companies[0].get('name', 'Unknown')
        else:
            p_extra_info = 'Unknown'

        runtimes = d.get('episode_run_time', [])
        if runtimes:
            p_runtime = int(sum(runtimes) / len(runtimes))
        else:
            last_ep = d.get('last_episode_to_air', {})
            p_runtime = last_ep.get('runtime', 0) if last_ep else 0

        status_map = {
            "Returning Series": "Returning",
            "Ended": "Ended",
            "Canceled": "Cancelled",
            "In Production": "Returning"
            }
        p_status = status_map.get(d.get('status'), "Returning")
        if p_status in ['Ended', 'Cancelled'] and d.get('last_air_date'):
            p_completed = int(d.get('last_air_date')[:4])

        pre_log_input = input(f"Seasons watched PRIOR to logging (default 0): ").strip()
        p_pre_log = int(pre_log_input) if pre_log_input.isdigit() else 0

    # --- STEP 6: CONFIRM BEFORE COMMITTING ---
    print(f" {official_title.upper()} ({p_year})")
    if media_type == 'Series':
        print(f" {p_status} | {p_country} | {p_seasons}S/{p_episodes}E | {p_runtime}m")
        print(f" Platform: {p_extra_info} | Genres: {', '.join(genres_list[:4])}")
    else:
        print(f" Dir: {p_extra_info[:25]} | {p_country} | {p_runtime}m")
        print(f" Gen: {', '.join(genres_list[:4])}")
        print(f" Watched before logging: {'Yes' if p_watched_pre_log else 'No'}")
    print(f" Poster: {p_poster_path if p_poster_path else 'none on TMDB'}")

    confirm = input(f" COMMIT {media_type} to Database? [y/N]: ").strip().lower()
    if confirm != 'y':
        print(f" ABORTED: {official_title} was not saved.")
        conn.close()
        sys.exit(3)

    # --- STEP 7: EXECUTE ---
    try:
        cur = conn.cursor()
        cur.execute(f"""
            CALL registry.add_metadata(
                %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s
            )
        """, (
            media_type, official_title, p_year, p_country, p_extra_info,
            p_runtime, genres_list, tmdb_id, p_status,
            p_completed, p_seasons, p_episodes, p_pre_log, p_watched_pre_log
        ))

        # Save the poster in the same transaction, so a title is never half saved
        if p_poster_path:
            cur.execute("CALL registry.set_poster(%s, %s, %s)", (media_type, tmdb_id, p_poster_path))

        conn.commit()
        print(f" SUCCESS: {official_title} REGISTERED.")
        sys.exit(0)

    except Exception as e:
        if conn:
            conn.rollback()
        print(f"DATABASE ERROR: {e}")
        sys.exit(1)
    finally:
        if conn:
            cur.close()
            conn.close()

if __name__ == "__main__":
    add_media()
