import psycopg2
import requests
import concurrent.futures

DB_DSN = "postgres://nghiatran:Password1@localhost:5433/artify-core_development?sslmode=disable"

def check_url(url):
    try:
        r = requests.head(url, timeout=5, headers={"User-Agent": "Mozilla/5.0"})
        return url, r.status_code
    except Exception as e:
        return url, 0

try:
    conn = psycopg2.connect(DB_DSN)
    cur = conn.cursor()
    cur.execute("SELECT image_url FROM photos")
    urls = [row[0] for row in cur.fetchall()]
    conn.close()

    alive = 0
    dead = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
        results = executor.map(check_url, urls)
        for url, status in results:
            if status >= 200 and status < 400:
                alive += 1
            else:
                dead += 1

    print(f"Total URLs: {len(urls)}")
    print(f"Alive (2xx/3xx): {alive}")
    print(f"Dead (4xx/5xx/Timeout): {dead}")

except Exception as e:
    print(f"Error: {e}")
