import sys
import os
import psycopg2
import uuid
import datetime

# Database Connection URL
# Try to get SUPABASE_DATABASE_URL, fallback to local dev postgres
DB_URL = os.environ.get("SUPABASE_DATABASE_URL")
if not DB_URL:
    print("Warning: SUPABASE_DATABASE_URL environment variable not set.")
    print("Defaulting to local development database.")
    DB_URL = "postgres://nghiatran:Password1@localhost:5433/artify-core_development?sslmode=disable"

def publish(version_str, url, notes):
    try:
        conn = psycopg2.connect(DB_URL)
        cur = conn.cursor()
        
        # Check if versions table exists
        cur.execute("SELECT to_regclass('public.versions')")
        if not cur.fetchone()[0]:
            print("Error: The 'versions' table does not exist in the database.")
            return

        # Check if version already exists
        cur.execute("SELECT id FROM versions WHERE build_version = %s", (version_str,))
        row = cur.fetchone()
        
        if row:
            print(f"Version {version_str} already exists. Updating it...")
            cur.execute(
                "UPDATE versions SET url = %s, notes = %s, updated_at = %s WHERE build_version = %s",
                (url, notes, datetime.datetime.now(), version_str)
            )
            conn.commit()
            print(f"Successfully updated version {version_str} in database.")
            return
        
        version_id = str(uuid.uuid4())
        # Try to parse build number (e.g. "3.3" -> 33)
        try:
            build_num = int("".join(filter(str.isdigit, version_str)))
        except:
            build_num = 1
            
        cur.execute(
            "INSERT INTO versions (id, build_version, build_number, created_at, updated_at, url, notes) VALUES (%s, %s, %s, %s, %s, %s, %s)",
            (version_id, version_str, build_num, datetime.datetime.now(), datetime.datetime.now(), url, notes)
        )
        conn.commit()
        print(f"Successfully published version {version_str} to database (ID: {version_id})!")
    except Exception as e:
        print(f"Error publishing version: {e}")
    finally:
        if 'conn' in locals() and conn:
            conn.close()

if __name__ == "__main__":
    if len(sys.argv) < 4:
        print("Usage: python publish_version.py <version> <url> <release_notes>")
        print("Example: python publish_version.py 3.3 https://example.com/artistry.zip 'New settings and quiz features'")
        sys.exit(1)
    publish(sys.argv[1], sys.argv[2], sys.argv[3])
