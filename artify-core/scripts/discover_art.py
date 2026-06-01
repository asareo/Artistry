#!/usr/bin/env python3
import requests
import uuid
import datetime
import psycopg2
import os
import sys
import time

# Use the environment variable if present (e.g. Supabase connection pooler), otherwise fall back to Docker-internal DB
DB_DSN = os.environ.get("SUPABASE_DATABASE_URL", "postgres://nghiatran:Password1@db:5432/artify-core_development?sslmode=disable")

def build_jeopardy_blurb(title, artist, bio, date, medium, loc, style, culture):
    parts = [f"JEOPARDY KEY: \"{title}\" by {artist}."]
    if bio: parts.append(f"Artist: {bio}.")
    if date: parts.append(f"Date: {date}.")
    if medium: parts.append(f"Medium: {medium}.")
    if style: parts.append(f"Style/Period: {style}.")
    if culture: parts.append(f"Cultural origin: {culture}.")
    if loc: parts.append(f"Currently housed at: {loc}.")
    return " ".join(parts)

def discover_and_seed(query):
    print(f"Discovering new art for: {query}")
    search_url = f"https://collectionapi.metmuseum.org/public/collection/v1/search?hasImages=true&q={query}"
    
    resp = requests.get(search_url)
    if resp.status_code != 200: return
    
    object_ids = resp.json().get("objectIDs", [])
    if not object_ids: return
    
    paintings = []
    # Fetch top 50 matches
    for obj_id in object_ids[:50]:
        obj_url = f"https://collectionapi.metmuseum.org/public/collection/v1/objects/{obj_id}"
        obj_resp = requests.get(obj_url)
        if obj_resp.status_code != 200: continue
        
        d = obj_resp.json()
        if not d.get("primaryImage") or not d.get("artistDisplayName"): continue
        
        artist = d.get("artistDisplayName", "Unknown")
        title = d.get("title", "Untitled")
        
        paintings.append({
            "title": title, "artist": artist, "artist_bio": d.get("artistDisplayBio", ""),
            "nationality": d.get("artistNationality", ""), "date": d.get("objectDate", ""),
            "style": d.get("period", d.get("department", "")),
            "medium": d.get("medium", ""), "dimensions": d.get("dimensions", ""),
            "location": d.get("repository", "Met Museum"),
            "image_url": d.get("primaryImage"), "source": "Met Museum Discover"
        })
        time.sleep(0.05)

    # Insert into DB
    try:
        conn = psycopg2.connect(DB_DSN)
        cur = conn.cursor()
        inserted = 0
        for p in paintings:
            cur.execute("SELECT id FROM photos WHERE name = %s", (p['title'],))
            if cur.fetchone(): continue
            
            # Author
            artist_name = p['artist'].split("(")[0].strip()
            cur.execute("SELECT id FROM authors WHERE name = %s", (artist_name,))
            row = cur.fetchone()
            if row: author_id = row[0]
            else:
                author_id = str(uuid.uuid4())
                cur.execute("INSERT INTO authors (id, created_at, updated_at, name, born, died, nationality, wikipedia, original_source) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)",
                            (author_id, datetime.datetime.now(), datetime.datetime.now(), artist_name, p['artist_bio'], '', p['nationality'], '', p['source']))
            
            # Photo
            info = build_jeopardy_blurb(p['title'], p['artist'], p['artist_bio'], p['date'], p['medium'], p['location'], p['style'], "")
            cur.execute("INSERT INTO photos (id, created_at, updated_at, name, image_url, author_id, width, height, info, date, style, location, dimensions, media, original_source, is_favorite) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
                        (str(uuid.uuid4()), datetime.datetime.now(), datetime.datetime.now(), p['title'], p['image_url'], author_id, 1920, 1080, info, p['date'], p['style'], p['location'], p['dimensions'], p['medium'], p['source'], False))
            inserted += 1
        conn.commit()
        print(f"Success: Inserted {inserted} new paintings.")
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    if len(sys.argv) > 1: discover_and_seed(sys.argv[1])
