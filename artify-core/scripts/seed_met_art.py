#!/usr/bin/env python3
"""
Artify Database Seeder
Fetches 17th-19th century masterpieces from:
  1. The Metropolitan Museum of Art (Met) API
  2. Art Institute of Chicago (AIC) API
  3. Curated MoMA/Whitney highlights (no public API, so hardcoded)

Stores metadata + image URLs in the local PostgreSQL database.
"""

import requests
import uuid
import datetime
import psycopg2
import sys
import time

# Docker exposes PostgreSQL on port 5433 on the host
DB_DSN = "postgres://nghiatran:Password1@localhost:5433/artify-core_development?sslmode=disable"

# ─────────────────────────────────────────────
# 1. Metropolitan Museum of Art
# ─────────────────────────────────────────────
def fetch_met_art():
    print("\n═══ METROPOLITAN MUSEUM OF ART ═══")
    print("Fetching highlighted paintings (1600-1900)...")
    
    search_url = (
        "https://collectionapi.metmuseum.org/public/collection/v1/search"
        "?hasImages=true&isHighlight=true&q=painting|masterpiece|landscape|portrait"
        "&dateBegin=1500&dateEnd=1950"
    )
    
    resp = requests.get(search_url)
    if resp.status_code != 200:
        print(f"  ✗ Search failed: {resp.status_code}")
        return []

    object_ids = resp.json().get("objectIDs", [])
    if not object_ids:
        print("  ✗ No objects found.")
        return []
    
    paintings = []
    print(f"  Found {len(object_ids)} highlights. Fetching details...")
    
    for obj_id in object_ids[:300]:
        obj_url = f"https://collectionapi.metmuseum.org/public/collection/v1/objects/{obj_id}"
        obj_resp = requests.get(obj_url)
        if obj_resp.status_code != 200:
            continue
            
        d = obj_resp.json()
        
        # Only paintings with images and known artists
        if not d.get("primaryImage") or not d.get("artistDisplayName"):
            continue
        if d.get("classification", "").lower() not in ("paintings", "painting", ""):
            continue
            
        artist = d.get("artistDisplayName", "Unknown")
        bio = d.get("artistDisplayBio", "")
        nat = d.get("artistNationality", "")
        title = d.get("title", "Untitled")
        date = d.get("objectDate", "")
        medium = d.get("medium", "")
        dims = d.get("dimensions", "")
        loc = d.get("repository", "Metropolitan Museum of Art, New York")
        img = d.get("primaryImage")
        dept = d.get("department", "")
        period = d.get("period", "")
        culture = d.get("culture", "")
        
        # Derive style from department/period/culture
        style = period if period else dept
        
        # Jeopardy-optimized info blurb
        info = build_jeopardy_blurb(
            title=title, artist=artist, bio=bio, date=date,
            medium=medium, loc=loc, style=style, culture=culture
        )
        
        paintings.append({
            "title": title, "artist": artist, "artist_bio": bio,
            "nationality": nat, "date": date, "style": style,
            "medium": medium, "dimensions": dims, "location": loc,
            "image_url": img, "info": info, "source": "Met Museum"
        })
        print(f"  ✓ {title} — {artist}")
        time.sleep(0.1)  # Rate limit courtesy

    print(f"  Total from Met: {len(paintings)}")
    return paintings


# ─────────────────────────────────────────────
# 2. Art Institute of Chicago
# ─────────────────────────────────────────────
def fetch_aic_art():
    print("\n═══ ART INSTITUTE OF CHICAGO ═══")
    print("Fetching public domain paintings (1600-1900)...")
    
    iiif_base = "https://www.artic.edu/iiif/2"
    paintings = []
    
    for page in range(1, 20):  # 20 pages × 20 = up to 400 candidates
        url = (
            "https://api.artic.edu/api/v1/artworks/search"
            "?q=painting"
            "&query[bool][must][0][range][date_start][gte]=1600"
            "&query[bool][must][1][range][date_end][lte]=1900"
            "&query[bool][must][2][term][is_public_domain]=true"
            "&fields=id,title,artist_display,date_display,medium_display,"
            "dimensions,place_of_origin,style_title,classification_title,"
            "image_id,thumbnail,artist_title"
            f"&limit=20&page={page}"
        )
        
        resp = requests.get(url)
        if resp.status_code != 200:
            print(f"  ✗ Page {page} failed: {resp.status_code}")
            continue
        
        data = resp.json().get("data", [])
        
        for d in data:
            image_id = d.get("image_id")
            artist = d.get("artist_title") or d.get("artist_display", "Unknown")
            title = d.get("title", "Untitled")
            
            if not image_id or not artist or artist == "Unknown":
                continue
            
            # AIC IIIF image URL (full resolution)
            img_url = f"{iiif_base}/{image_id}/full/1686,/0/default.jpg"
            
            style = d.get("style_title") or d.get("classification_title") or ""
            date = d.get("date_display", "")
            medium = d.get("medium_display", "")
            dims = d.get("dimensions", "")
            origin = d.get("place_of_origin", "")
            loc = f"Art Institute of Chicago"
            bio = d.get("artist_display", "")
            
            # Parse nationality from artist_display (e.g., "French, 1840-1926")
            nat = ""
            if bio and "," in bio:
                parts = bio.split("\n")
                if len(parts) > 1:
                    nat = parts[1].strip().split(",")[0]
            
            info = build_jeopardy_blurb(
                title=title, artist=artist, bio=bio, date=date,
                medium=medium, loc=loc, style=style, culture=origin
            )
            
            paintings.append({
                "title": title, "artist": artist, "artist_bio": bio,
                "nationality": nat, "date": date, "style": style,
                "medium": medium, "dimensions": dims, "location": loc,
                "image_url": img_url, "info": info, "source": "Art Institute of Chicago"
            })
            print(f"  ✓ {title} — {artist}")
        
        time.sleep(0.5)
    
    print(f"  Total from AIC: {len(paintings)}")
    return paintings


# ─────────────────────────────────────────────
# 3. Curated MoMA / Whitney / Other Masterpieces
#    (These museums lack public image APIs, so we use 
#     Wikipedia/Wikimedia Commons public domain images)
# ─────────────────────────────────────────────
def get_curated_masterpieces():
    print("\n═══ CURATED MASTERPIECES (MoMA/Whitney/Major Works) ═══")
    
    curated = [
        {
            "title": "The Starry Night",
            "artist": "Vincent van Gogh",
            "artist_bio": "Dutch, 1853–1890",
            "nationality": "Dutch",
            "date": "1889",
            "style": "Post-Impressionism",
            "medium": "Oil on canvas",
            "dimensions": "73.7 × 92.1 cm",
            "location": "Museum of Modern Art (MoMA), New York",
            "image_url": "https://upload.wikimedia.org/wikipedia/commons/thumb/e/ea/Van_Gogh_-_Starry_Night_-_Google_Art_Project.jpg/1280px-Van_Gogh_-_Starry_Night_-_Google_Art_Project.jpg",
            "info": "JEOPARDY KEY: One of the most recognized paintings in Western art. Painted from memory during the day from his asylum room at Saint-Rémy-de-Provence. The swirling night sky dominates — look for the cypress tree in the foreground and the small village below. Van Gogh's thick, expressive brushstrokes (impasto) are a signature tell. He painted this during a period of intense mental anguish, yet considered it a 'failure.' It was sold for 1,000 francs shortly after his death. Now at MoMA.",
            "source": "MoMA"
        },
        {
            "title": "Les Demoiselles d'Avignon",
            "artist": "Pablo Picasso",
            "artist_bio": "Spanish, 1881–1973",
            "nationality": "Spanish",
            "date": "1907",
            "style": "Proto-Cubism",
            "medium": "Oil on canvas",
            "dimensions": "243.9 × 233.7 cm",
            "location": "Museum of Modern Art (MoMA), New York",
            "image_url": "https://upload.wikimedia.org/wikipedia/en/4/4c/Les_Demoiselles_d%27Avignon.jpg",
            "info": "JEOPARDY KEY: Revolutionary proto-Cubist work showing five nude women composed of flat, angular planes. The two figures on the right have African mask-like faces — Picasso was influenced by Iberian sculpture and African art. This painting shocked even Picasso's closest friends. Matisse considered it an 'outrage.' It broke from traditional European painting perspective and is considered a pivotal work leading to Cubism.",
            "source": "MoMA"
        },
        {
            "title": "Christina's World",
            "artist": "Andrew Wyeth",
            "artist_bio": "American, 1917–2009",
            "nationality": "American",
            "date": "1948",
            "style": "Realism / Regionalism",
            "medium": "Tempera on panel",
            "dimensions": "81.9 × 121.3 cm",
            "location": "Museum of Modern Art (MoMA), New York",
            "image_url": "https://upload.wikimedia.org/wikipedia/en/a/a2/Christina%27s_World.jpg",
            "info": "JEOPARDY KEY: Shows a woman (Christina Olson, who had a degenerative muscular disorder) crawling across a brown field toward a gray farmhouse. Wyeth's neighbor in Cushing, Maine. Painted in egg tempera, not oil — a tell for Wyeth. The vast emptiness between figure and house creates psychological tension. One of the best-known American paintings of the 20th century.",
            "source": "MoMA"
        },
        {
            "title": "Dempsey and Firpo",
            "artist": "George Bellows",
            "artist_bio": "American, 1882–1925",
            "nationality": "American",
            "date": "1924",
            "style": "Ashcan School",
            "medium": "Oil on canvas",
            "dimensions": "129.5 × 160.6 cm",
            "location": "Whitney Museum of American Art, New York",
            "image_url": "https://upload.wikimedia.org/wikipedia/commons/7/71/Bellows_George_Dempsey_and_Firpo_1924.jpg",
            "info": "JEOPARDY KEY: Captures the famous moment when Argentine boxer Luis Ángel Firpo knocked Jack Dempsey out of the ring during their 1923 heavyweight title fight. Bellows was a leader of the Ashcan School — known for gritty, urban American realism. His boxing paintings are his most famous works. Dramatic diagonal composition and dynamic figures are Bellows tells.",
            "source": "Whitney"
        },
        {
            "title": "Girl with a Pearl Earring",
            "artist": "Johannes Vermeer",
            "artist_bio": "Dutch, 1632–1675",
            "nationality": "Dutch",
            "date": "c. 1665",
            "style": "Dutch Golden Age / Baroque",
            "medium": "Oil on canvas",
            "dimensions": "44.5 × 39 cm",
            "location": "Mauritshuis, The Hague, Netherlands",
            "image_url": "https://upload.wikimedia.org/wikipedia/commons/thumb/0/0f/1665_Girl_with_a_Pearl_Earring.jpg/800px-1665_Girl_with_a_Pearl_Earring.jpg",
            "info": "JEOPARDY KEY: Called the 'Mona Lisa of the North.' A tronie (character study), not a portrait of a specific person. The luminous pearl earring is the focal point. Vermeer's signature tells: exquisite light rendering, ultramarine blue (ground from expensive lapis lazuli), and intimate domestic scale. Only ~34 verified Vermeer paintings exist. The turban suggests exotic/Oriental influence popular in 17th-century Dutch painting.",
            "source": "Mauritshuis"
        },
        {
            "title": "The Night Watch",
            "artist": "Rembrandt van Rijn",
            "artist_bio": "Dutch, 1606–1669",
            "nationality": "Dutch",
            "date": "1642",
            "style": "Dutch Golden Age / Baroque",
            "medium": "Oil on canvas",
            "dimensions": "363 × 437 cm",
            "location": "Rijksmuseum, Amsterdam, Netherlands",
            "image_url": "https://upload.wikimedia.org/wikipedia/commons/thumb/5/5a/The_Night_Watch_-_HD.jpg/1280px-The_Night_Watch_-_HD.jpg",
            "info": "JEOPARDY KEY: Actually titled 'Militia Company of District II under Captain Frans Banninck Cocq.' It's NOT a night scene — centuries of varnish darkened it. Largest Rembrandt painting. Shows a militia company in dramatic motion rather than the standard static group portrait. Rembrandt tells: dramatic chiaroscuro (extreme light/dark contrast), rich impasto, psychological depth in faces. It was trimmed on all sides when moved in 1715.",
            "source": "Rijksmuseum"
        },
        {
            "title": "The Birth of Venus",
            "artist": "Sandro Botticelli",
            "artist_bio": "Italian, 1445–1510",
            "nationality": "Italian",
            "date": "c. 1485",
            "style": "Early Renaissance",
            "medium": "Tempera on canvas",
            "dimensions": "172.5 × 278.9 cm",
            "location": "Uffizi Gallery, Florence, Italy",
            "image_url": "https://upload.wikimedia.org/wikipedia/commons/thumb/0/0b/Sandro_Botticelli_-_La_nascita_di_Venere_-_Google_Art_Project_-_edited.jpg/1280px-Sandro_Botticelli_-_La_nascita_di_Venere_-_Google_Art_Project_-_edited.jpg",
            "info": "JEOPARDY KEY: Venus emerges from the sea as a full-grown woman on a giant scallop shell. Botticelli tells: elongated figures, flowing golden hair, delicate linear style, mythological subjects. Commissioned by the Medici family. One of the first large-scale Renaissance paintings on canvas (not wood panel). The figure of Venus is based on the ancient Venus de' Medici sculpture. Painted with tempera, not oil.",
            "source": "Uffizi"
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
            "location": "Louvre Museum, Paris, France",
            "image_url": "https://upload.wikimedia.org/wikipedia/commons/thumb/5/5d/Eug%C3%A8ne_Delacroix_-_Le_28_Juillet._La_Libert%C3%A9_guidant_le_peuple.jpg/1280px-Eug%C3%A8ne_Delacroix_-_Le_28_Juillet._La_Libert%C3%A9_guidant_le_peuple.jpg",
            "info": "JEOPARDY KEY: Commemorates the July Revolution of 1830 that toppled King Charles X. The bare-breasted woman is Marianne — allegorical figure of the French Republic and Liberty. She holds the tricolore flag. Delacroix tells: vivid dramatic color, energetic brushwork, Romantic emphasis on emotion over reason. Delacroix included himself in the painting (man in top hat with rifle). Inspired the Statue of Liberty's design.",
            "source": "Louvre"
        },
        {
            "title": "The Great Wave off Kanagawa",
            "artist": "Katsushika Hokusai",
            "artist_bio": "Japanese, 1760–1849",
            "nationality": "Japanese",
            "date": "c. 1831",
            "style": "Ukiyo-e",
            "medium": "Woodblock print (nishiki-e); ink and color on paper",
            "dimensions": "25.7 × 37.9 cm",
            "location": "Metropolitan Museum of Art, New York (and others)",
            "image_url": "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a5/Tsunami_by_hokusai_19th_century.jpg/1280px-Tsunami_by_hokusai_19th_century.jpg",
            "info": "JEOPARDY KEY: Part of 'Thirty-six Views of Mount Fuji' series. Mt. Fuji appears tiny in the background — the wave dominates. NOT a painting but a woodblock print. Hokusai was ~70 when he made this. Used Prussian blue pigment (recently imported from Europe). Three boats with fishermen are caught in the waves. One of the most reproduced images in art history. Influenced Western Impressionists including Monet and Van Gogh.",
            "source": "Multiple collections"
        },
        {
            "title": "Wanderer above the Sea of Fog",
            "artist": "Caspar David Friedrich",
            "artist_bio": "German, 1774–1840",
            "nationality": "German",
            "date": "c. 1818",
            "style": "Romanticism",
            "medium": "Oil on canvas",
            "dimensions": "94.8 × 74.8 cm",
            "location": "Hamburger Kunsthalle, Hamburg, Germany",
            "image_url": "https://upload.wikimedia.org/wikipedia/commons/thumb/b/b9/Caspar_David_Friedrich_-_Wanderer_above_the_sea_of_fog.jpg/800px-Caspar_David_Friedrich_-_Wanderer_above_the_sea_of_fog.jpg",
            "info": "JEOPARDY KEY: Iconic image of Romanticism. A man in a dark frock coat stands on a rocky precipice, back to viewer, gazing over a sea of fog. Friedrich tells: Rückenfigur (figure seen from behind, inviting viewer to share their perspective), sublime landscapes, tiny humans dwarfed by nature. Friedrich was the leading German Romantic painter. This painting epitomizes the Romantic concept of the Sublime — nature's overwhelming, awe-inspiring power.",
            "source": "Hamburger Kunsthalle"
        },
        {
            "title": "A Bar at the Folies-Bergère",
            "artist": "Édouard Manet",
            "artist_bio": "French, 1832–1883",
            "nationality": "French",
            "date": "1882",
            "style": "Impressionism / Realism",
            "medium": "Oil on canvas",
            "dimensions": "96 × 130 cm",
            "location": "Courtauld Gallery, London, UK",
            "image_url": "https://upload.wikimedia.org/wikipedia/commons/thumb/0/0d/Edouard_Manet%2C_A_Bar_at_the_Folies-Berg%C3%A8re.jpg/1280px-Edouard_Manet%2C_A_Bar_at_the_Folies-Berg%C3%A8re.jpg",
            "info": "JEOPARDY KEY: Manet's last major work before his death. A barmaid stands behind a marble counter; behind her, a mirror reflects the crowded concert hall. The mirror reflection is deliberately 'wrong' — the reflection doesn't align with the viewer's perspective. Manet tells: bold brushstrokes, flat areas of color, modern Parisian subjects, dark outlines. He bridged Realism and Impressionism. Notice the still life of bottles, oranges, and flowers on the counter.",
            "source": "Courtauld Gallery"
        },
        {
            "title": "Watson and the Shark",
            "artist": "John Singleton Copley",
            "artist_bio": "American, 1738–1815",
            "nationality": "American",
            "date": "1778",
            "style": "Romanticism / History painting",
            "medium": "Oil on canvas",
            "dimensions": "182.1 × 229.7 cm",
            "location": "National Gallery of Art, Washington, D.C.",
            "image_url": "https://upload.wikimedia.org/wikipedia/commons/thumb/7/71/Watson_and_the_Shark_%281778%29.jpg/1280px-Watson_and_the_Shark_%281778%29.jpg",
            "info": "JEOPARDY KEY: Depicts the real rescue of Brook Watson from a shark attack in Havana Harbor in 1749. Watson later became Lord Mayor of London. Copley was the first major American painter — self-taught in Boston. This was his first history painting after moving to London. The Black figure at the top of the rescue composition is one of the most prominent and dignified depictions of a Black person in 18th-century Western art.",
            "source": "National Gallery of Art"
        },
    ]
    
    for p in curated:
        print(f"  ✓ {p['title']} — {p['artist']}")
    
    print(f"  Total curated: {len(curated)}")
    return curated


# ─────────────────────────────────────────────
# Helper: Build Jeopardy-optimized info blurb
# ─────────────────────────────────────────────
def build_jeopardy_blurb(title, artist, bio, date, medium, loc, style, culture):
    parts = []
    parts.append(f"JEOPARDY KEY: \"{title}\" by {artist}.")
    if bio:
        parts.append(f"Artist: {bio}.")
    if date:
        parts.append(f"Date: {date}.")
    if medium:
        parts.append(f"Medium: {medium}.")
    if style:
        parts.append(f"Style/Period: {style}.")
    if culture:
        parts.append(f"Cultural origin: {culture}.")
    if loc:
        parts.append(f"Currently housed at: {loc}.")
    return " ".join(parts)


# ─────────────────────────────────────────────
# Database insertion
# ─────────────────────────────────────────────
def seed_database(all_paintings):
    print(f"\n═══ DATABASE SEEDING ═══")
    try:
        conn = psycopg2.connect(DB_DSN)
        cur = conn.cursor()
    except Exception as e:
        print(f"  ✗ Failed to connect: {e}")
        sys.exit(1)

    # Deduplicate by title+artist
    seen = set()
    unique = []
    for p in all_paintings:
        key = (p["title"].lower().strip(), p["artist"].lower().strip())
        if key not in seen:
            seen.add(key)
            unique.append(p)
    
    print(f"  {len(unique)} unique paintings to insert (deduplicated from {len(all_paintings)})...")
    
    inserted = 0
    skipped = 0
    
    for p in unique:
        # Check if photo already exists
        cur.execute("SELECT id FROM photos WHERE name = %s", (p['title'],))
        if cur.fetchone():
            skipped += 1
            continue
        
        # Upsert author
        artist_name = p['artist'].split("(")[0].strip()  # Clean "Artist (Full Name)"
        cur.execute("SELECT id FROM authors WHERE name = %s", (artist_name,))
        author_row = cur.fetchone()
        
        if author_row:
            author_id = author_row[0]
        else:
            author_id = str(uuid.uuid4())
            now = datetime.datetime.now()
            cur.execute(
                """INSERT INTO authors (id, created_at, updated_at, name, born, died, nationality, wikipedia, original_source)
                   VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)""",
                (author_id, now, now, artist_name, p.get('artist_bio', ''), '', 
                 p.get('nationality', ''), '', p.get('source', ''))
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
             p['medium'], p.get('source', ''), False)
        )
        inserted += 1
    
    conn.commit()
    cur.close()
    conn.close()
    print(f"  ✓ Inserted: {inserted}  |  Skipped (duplicates): {skipped}")
    print(f"  ✓ Database seeded successfully!")


# ─────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────
if __name__ == "__main__":
    all_paintings = []
    
    # 1. Metropolitan Museum of Art
    all_paintings.extend(fetch_met_art())
    
    # 2. Art Institute of Chicago
    all_paintings.extend(fetch_aic_art())
    
    # 3. Curated masterpieces (MoMA, Whitney, other major museums)
    all_paintings.extend(get_curated_masterpieces())
    
    print(f"\n═══ SUMMARY ═══")
    print(f"Total paintings collected: {len(all_paintings)}")
    
    if all_paintings:
        seed_database(all_paintings)
    else:
        print("No paintings to insert.")
