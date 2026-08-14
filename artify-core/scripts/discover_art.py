#!/usr/bin/env python3
import requests
import uuid
import datetime
import psycopg2
import os
import sys
import time
import re

# Use the environment variable if present (e.g. Supabase connection pooler), otherwise fall back to Docker-internal DB
DB_DSN = os.environ.get("SUPABASE_DATABASE_URL", os.environ.get("DATABASE_URL", "postgres://nghiatran:Password1@db:5432/artify-core_development?sslmode=disable"))

COMMON_MAPPINGS = {
    "picasso": "pablo-picasso",
    "van gogh": "vincent-van-gogh",
    "da vinci": "leonardo-da-vinci",
    "monet": "claude-monet",
    "degas": "edgar-degas",
    "klimt": "gustav-klimt",
    "warhol": "andy-warhol",
    "dalí": "salvador-dali",
    "dali": "salvador-dali",
    "rembrandt": "rembrandt",
    "vermeer": "johannes-vermeer",
    "botticelli": "sandro-botticelli",
    "michelangelo": "michelangelo",
    "raphael": "raphael",
    "hokusai": "katsushika-hokusai",
    "basquiat": "jean-michel-basquiat",
    "toulouse-lautrec": "henri-de-toulouse-lautrec",
    "toulouse lautrec": "henri-de-toulouse-lautrec",
    "la tour": "georges-de-la-tour",
    "de la tour": "georges-de-la-tour",
    "rothko": "mark-rothko",
    "mark rothko": "mark-rothko",
    "kandinsky": "wassily-kandinsky",
    "matisse": "henri-matisse",
    "cezanne": "paul-cezanne",
    "renoir": "pierre-auguste-renoir",
    "gauguin": "paul-gauguin",
    "modigliani": "amedeo-modigliani",
    "turner": "joseph-mallord-william-turner",
    "constable": "john-constable",
    "caravaggio": "caravaggio",
    "mucha": "alphonse-mucha",
    "hopper": "edward-hopper",
}

def make_slug(name):
    # Check common mapped abbreviations first
    short_name = name.lower().strip()
    if short_name in COMMON_MAPPINGS:
        return COMMON_MAPPINGS[short_name]
    
    # Otherwise, generate standard slug
    cleaned = re.sub(r"['.()\"]", "", name.lower())
    slug = re.sub(r"[\s-]+", "-", cleaned).strip("-")
    return slug

def build_jeopardy_blurb(title, artist, bio, date, medium, loc, style, culture):
    parts = [f"JEOPARDY KEY: \"{title}\" by {artist}."]
    if bio: parts.append(f"Artist: {bio}.")
    if date: parts.append(f"Date: {date}.")
    if medium: parts.append(f"Medium: {medium}.")
    if style: parts.append(f"Style/Period: {style}.")
    if culture: parts.append(f"Cultural origin: {culture}.")
    if loc: parts.append(f"Currently housed at: {loc}.")
    return " ".join(parts)

def fetch_wikiart_paintings(artist_slug):
    print(f"Checking WikiArt for slug: {artist_slug}")
    url = f"https://www.wikiart.org/en/App/Painting/PaintingsByArtist?artistUrl={artist_slug}&json=2"
    headers = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"}
    
    try:
        resp = requests.get(url, headers=headers, timeout=15)
        if resp.status_code != 200:
            print(f"WikiArt returned status code: {resp.status_code}")
            return []
        
        results = resp.json()
        if not isinstance(results, list):
            return []
        
        paintings = []
        # Limit to top 15 paintings to keep seeding lightweight
        for p in results[:15]:
            img_url = p.get("image")
            if not img_url:
                continue
            
            # Standardize image size suffix if present
            if "!Large.jpg" not in img_url:
                img_url = img_url + "!Large.jpg"
                
            title = p.get("title", "Untitled")
            artist = p.get("artistName", "Unknown")
            year = p.get("yearAsString", p.get("completitionYear", ""))
            
            # Resolve style based on year safely
            style = "Classical Art"
            if year:
                try:
                    year_digits = re.sub(r"\D", "", str(year))
                    if year_digits and int(year_digits) > 1900:
                        style = "Modern Art"
                except:
                    pass

            paintings.append({
                "title": title,
                "artist": artist,
                "artist_bio": artist,
                "nationality": "",
                "date": str(year) if year else "",
                "style": style,
                "medium": "Oil painting",
                "dimensions": f"{p.get('width', 0)} x {p.get('height', 0)}",
                "location": "National Gallery of Art / Museum Collection",
                "image_url": img_url,
                "source": "WikiArt"
            })
        return paintings
    except Exception as e:
        print(f"Error calling WikiArt API: {e}")
        return []

def fetch_aic_paintings(query):
    print(f"Checking Art Institute of Chicago / National Gallery for: {query}")
    aic_url = f"https://api.artic.edu/api/v1/artworks/search?q={query}&fields=id,title,artist_display,image_id,date_display,style_title,medium_display&limit=10"
    try:
        resp = requests.get(aic_url, timeout=10)
        if resp.status_code != 200: return []
        data = resp.json().get("data", [])
        paintings = []
        for d in data:
            img_id = d.get("image_id")
            if not img_id: continue
            img_url = f"https://www.artic.edu/iiif/2/{img_id}/full/843,/0/default.jpg"
            title = d.get("title", "Untitled")
            artist_raw = d.get("artist_display", "Unknown")
            artist_name = artist_raw.split("\n")[0].split("(")[0].strip()
            if not artist_name: artist_name = "Unknown Artist"
            
            paintings.append({
                "title": title,
                "artist": artist_name,
                "artist_bio": artist_raw,
                "nationality": "",
                "date": d.get("date_display", ""),
                "style": d.get("style_title", "Fine Art"),
                "medium": d.get("medium_display", "Painting"),
                "dimensions": "",
                "location": "National Gallery of Art / Art Institute",
                "image_url": img_url,
                "source": "NGA / Art Institute"
            })
        return paintings
    except Exception as e:
        print(f"Error calling AIC API: {e}")
        return []

def fetch_met_paintings(query):
    print(f"Falling back to Met Museum search for: {query}")
    search_url = f"https://collectionapi.metmuseum.org/public/collection/v1/search?hasImages=true&q={query}"
    
    try:
        resp = requests.get(search_url, timeout=10)
        if resp.status_code != 200: return []
        
        object_ids = resp.json().get("objectIDs", [])
        if not object_ids: return []
        
        paintings = []
        for obj_id in object_ids[:10]:
            obj_url = f"https://collectionapi.metmuseum.org/public/collection/v1/objects/{obj_id}"
            obj_resp = requests.get(obj_url, timeout=5)
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
        return paintings
    except Exception as e:
        print(f"Error calling Met Museum API: {e}")
        return []

def discover_and_seed(query):
    print(f"Starting art discovery for: {query}")
    
    # 1. Attempt WikiArt first
    slug = make_slug(query)
    paintings = fetch_wikiart_paintings(slug)
    
    # 2. Attempt Art Institute / National Gallery provider
    if not paintings:
        paintings = fetch_aic_paintings(query)
        
    # 3. Fallback to Met Museum
    if not paintings:
        paintings = fetch_met_paintings(query)
        
    if not paintings:
        print("No paintings found from either WikiArt or Met Museum.")
        return
        
    print(f"Found {len(paintings)} paintings. Seeding database...")
    
    # 3. Insert into DB
    try:
        conn = psycopg2.connect(DB_DSN)
        cur = conn.cursor()
        inserted = 0
        for p in paintings:
            # 1. Author resolution
            artist_name = p['artist'].split("(")[0].strip()
            cur.execute("SELECT id FROM authors WHERE name = %s", (artist_name,))
            row = cur.fetchone()
            if row:
                author_id = row[0]
            else:
                author_id = str(uuid.uuid4())
                cur.execute("INSERT INTO authors (id, created_at, updated_at, name, born, died, nationality, wikipedia, original_source) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)",
                            (author_id, datetime.datetime.now(), datetime.datetime.now(), artist_name, p['artist_bio'], '', p['nationality'], '', p['source']))
            
            # 2. Check if this exact image URL is already in database
            cur.execute("SELECT id FROM photos WHERE image_url = %s", (p['image_url'],))
            if cur.fetchone():
                continue
            
            # 3. Differentiate duplicate titles for the same artist (e.g. multiple "Smallsword" pieces)
            photo_title = p['title']
            cur.execute("SELECT COUNT(*) FROM photos WHERE name LIKE %s AND author_id = %s", (p['title'] + '%', author_id))
            title_count = cur.fetchone()[0]
            if title_count > 0:
                photo_title = f"{p['title']} #{title_count + 1}"

            # 4. Insert photo
            info = build_jeopardy_blurb(photo_title, p['artist'], p['artist_bio'], p['date'], p['medium'], p['location'], p['style'], "")
            cur.execute("INSERT INTO photos (id, created_at, updated_at, name, image_url, author_id, width, height, info, date, style, location, dimensions, media, original_source, is_favorite) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
                        (str(uuid.uuid4()), datetime.datetime.now(), datetime.datetime.now(), photo_title, p['image_url'], author_id, 1920, 1080, info, p['date'], p['style'], p['location'], p['dimensions'], p['medium'], p['source'], False))
            inserted += 1
        conn.commit()
        print(f"Success: Inserted {inserted} new paintings.")
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        discover_and_seed(sys.argv[1])
