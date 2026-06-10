#!/usr/bin/env python3
import os
import sys
import psycopg2
import requests
import concurrent.futures

# Retrieve database connection string
DB_DSN = os.environ.get(
    "SUPABASE_DATABASE_URL", 
    "postgres://nghiatran:Password1@localhost:5433/artify-core_development?sslmode=disable"
)

# Custom headers mimicking a real web browser to avoid CDN blocks (403/404)
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"
}

def check_url(photo_id, name, url):
    try:
        # Use GET request with stream=True so we only fetch headers (extremely fast, doesn't download the file)
        resp = requests.get(url, headers=HEADERS, timeout=8, stream=True)
        status = resp.status_code
        if status >= 200 and status < 400:
            return photo_id, name, url, True, f"OK ({status})"
        else:
            return photo_id, name, url, False, f"HTTP Error {status}"
    except requests.exceptions.Timeout:
        return photo_id, name, url, False, "Connection Timeout (8s)"
    except requests.exceptions.RequestException as e:
        return photo_id, name, url, False, f"Connection Failure ({type(e).__name__})"

def main():
    print("Connecting to database...")
    try:
        conn = psycopg2.connect(DB_DSN)
        cur = conn.cursor()
    except Exception as e:
        print(f"Failed to connect to database: {e}")
        print("Make sure SUPABASE_DATABASE_URL is set in your environment.")
        sys.exit(1)

    print("Fetching active paintings...")
    cur.execute("SELECT id, name, image_url FROM photos")
    rows = cur.fetchall()
    
    if not rows:
        print("No paintings found in the database.")
        conn.close()
        return

    print(f"Checking {len(rows)} paintings using 15 threads...")
    
    dead_photos = []
    
    # Check URLs in parallel to finish in seconds rather than minutes
    with concurrent.futures.ThreadPoolExecutor(max_workers=15) as executor:
        futures = [executor.submit(check_url, row[0], row[1], row[2]) for row in rows]
        for idx, future in enumerate(concurrent.futures.as_completed(futures)):
            photo_id, name, url, is_alive, reason = future.result()
            if not is_alive:
                print(f"[DEAD] '{name}' -> Reason: {reason} | URL: {url}")
                dead_photos.append(photo_id)
            if (idx + 1) % 50 == 0:
                print(f"Checked {idx + 1}/{len(rows)} paintings...")

    if dead_photos:
        print(f"\nFound {len(dead_photos)} dead/broken paintings. Cleaning library...")
        try:
            # Delete broken photos from the database
            cur.execute("DELETE FROM photos WHERE id = ANY(%s)", (dead_photos,))
            conn.commit()
            print(f"Successfully deleted {len(dead_photos)} broken paintings from the library!")
        except Exception as e:
            conn.rollback()
            print(f"Failed to delete records: {e}")
    else:
        print("\nAll paintings in the library loaded successfully! No dead URLs found.")

    conn.close()

if __name__ == "__main__":
    main()
