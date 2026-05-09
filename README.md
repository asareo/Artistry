# ArtifyV2 — Native macOS Masterpiece Engine
ArtifyV2 is a native macOS menu bar application that delivers an educational art experience directly to your desktop. It transforms your wallpaper into a rotating gallery of world-class masterpieces while providing historical context through an unobtrusive overlay.
## Features
- **Curated Masterpieces**: 1,000+ high-resolution paintings from the Met, Art Institute of Chicago, and WikiArt.
- **Educational Overlays**: Learn the "tells" of famous artists and historical trivia.
- **Art Quiz**: Test your knowledge with Kahoot-style quizzes based on your recently seen art.
- **Masterpiece Gallery**: Save your favorite paintings and view them in a dedicated grid.
- **Smart Wallpaper Scaling**: Automatically chooses between "Fill" and "Fit" based on the artwork's aspect ratio.
---
## Developer Requirements (Running from Source)
Because ArtifyV2 relies on a local art metadata engine, you must have the **Docker backend** running to fetch new art.
### 1. Prerequisites
- **Xcode 14+** (for the macOS app)
- **Docker Desktop** (for the art database and API)
- **Python 3** (optional, for seeding more art)
### 2. Setting Up the Backend
The app communicates with a Go-based API and a PostgreSQL database hosted in Docker.
1. Navigate to the `artify-core` directory.
2. Start the services:
   ```bash
   docker-compose up -d
   ```
3. (Optional) If the database is empty, seed it with art:
   ```bash
   python3 scripts/seed_met_art.py
   ```
### 3. Building the App
1. Open the project in Xcode or build via terminal using the provided `swiftc` command.
2. Ensure the `ArtifyV2` process can communicate with `http://localhost:7300`.
---
## For Partners & Testers
### "Do I need Docker?"
**Yes.** Currently, the app is a "thick client" that requires the local `artify-core` backend to be active. If Docker is not running, the app will rely solely on its local image cache (if any) and will not be able to discover new masterpieces.
### Packaging for Release
To package ArtifyV2 as a standalone `.app`:
1. Select "Any Mac (Apple Silicon, Intel)" in Xcode.
2. Go to **Product > Archive**.
3. Once archived, select **Distribute App > Copy App**.
*Note: Future versions may include a cloud-hosted backend to remove the Docker requirement for end-users.*
---
## Credits
- **Developer**: Owuraku
- **Assistant**: Antigravity (Google DeepMind)
- **Data Sources**: The Metropolitan Museum of Art, Art Institute of Chicago, WikiArt, Wikimedia Commons.
