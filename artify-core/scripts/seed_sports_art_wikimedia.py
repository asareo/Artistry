#!/usr/bin/env python3
import os
import sys
import uuid
import datetime
import requests
import psycopg2

DB_DSN = os.environ.get(
    "SUPABASE_DATABASE_URL",
    "postgresql://postgres.nybciquulmttuzpcbpjg:sWP0Ta95tGuVeqIL@aws-1-us-west-2.pooler.supabase.com:6543/postgres"
)

# Curated list of classical masterpieces featured on "Art But Make It Sports" (Wikimedia Commons files)
WIKIMEDIA_MATCHUPS = [
    {
        "file_title": "The Intervention of the Sabine Women - David (Louvre INV 3691).jpg",
        "title": "The Intervention of the Sabine Women",
        "artist": "Jacques-Louis David",
        "artist_bio": "French, 1748–1825",
        "nationality": "French",
        "date": "1799",
        "style": "Neoclassicism",
        "medium": "Oil on canvas",
        "dimensions": "385 × 522 cm",
        "location": "Louvre Museum, Paris",
        "info": "JEOPARDY KEY: \"The Intervention of the Sabine Women\" by Jacques-Louis David. Paired with complex player pile-ups and strategic formations in American Football by LJ Rader on 'Art But Make It Sports'.",
        "source": "Wikimedia Commons"
    },
    {
        "file_title": "Michelangelo Buonarroti - The Torment of Saint Anthony - Google Art Project.jpg",
        "title": "The Torment of Saint Anthony",
        "artist": "Michelangelo",
        "artist_bio": "Italian, 1475–1564",
        "nationality": "Italian",
        "date": "c. 1487",
        "style": "High Renaissance",
        "medium": "Oil and tempera on panel",
        "dimensions": "47 × 35 cm",
        "location": "Kimbell Art Museum, Fort Worth, Texas",
        "info": "JEOPARDY KEY: \"The Torment of Saint Anthony\" by Michelangelo. Paired with high-energy aerial sports moments, such as NBA players dunking in a crowd of defenders, by LJ Rader on 'Art But Make It Sports'.",
        "source": "Wikimedia Commons"
    },
    {
        "file_title": "Philips Koninck - The Feast of Bacchus - Museum Bredius.jpg",
        "title": "The Feast of Bacchus",
        "artist": "Philips Koninck",
        "artist_bio": "Dutch, 1619–1688",
        "nationality": "Dutch",
        "date": "1654",
        "style": "Dutch Golden Age",
        "medium": "Oil on canvas",
        "dimensions": "145 × 180 cm",
        "location": "Museum Bredius, The Hague",
        "info": "JEOPARDY KEY: \"The Feast of Bacchus\" by Philips Koninck. Paired with Jason Kelce celebrating a touchdown bare-chested by LJ Rader on 'Art But Make It Sports'.",
        "source": "Wikimedia Commons"
    },
    {
        "file_title": "Charles Mellin - Judith with the Head of Holofernes - WGA14769.jpg",
        "title": "Judith with the Head of Holofernes",
        "artist": "Charles Mellin",
        "artist_bio": "French, 1597–1649",
        "nationality": "French",
        "date": "c. 1630",
        "style": "Baroque",
        "medium": "Oil on canvas",
        "dimensions": "100 × 75 cm",
        "location": "National Museum in Warsaw",
        "info": "JEOPARDY KEY: \"Judith with the Head of Holofernes\" by Charles Mellin. Paired with Caitlin Clark at the 2024 WNBA draft by LJ Rader on 'Art But Make It Sports'.",
        "source": "Wikimedia Commons"
    },
    {
        "file_title": "The Martyrdom of Saint Matthew-Caravaggio (c. 1599-1600).jpg",
        "title": "The Martyrdom of Saint Matthew",
        "artist": "Caravaggio",
        "artist_bio": "Italian, 1571–1610",
        "nationality": "Italian",
        "date": "1600",
        "style": "Baroque / Tenebrism",
        "medium": "Oil on canvas",
        "dimensions": "323 × 343 cm",
        "location": "San Luigi dei Francesi, Rome",
        "info": "JEOPARDY KEY: \"The Martyrdom of Saint Matthew\" by Caravaggio. Paired with dramatic sports poses and players taunting their opponents by LJ Rader on 'Art But Make It Sports'.",
        "source": "Wikimedia Commons"
    },
    {
        "file_title": "Lamentation - Botticelli.jpg",
        "title": "Lamentation Over the Dead Christ",
        "artist": "Sandro Botticelli",
        "artist_bio": "Italian, 1445–1510",
        "nationality": "Italian",
        "date": "c. 1490",
        "style": "Early Renaissance",
        "medium": "Tempera on panel",
        "dimensions": "140 × 207 cm",
        "location": "Alte Pinakothek, Munich",
        "info": "JEOPARDY KEY: \"Lamentation Over the Dead Christ\" by Sandro Botticelli. Paired with athletes collapsed on the field in exhaustion or defeat by LJ Rader on 'Art But Make It Sports'.",
        "source": "Wikimedia Commons"
    }
]

# Static files that don't need API search
STATIC_MATCHUPS = [
    {
        "title": "The Death of Socrates",
        "artist": "Jacques-Louis David",
        "artist_bio": "French, 1748–1825",
        "nationality": "French",
        "date": "1787",
        "style": "Neoclassicism",
        "medium": "Oil on canvas",
        "dimensions": "130 × 196 cm",
        "location": "Metropolitan Museum of Art, New York",
        "image_url": "https://upload.wikimedia.org/wikipedia/commons/8/8c/David_-_The_Death_of_Socrates.jpg",
        "info": "JEOPARDY KEY: \"The Death of Socrates\" by Jacques-Louis David. Paired with dramatic locker room and sidelines sports interactions by LJ Rader on 'Art But Make It Sports'.",
        "source": "Wikimedia Commons"
    },
    {
        "title": "Liberty Leading the People",
        "artist": "Eugène Delacroix",
        "artist_bio": "French, 1798–1863",
        "nationality": "French",
        "date": "1830",
        "style": "Romanticism",
        "medium": "Oil on canvas",
        "dimensions": "260 × 325 cm",
        "location": "Louvre Museum, Paris",
        "image_url": "https://upload.wikimedia.org/wikipedia/commons/a/a7/Eug%C3%A8ne_Delacroix_-_La_libert%C3%A9_guidant_le_peuple.jpg",
        "info": "JEOPARDY KEY: \"Liberty Leading the People\" by Eugène Delacroix. Paired with Sabrina Ionescu celebrating in the 2023 WNBA Playoffs on 'Art But Make It Sports'.",
        "source": "Wikimedia Commons"
    }
]

def resolve_wikimedia_url(file_title):
    headers = {
        "User-Agent": "ArtifyApp/1.0 (contact@artifyapp.com) Mozilla/5.0"
    }
    url = "https://commons.wikimedia.org/w/api.php"
    params = {
        "action": "query",
        "titles": f"File:{file_title}",
        "prop": "imageinfo",
        "iiprop": "url",
        "format": "json"
    }
    try:
        resp = requests.get(url, headers=headers, params=params, timeout=10)
        data = resp.json()
        pages = data.get("query", {}).get("pages", {})
        for page_id, page in pages.items():
            imageinfo = page.get("imageinfo", [])
            if imageinfo:
                return imageinfo[0].get("url")
    except Exception as e:
        print(f"Error querying API for {file_title}: {e}")
    return None

def main():
    print("Resolving Wikimedia URLs via MediaWiki API...")
    to_seed = []
    
    # 1. Resolve dynamic matches
    headers = {"User-Agent": "ArtifyApp/1.0 (contact@artifyapp.com) Mozilla/5.0"}
    for art in WIKIMEDIA_MATCHUPS:
        url = resolve_wikimedia_url(art["file_title"])
        if url:
            # Verify URL returns 200
            try:
                resp = requests.get(url, headers=headers, timeout=5, stream=True)
                if resp.status_code == 200:
                    art["image_url"] = url
                    to_seed.append(art)
                    print(f"  ✓ Resolved: {art['title']} -> {url}")
                else:
                    print(f"  ✗ Failed to verify URL for: {art['title']} (Status: {resp.status_code})")
            except Exception as e:
                print(f"  ✗ Connection failure verifying: {art['title']} ({type(e).__name__})")
        else:
            print(f"  ✗ Could not find Wikimedia URL for: {art['title']}")
            
    # 2. Add static verified matches
    for art in STATIC_MATCHUPS:
        to_seed.append(art)
        print(f"  ✓ Verified Static: {art['title']}")
        
    if not to_seed:
        print("No artworks resolved to valid URLs. Aborting.")
        return
        
    print(f"\nConnecting to database...")
    try:
        conn = psycopg2.connect(DB_DSN)
        cur = conn.cursor()
    except Exception as e:
        print(f"✗ Failed to connect to database: {e}")
        sys.exit(1)

    inserted = 0
    skipped = 0

    for p in to_seed:
        # Check if photo already exists
        cur.execute("SELECT id FROM photos WHERE name = %s", (p['title'],))
        if cur.fetchone():
            print(f"  - Skipped (already exists): {p['title']}")
            skipped += 1
            continue

        # Upsert author
        cur.execute("SELECT id FROM authors WHERE name = %s", (p['artist'],))
        author_row = cur.fetchone()

        if author_row:
            author_id = author_row[0]
        else:
            author_id = str(uuid.uuid4())
            now = datetime.datetime.now()
            cur.execute(
                """INSERT INTO authors (id, created_at, updated_at, name, born, died, nationality, wikipedia, original_source)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)""",
                (author_id, now, now, p['artist'], p['artist_bio'], '', 
                 p['nationality'], '', p['source'])
            )

        # Insert photo
        photo_id = str(uuid.uuid4())
        now = datetime.datetime.now()
        cur.execute(
            """INSERT INTO photos (id, created_at, updated_at, name, image_url, author_id, 
               width, height, info, date, style, location, dimensions, media, original_source, is_favorite)
               VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)""",
            (photo_id, now, now, p['title'], p['image_url'], author_id, 1920, 1080,
             p['info'], p['date'], p['style'], p['location'], p.get('dimensions', ''),
             p['medium'], p['source'], False)
        )
        print(f"  ✓ Seeded: {p['title']} by {p['artist']}")
        inserted += 1

    conn.commit()
    cur.close()
    conn.close()
    print(f"\n═══ SUMMARY ═══")
    print(f"Successfully seeded: {inserted}")
    print(f"Skipped duplicates: {skipped}")

if __name__ == "__main__":
    main()
