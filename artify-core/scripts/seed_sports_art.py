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

# Curated list of classical masterpieces featured on "Art But Make It Sports"
SPORTS_ARTWORKS = [
    {
        "title": "The Retreat of Hugues de Payens",
        "artist": "Georges Mathieu",
        "artist_bio": "French, 1921–2012",
        "nationality": "French",
        "date": "1958",
        "style": "Lyrical Abstraction / Tachism",
        "medium": "Oil on canvas",
        "dimensions": "200 × 300 cm",
        "location": "Private Collection",
        "image_url": "https://upload.wikimedia.org/wikipedia/commons/4/4e/Georges_Mathieu_La_Retraite_d%27Hugues_de_Payens_1958.jpg",
        "info": "JEOPARDY KEY: \"The Retreat of Hugues de Payens\" by Georges Mathieu. Paired with Megan Keller's iconic hockey goal at the Winter Olympics by LJ Rader on 'Art But Make It Sports'.",
        "source": "Wikimedia Commons"
    },
    {
        "title": "Suprematism",
        "artist": "Nikolai Suetin",
        "artist_bio": "Russian, 1897–1954",
        "nationality": "Russian",
        "date": "1921",
        "style": "Suprematism",
        "medium": "Oil on canvas",
        "dimensions": "65 × 52 cm",
        "location": "State Russian Museum, Saint Petersburg",
        "image_url": "https://upload.wikiart.org/images/nikolai-suetin/suprematism-1921.jpg",
        "info": "JEOPARDY KEY: \"Suprematism\" by Nikolai Suetin. Paired with Connor Hellebuyck's legendary stick save at the Olympics by LJ Rader on 'Art But Make It Sports'.",
        "source": "WikiArt"
    },
    {
        "title": "The Dugout",
        "artist": "Norman Rockwell",
        "artist_bio": "American, 1894–1978",
        "nationality": "American",
        "date": "1948",
        "style": "Realism / Illustration",
        "medium": "Oil on canvas",
        "dimensions": "48 × 45 cm",
        "location": "Art Institute of Chicago",
        "image_url": "https://upload.wikimedia.org/wikipedia/en/d/d3/The_Dugout_%28Rockwell_painting%29.jpg",
        "info": "JEOPARDY KEY: \"The Dugout\" by Norman Rockwell. Featured by LJ Rader at the Art Institute of Chicago on 'Art But Make It Sports'.",
        "source": "Wikimedia Commons"
    },
    {
        "title": "Judith with the Head of Holofernes",
        "artist": "Charles Mellin",
        "artist_bio": "French, 1597–1649",
        "nationality": "French",
        "date": "c. 1630",
        "style": "Baroque",
        "medium": "Oil on canvas",
        "dimensions": "100 × 75 cm",
        "location": "National Museum in Warsaw",
        "image_url": "https://upload.wikimedia.org/wikipedia/commons/e/ea/Charles_Mellin_-_Judith_with_the_Head_of_Holofernes_-_M.Ob.131_-_National_Museum_in_Warsaw.jpg",
        "info": "JEOPARDY KEY: \"Judith with the Head of Holofernes\" by Charles Mellin. Paired with Caitlin Clark at the 2024 WNBA draft on 'Art But Make It Sports'.",
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
    },
    {
        "title": "The Feast of Bacchus",
        "artist": "Philips Koninck",
        "artist_bio": "Dutch, 1619–1688",
        "nationality": "Dutch",
        "date": "1654",
        "style": "Dutch Golden Age",
        "medium": "Oil on canvas",
        "dimensions": "145 × 180 cm",
        "location": "Bredius Museum, The Hague",
        "image_url": "https://upload.wikimedia.org/wikipedia/commons/b/b2/Philips_Koninck_-_The_Feast_of_Bacchus_-_Google_Art_Project.jpg",
        "info": "JEOPARDY KEY: \"The Feast of Bacchus\" by Philips Koninck. Paired with Jason Kelce celebrating a touchdown on 'Art But Make It Sports'.",
        "source": "Wikimedia Commons"
    },
    {
        "title": "The Persistence of Memory",
        "artist": "Salvador Dalí",
        "artist_bio": "Spanish, 1904–1989",
        "nationality": "Spanish",
        "date": "1931",
        "style": "Surrealism",
        "medium": "Oil on canvas",
        "dimensions": "24 × 33 cm",
        "location": "Museum of Modern Art, New York",
        "image_url": "https://uploads7.wikiart.org/images/salvador-dali/the-persistence-of-memory-1931.jpg",
        "info": "JEOPARDY KEY: \"The Persistence of Memory\" by Salvador Dalí. Paired with Novak Djokovic breaking a tennis racquet on 'Art But Make It Sports'.",
        "source": "WikiArt"
    },
    {
        "title": "Man Carrying a Baby",
        "artist": "Salvador Dalí",
        "artist_bio": "Spanish, 1904–1989",
        "nationality": "Spanish",
        "date": "1941",
        "style": "Surrealism",
        "medium": "Oil on canvas",
        "dimensions": "41 × 33 cm",
        "location": "Private Collection",
        "image_url": "https://uploads6.wikiart.org/images/salvador-dali/man-carrying-a-baby-1941.jpg",
        "info": "JEOPARDY KEY: \"Man Carrying a Baby\" by Salvador Dalí. Paired with LeBron James celebrating a WNBA/NBA championship/victory on 'Art But Make It Sports'.",
        "source": "WikiArt"
    }
]

def check_image_urls():
    print("Checking availability of curated image URLs...")
    valid_artworks = []
    headers = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"}
    
    for art in SPORTS_ARTWORKS:
        try:
            resp = requests.head(art["image_url"], headers=headers, timeout=5)
            if resp.status_code == 200:
                print(f"  ✓ Valid image URL for: {art['title']}")
                valid_artworks.append(art)
            else:
                # If HEAD fails, try a GET request with stream=True
                resp_get = requests.get(art["image_url"], headers=headers, timeout=5, stream=True)
                if resp_get.status_code == 200:
                    print(f"  ✓ Valid image URL for: {art['title']}")
                    valid_artworks.append(art)
                else:
                    print(f"  ✗ URL failed for: {art['title']} (Status: {resp_get.status_code})")
        except Exception as e:
            print(f"  ✗ Network error for: {art['title']} ({type(e).__name__})")
            
    return valid_artworks

def seed_database(artworks):
    print(f"\nConnecting to database...")
    try:
        conn = psycopg2.connect(DB_DSN)
        cur = conn.cursor()
    except Exception as e:
        print(f"✗ Failed to connect to database: {e}")
        sys.exit(1)

    inserted = 0
    skipped = 0

    for p in artworks:
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
    valid = check_image_urls()
    if valid:
        seed_database(valid)
    else:
        print("No valid artwork URLs found.")
