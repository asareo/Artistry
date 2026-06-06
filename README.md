# Artistry — Native macOS Masterpiece Engine

Artistry is a native macOS menu bar application that delivers an educational art experience directly to your desktop. It transforms your wallpaper into a rotating gallery of world-class masterpieces while providing historical context through an unobtrusive overlay.

---

## Features
- **Curated Masterpieces**: 1,000+ high-resolution paintings from the Met Museum, Art Institute of Chicago, and WikiArt.
- **No Local Server Required**: Connected directly to the cloud-hosted backend on Render and a remote Supabase database.
- **Educational Overlays**: Learn the "tells" of famous artists and historical trivia.
- **Art Quiz**: Test your knowledge with Kahoot-style quizzes based on your recently seen art.
- **Masterpiece Gallery**: Save your favorite paintings and view them in a dedicated grid.
- **Smart Wallpaper Scaling**: Automatically chooses between "Fill" and "Fit" based on the artwork's aspect ratio.
- **Check for Updates**: Easily check for and download the latest compiled builds directly from the app.

---

## Architecture & Deployment

The application is split into two parts:
1. **Client**: A native Swift macOS menu bar app (`Artistry`).
2. **Backend**: A Go-based API (`artify-core`) hosted on **Render** (`https://artistry-wsnw.onrender.com`) and connected to a **Supabase PostgreSQL** cloud database.

### Seeding & Discovering Art
Whenever a user inputs a query in the "Discover & Add New Art" field:
1. The client requests the backend API `/api/discover?q=...`.
2. The backend queries WikiArt and Met Museum APIs, scrapes metadata, and seeds the new masterpieces into the Supabase database.
3. Because the database is shared globally, newly seeded art becomes instantly available to all active clients.

---

## Building the App

To compile the native macOS application:

```bash
swiftc -O ArtifyV2/Sources/main.swift -o Artistry.app/Contents/MacOS/Artistry
```

Once compiled, you can run `Artistry.app` or zip it to share it with friends.

---

## For Partners & Testers

### "Do I need Docker?"
**No.** Docker is no longer required to run the app. It communicates with the live Render cloud backend automatically. You can open `Artistry.app` and it will work immediately out of the box.

### "How do updates work?"
If Swift code changes are made (like UI updates), click the **Check for Updates...** button under the gear settings icon `⚙️` in the popover. It queries the backend to check if a newer client binary has been published.

---

## Credits
- **Developer**: Owuraku
- **Assistant**: Antigravity (Google DeepMind)
- **Data Sources**: The Metropolitan Museum of Art, Art Institute of Chicago, WikiArt, Wikimedia Commons.
