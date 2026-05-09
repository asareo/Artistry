// ArtifyV2 — Modern macOS Wallpaper App
// v2.3: Kahoot quiz, draggable overlay, artist portraits, About panel.

import AppKit
import SwiftUI

// ─────────────────────────────────────────────
// MARK: - Data Models
// ─────────────────────────────────────────────

struct Author: Codable {
    let id: String
    let name: String
    let born: String?
    let died: String?
    let nationality: String?
}

struct Photo: Codable, Equatable {
    let id: String
    let name: String
    let image_url: String
    let author: Author
    let info: String?
    let date: String?
    let style: String?
    let location: String?
    let dimensions: String?
    let media: String?
    let is_favorite: Bool?

    static func == (lhs: Photo, rhs: Photo) -> Bool {
        lhs.id == rhs.id
    }
}

struct APIResponse: Codable {
    let code: Int
    let message: String
    let data: Photo?
}

// ─────────────────────────────────────────────
// MARK: - Image Cache Manager
// ─────────────────────────────────────────────

class ArtifyCacheManager {
    static let shared = ArtifyCacheManager()

    private let cacheDir: URL
    private let maxCached = 300
    private let maxCacheBytes: Int64 = 500 * 1024 * 1024  // 500 MB
    private(set) var cachedWallpapers: [URL] = []

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = base.appendingPathComponent("ArtifyV2", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        loadExistingCache()
    }

    /// Scans the cache directory and populates the in-memory list
    private func loadExistingCache() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        // Sort by creation date — oldest first so we can evict
        cachedWallpapers = files
            .filter { $0.pathExtension == "jpg" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da < db
            }
    }

    /// Saves a downloaded temp file into the persistent cache.
    /// Evicts oldest files when count > 300 or total size > 500 MB.
    func save(tempURL: URL, photoID: String) -> URL? {
        let destURL = cacheDir.appendingPathComponent("\(photoID).jpg")
        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: tempURL, to: destURL)
            if !cachedWallpapers.contains(destURL) {
                cachedWallpapers.append(destURL)
            }
            // Evict oldest until we're within both limits
            evictIfNeeded()
            return destURL
        } catch {
            return nil
        }
    }

    private func evictIfNeeded() {
        while cachedWallpapers.count > maxCached {
            evictOldest()
        }
        while totalCacheBytes() > maxCacheBytes, !cachedWallpapers.isEmpty {
            evictOldest()
        }
    }

    private func evictOldest() {
        guard let oldest = cachedWallpapers.first else { return }
        try? FileManager.default.removeItem(at: oldest)
        cachedWallpapers.removeFirst()
    }

    private func totalCacheBytes() -> Int64 {
        cachedWallpapers.reduce(Int64(0)) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
            return sum + size
        }
    }

    /// Returns a random cached wallpaper, preferring not the currently displayed one
    func randomCached(excluding currentURL: URL? = nil) -> URL? {
        let candidates = cachedWallpapers.filter { $0 != currentURL }
        return candidates.randomElement() ?? cachedWallpapers.randomElement()
    }

    var hasCache: Bool { !cachedWallpapers.isEmpty }
}

// ─────────────────────────────────────────────
// MARK: - Artist Portrait Cache
// ─────────────────────────────────────────────

class ArtistPortraitCache {
    static let shared = ArtistPortraitCache()
    private let portraitDir: URL
    // In-memory map: sanitized artist name → [local file URLs]
    private var cache: [String: [URL]] = [:]

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        portraitDir = base.appendingPathComponent("ArtifyV2/portraits", isDirectory: true)
        try? FileManager.default.createDirectory(at: portraitDir, withIntermediateDirectories: true)
        loadExisting()
    }

    private func sanitize(_ name: String) -> String {
        name.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
    }

    private func loadExisting() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: portraitDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        for url in files where url.pathExtension == "jpg" {
            // Filename pattern: <sanitizedName>_<index>.jpg
            let base = url.deletingPathExtension().lastPathComponent
            let parts = base.split(separator: "_", maxSplits: 1).map(String.init)
            let key = parts.first ?? base
            cache[key, default: []].append(url)
        }
    }

    /// Returns cached portrait URLs for an artist, or empty if not yet fetched.
    func portraits(for artist: String) -> [URL] {
        cache[sanitize(artist)] ?? []
    }

    /// Total number of cached portrait files
    var totalCount: Int { cache.values.reduce(0) { $0 + $1.count } }

    /// Fetches and caches the artist portrait from Wikipedia if not already stored.
    func fetchIfNeeded(for artist: String, completion: @escaping ([URL]) -> Void) {
        let key = sanitize(artist)
        if let cached = cache[key], !cached.isEmpty {
            completion(cached); return
        }
        // Wikipedia REST summary API — returns infobox thumbnail
        let encoded = artist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? artist
        guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)") else {
            completion([]); return
        }
        var req = URLRequest(url: url)
        req.setValue("ArtifyV2/1.0 (educational art app)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let thumb = json["thumbnail"] as? [String: Any],
                  let imgStr = thumb["source"] as? String,
                  let imgURL = URL(string: imgStr) else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            // Download portrait
            URLSession.shared.downloadTask(with: imgURL) { tmpURL, _, _ in
                guard let tmpURL = tmpURL else {
                    DispatchQueue.main.async { completion([]) }
                    return
                }
                let dest = self.portraitDir.appendingPathComponent("\(key)_0.jpg")
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: tmpURL, to: dest)
                DispatchQueue.main.async {
                    self.cache[key] = [dest]
                    completion([dest])
                }
            }.resume()
        }.resume()
    }
}

// ─────────────────────────────────────────────
// MARK: - App State
// ─────────────────────────────────────────────

class ArtifyState: ObservableObject {
    static let shared = ArtifyState()

    @Published var currentPhoto: Photo?
    @Published var isLoading = false
    @Published var lastError: String?
    @Published var shuffleInterval: TimeInterval = 0 // 0 = off
    @Published var overlayVisible = true
    @Published var quizReady = false   // true = menu bar shows "Quiz Ready" button

    // Ring buffer of the last 10 successfully shown photos (for quiz)
    private(set) var recentlyShownPhotos: [Photo] = []
    private var photosUntilQuiz: Int = Int.random(in: 5...8)

    private var shuffleTimer: Timer?
    private var lastPhotoID: String?
    private var currentWallpaperURL: URL?
    private var fetchRetryCount = 0
    private var downloadFailCount = 0   // separate counter for image-level failures
    private let maxFetchRetries = 5    // max times to retry same-ID API response
    private let maxDownloadRetries = 8  // max image download failures before giving up
    private let downloadTimeoutSeconds: TimeInterval = 20  // generous for large art images

    let apiBase = "http://localhost:7300/api"

    // Custom URLSession with tight timeout
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    func fetchRandom(isRetry: Bool = false) {
        // Reset retry counter on fresh user-initiated fetch
        if !isRetry {
            fetchRetryCount = 0
        }

        // If already loading and this isn't a retry, ignore
        if isLoading && !isRetry { return }

        isLoading = true
        lastError = nil

        guard let url = URL(string: "\(apiBase)/feature/random") else {
            lastError = "Invalid URL"
            isLoading = false
            return
        }

        session.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error {
                    self.lastError = "Network: \(error.localizedDescription)"
                    self.isLoading = false
                    // Fall back to cache if we have one
                    self.applyFallbackIfAvailable()
                    return
                }

                guard let data = data else {
                    self.lastError = "No data received"
                    self.isLoading = false
                    self.applyFallbackIfAvailable()
                    return
                }

                do {
                    let apiResp = try JSONDecoder().decode(APIResponse.self, from: data)
                    if let photo = apiResp.data {
                        // If we got the same photo as last time, retry up to maxRetries
                        if photo.id == self.lastPhotoID && self.fetchRetryCount < self.maxFetchRetries {
                            self.fetchRetryCount += 1
                            self.isLoading = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                self.fetchRandom(isRetry: true)
                            }
                            return
                        }
                        self.fetchRetryCount = 0
                        self.lastPhotoID = photo.id
                        self.currentPhoto = photo
                        self.setWallpaper(from: photo.image_url, photoID: photo.id)
                    } else {
                        self.lastError = "No photo in response"
                        self.isLoading = false
                    }
                } catch {
                    self.lastError = "Parse error: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }.resume()
    }

    func setWallpaper(from urlString: String, photoID: String) {
        guard let imageURL = URL(string: urlString) else {
            isLoading = false
            retryWithNewPhoto()
            return
        }

        // Serve instantly from local cache if we already downloaded this painting
        let cachedFile = ArtifyCacheManager.shared.cachedWallpapers
            .first { $0.lastPathComponent == "\(photoID).jpg" }
        if let existing = cachedFile {
            downloadFailCount = 0  // success path resets failure counter
            applyWallpaper(localURL: existing)
            isLoading = false
            return
        }

        // Timeout guard — both paths always touch `completed` on the main queue only
        var completed = false

        DispatchQueue.main.asyncAfter(deadline: .now() + downloadTimeoutSeconds) { [weak self] in
            guard let self = self, !completed else { return }
            completed = true
            self.isLoading = false
            // Timeout = try a different photo, don't give up
            self.retryWithNewPhoto()
        }

        // Build a request with a browser User-Agent — some CDNs block default URLSession UA
        var request = URLRequest(url: imageURL)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = downloadTimeoutSeconds

        session.downloadTask(with: request) { [weak self] localURL, response, error in
            guard let self = self else { return }

            // Check HTTP status — treat 4xx as a failure worth retrying with a new photo
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 200
            let downloadOK = localURL != nil && error == nil && httpStatus < 400

            // CRITICAL: copy temp file on background thread BEFORE dispatching to main.
            // URLSession deletes the temp file when this handler returns.
            var stableURL: URL? = nil
            if downloadOK, let tmpURL = localURL {
                stableURL = ArtifyCacheManager.shared.save(tempURL: tmpURL, photoID: photoID)
                if stableURL == nil {
                    let fallbackTmp = FileManager.default.temporaryDirectory
                        .appendingPathComponent("artify_\(photoID).jpg")
                    try? FileManager.default.removeItem(at: fallbackTmp)
                    if (try? FileManager.default.copyItem(at: tmpURL, to: fallbackTmp)) != nil {
                        stableURL = fallbackTmp
                    }
                }
            }

            DispatchQueue.main.async {
                guard !completed else { return }
                completed = true
                self.isLoading = false

                if let url = stableURL {
                    self.downloadFailCount = 0  // reset on success
                    self.applyWallpaper(localURL: url)
                } else {
                    // HTTP error (403/404) or network failure — try a different photo
                    let code = httpStatus
                    self.lastError = code >= 400 ? "Image unavailable (\(code)) — trying another…" : "Download failed — trying another…"
                    self.retryWithNewPhoto()
                }
            }
        }.resume()
    }

    private func applyFallbackIfAvailable() {
        // Only use cached fallback as a last resort (all retries exhausted)
        guard ArtifyCacheManager.shared.hasCache,
              let fallback = ArtifyCacheManager.shared.randomCached(excluding: currentWallpaperURL) else {
            lastError = "No cached art available"
            return
        }
        applyWallpaper(localURL: fallback)
    }

    // Called when an image download fails (403, 404, timeout, etc.)
    // Automatically fetches a fresh random photo instead of stalling.
    private func retryWithNewPhoto() {
        downloadFailCount += 1
        if downloadFailCount > maxDownloadRetries {
            // Truly stuck — show cached art and reset
            downloadFailCount = 0
            lastError = "Several images unavailable — showing cached art"
            applyFallbackIfAvailable()
            return
        }
        // Kick off a fresh API request immediately
        lastError = nil
        isLoading = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.fetchRandom(isRetry: true)
        }
    }

    private func applyWallpaper(localURL: URL) {
        currentWallpaperURL = localURL

        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
            .allowClipping: NSNumber(value: true)
        ]
        for screen in NSScreen.screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(localURL, for: screen, options: options)
            } catch {
                self.lastError = "Wallpaper error: \(error.localizedDescription)"
            }
        }

        // Track this photo in the quiz-history ring buffer
        if let photo = currentPhoto {
            if !recentlyShownPhotos.contains(photo) {
                recentlyShownPhotos.append(photo)
                if recentlyShownPhotos.count > 10 { recentlyShownPhotos.removeFirst() }
            }
            // Pre-fetch artist portrait in background so it's ready during quiz
            ArtistPortraitCache.shared.fetchIfNeeded(for: photo.author.name) { _ in }

            // Tick quiz countdown
            photosUntilQuiz -= 1
            if photosUntilQuiz <= 0 && recentlyShownPhotos.count >= 5 && !quizReady {
                quizReady = true
                NotificationCenter.default.post(
                    name: NSNotification.Name("ArtifyQuizReady"), object: nil)
            }
        }

        OverlayWindowController.shared.update()
    }

    /// Called by the quiz when the user dismisses it.
    func resumeAfterQuiz() {
        quizReady = false
        photosUntilQuiz = Int.random(in: 5...8)
        // Restart shuffle timer if it was running
        if shuffleInterval > 0 { setShuffleInterval(shuffleInterval) }
    }

    func setShuffleInterval(_ interval: TimeInterval) {
        shuffleInterval = interval
        shuffleTimer?.invalidate()
        shuffleTimer = nil
        guard interval > 0 else { return }
        shuffleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            // Don't auto-shuffle while quiz is active
            guard self?.quizReady == false else { return }
            self?.fetchRandom()
        }
    }

    func toggleOverlay() {
        overlayVisible.toggle()
        if overlayVisible {
            OverlayWindowController.shared.show()
        } else {
            OverlayWindowController.shared.hide()
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Draggable Window
// ─────────────────────────────────────────────
// NSHostingView (SwiftUI container) absorbs mouse events, so
// isMovableByWindowBackground never fires. We fix this by overriding
// sendEvent in NSWindow: when the user drags after a small threshold
// we move the window directly, bypassing SwiftUI's event handling.

class DraggableWindow: NSWindow {
    private var dragStart: NSPoint?
    private var dragging = false

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragStart = NSEvent.mouseLocation
            dragging = false
            super.sendEvent(event)
        case .leftMouseDragged:
            if let start = dragStart {
                let cur = NSEvent.mouseLocation
                let dx = cur.x - start.x, dy = cur.y - start.y
                if !dragging && (dx*dx + dy*dy) > 16 { dragging = true }
                if dragging {
                    setFrameOrigin(NSPoint(x: frame.origin.x + cur.x - start.x,
                                          y: frame.origin.y + cur.y - start.y))
                    dragStart = cur
                    return   // don't forward — we handled it
                }
            }
            super.sendEvent(event)
        case .leftMouseUp:
            dragStart = nil; dragging = false
            super.sendEvent(event)
        default:
            super.sendEvent(event)
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Overlay Window Controller
// ─────────────────────────────────────────────

class OverlayWindowController {
    static let shared = OverlayWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<OverlayView>?

    func show() {
        if window == nil {
            createWindow()
        }
        window?.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    func update() {
        // OverlayView uses @ObservedObject on ArtifyState.shared,
        // so it auto-updates when currentPhoto changes.
        // We intentionally do NOT replace rootView here —
        // doing so resets NSHostingView's internal event state
        // and breaks DraggableWindow's drag tracking.
    }

    private func createWindow() {
        guard let screen = NSScreen.main else { return }
        let _ = screen // used implicitly via NSScreen.main check

        let width: CGFloat = 400
        let height: CGFloat = 220
        let padding: CGFloat = 32

        let frame = NSRect(
            x: padding,
            y: padding,
            width: width,
            height: height
        )

        // DraggableWindow handles mouse drag directly — fixes SwiftUI event absorption
        let w = DraggableWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        // Desktop level: above wallpaper, below all app windows
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.ignoresMouseEvents = false  // DraggableWindow handles drag via sendEvent

        let overlayView = OverlayView()
        let hosting = NSHostingView(rootView: overlayView)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)

        w.contentView = hosting
        self.hostingView = hosting
        self.window = w
    }
}

// ─────────────────────────────────────────────
// MARK: - Overlay SwiftUI View
// ─────────────────────────────────────────────

struct OverlayView: View {
    @ObservedObject private var state = ArtifyState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let photo = state.currentPhoto {

                // Title
                Text(photo.name)
                    .font(.system(size: 17, weight: .bold, design: .serif))
                    .foregroundColor(.white)
                    .lineLimit(2)

                // Artist + date
                HStack(spacing: 6) {
                    Text(photo.author.name)
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .foregroundColor(Color(white: 0.85))
                    if let date = photo.date, !date.isEmpty {
                        Text("·")
                            .foregroundColor(Color(white: 0.5))
                        Text(date)
                            .font(.system(size: 12, weight: .regular, design: .serif))
                            .foregroundColor(Color(white: 0.7))
                    }
                }

                // Style / medium tags
                HStack(spacing: 8) {
                    if let style = photo.style, !style.isEmpty {
                        tagBadge(style)
                    }
                    if let media = photo.media, !media.isEmpty {
                        tagBadge(shortMedia(media))
                    }
                }

                Divider()
                    .background(Color.white.opacity(0.25))
                    .padding(.vertical, 2)

                // ── FIX 4: Art thought blurb instead of dimensions ────────────
                // Show first 2 sentences of the info field as a contemplative
                // thought piece. Falls back to a short artist bio if no info.
                let blurb = thoughtBlurb(photo: photo)
                if !blurb.isEmpty {
                    Text(blurb)
                        .font(.system(size: 11, weight: .light, design: .serif))
                        .foregroundColor(Color(white: 0.88))
                        .italic()
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

            } else if state.isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.7)
                    Text("Loading artwork…")
                        .font(.system(size: 13, design: .serif))
                        .foregroundColor(.white)
                }
            } else {
                Text("No artwork loaded")
                    .font(.system(size: 13, design: .serif))
                    .foregroundColor(.white)
                Text("Click 🎨 in the menu bar → Randomize")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.6))
            }
        }
        .padding(18)
        .frame(width: 400, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.58))
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.ultraThinMaterial)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
        )
        .shadow(color: .black.opacity(0.5), radius: 24, x: 0, y: 6)
    }

    // ── Thought blurb: strip the "JEOPARDY KEY:" prefix and take ~2 sentences ──
    private func thoughtBlurb(photo: Photo) -> String {
        if let info = photo.info, !info.isEmpty {
            var text = info
            // Strip the Jeopardy prefix if present
            if text.hasPrefix("JEOPARDY KEY:") {
                text = String(text.dropFirst("JEOPARDY KEY:".count)).trimmingCharacters(in: .whitespaces)
            }
            return firstTwoSentences(of: text, maxChars: 240)
        }
        // Fallback: synthesize from available metadata
        var parts: [String] = []
        parts.append("\(photo.author.name) — \(photo.name).")
        if let style = photo.style, !style.isEmpty { parts.append("A work of \(style).") }
        if let loc = photo.location, !loc.isEmpty { parts.append("Held at \(loc).") }
        return parts.joined(separator: " ")
    }

    private func firstTwoSentences(of text: String, maxChars: Int) -> String {
        // Split on sentence boundaries
        var sentences: [String] = []
        var current = ""
        for char in text {
            current.append(char)
            if char == "." || char == "!" || char == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
                if sentences.count == 2 { break }
            }
        }
        // If we didn't find 2 sentence endings, use what we have
        if sentences.isEmpty {
            return String(text.prefix(maxChars))
        }
        let joined = sentences.joined(separator: " ")
        if joined.count <= maxChars { return joined }
        return String(joined.prefix(maxChars)) + "…"
    }

    private func shortMedia(_ media: String) -> String {
        // Truncate long media strings like "Oil on canvas, laid down on panel"
        let parts = media.split(separator: ",")
        return String(parts.first ?? Substring(media)).trimmingCharacters(in: .whitespaces)
    }

    @ViewBuilder
    private func tagBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundColor(Color(white: 0.75))
            .tracking(0.8)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Color.white.opacity(0.12))
            )
    }
}

// ─────────────────────────────────────────────
// MARK: - Menu Bar Content View
// ─────────────────────────────────────────────

struct MenuBarContentView: View {
    @ObservedObject private var state = ArtifyState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Current painting info
            if let photo = state.currentPhoto {
                Text(photo.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("by \(photo.author.name)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Divider()
            }

            // Randomize button
            Button(state.isLoading ? "⏳  Loading…" : "🎲  Randomize") {
                ArtifyState.shared.fetchRandom()
            }
            .keyboardShortcut("r")
            .disabled(state.isLoading)

            Divider()

            // Quiz ready banner — launches the Kahoot-style art quiz
            if state.quizReady {
                Button("🧠  Art Quiz Ready! Start →") {
                    let photos = Array(ArtifyState.shared.recentlyShownPhotos.suffix(5))
                    QuizWindowController.shared.present(photos: photos)
                }
                .foregroundColor(.yellow)
                Divider()
            }

            // Shuffle interval
            Menu("⏱  Shuffle Interval") {
                Button(state.shuffleInterval == 0 ? "✓ Off" : "Off") {
                    state.setShuffleInterval(0)
                }
                Button(state.shuffleInterval == 30 ? "✓ 30 sec" : "30 sec") {
                    state.setShuffleInterval(30)
                }
                Button(state.shuffleInterval == 60 ? "✓ 1 min" : "1 min") {
                    state.setShuffleInterval(60)
                }
                Button(state.shuffleInterval == 300 ? "✓ 5 min" : "5 min") {
                    state.setShuffleInterval(300)
                }
                Button(state.shuffleInterval == 600 ? "✓ 10 min" : "10 min") {
                    state.setShuffleInterval(600)
                }
                Button(state.shuffleInterval == 1800 ? "✓ 30 min" : "30 min") {
                    state.setShuffleInterval(1800)
                }
            }

            // Toggle overlay
            Button(state.overlayVisible ? "🔲  Hide Info Overlay" : "🔲  Show Info Overlay") {
                state.toggleOverlay()
            }

            // About
            Menu("ℹ️  About") {
                Text("ArtifyV2 — v2.3")
                    .font(.caption)
                Text("Built by swift 🛠")
                    .font(.caption)
                Divider()
                let cacheCount = ArtifyCacheManager.shared.cachedWallpapers.count
                let portraitCount = ArtistPortraitCache.shared.totalCount
                Text("🖼  \(cacheCount) painting\(cacheCount == 1 ? "" : "s") cached")
                    .font(.caption)
                Text("👤  \(portraitCount) artist portrait\(portraitCount == 1 ? "" : "s") saved")
                    .font(.caption)
                Text("🧠  \(state.recentlyShownPhotos.count) paintings in quiz pool")
                    .font(.caption)
                Divider()
                Text("Desktop wallpaper engine powered")
                    .font(.caption)
                Text("by Met Museum & WikiArt")
                    .font(.caption)
            }

            Divider()

            // Error display
            if let error = state.lastError {
                Text("⚠️ \(error)")
                    .font(.caption)
                    .foregroundColor(.orange)
                Divider()
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(6)
        .frame(minWidth: 240)
    }
}

// ─────────────────────────────────────────────
// MARK: - Quiz Models
// ─────────────────────────────────────────────

enum QuestionType: CaseIterable {
    case artist, title, style
    var prompt: String {
        switch self {
        case .artist: return "Who painted this?"
        case .title:  return "What is this painting called?"
        case .style:  return "What artistic style is this?"
        }
    }
    var hasHint: Bool { self == .artist }
}

struct QuizQuestion {
    let photo: Photo
    let type: QuestionType
    let correctAnswer: String
    let options: [String]           // 4 items, shuffled
    let cachedImageURL: URL?
}

struct QuizAnswer {
    let question: QuizQuestion
    let chosen: String              // empty string = timed out
    var isCorrect: Bool { chosen == question.correctAnswer }
}

// ─────────────────────────────────────────────
// MARK: - Quiz State
// ─────────────────────────────────────────────

class QuizState: ObservableObject {
    static let shared = QuizState()

    @Published var isActive      = false
    @Published var quizComplete  = false
    @Published var qIndex        = 0
    @Published var questions: [QuizQuestion] = []
    @Published var answers:   [QuizAnswer]   = []
    @Published var chosen: String?           // nil = not answered yet
    @Published var showResult    = false     // brief flash after answer
    @Published var showHint      = false
    @Published var timeRemaining: Double = 15
    @Published var portraitURLs: [URL]   = []

    private var timer: Timer?
    private let questionTime: Double = 15

    var currentQ: QuizQuestion? {
        guard qIndex < questions.count else { return nil }
        return questions[qIndex]
    }
    var score: Int { answers.filter(\.isCorrect).count }

    // MARK: - Start / Flow

    func startQuiz(photos: [Photo]) {
        questions    = buildQuestions(from: photos)
        answers      = []
        qIndex       = 0
        chosen       = nil
        showResult   = false
        showHint     = false
        quizComplete = false
        isActive     = true
        loadPortraitsForCurrentQ()
        startTimer()
    }

    func select(_ answer: String) {
        guard chosen == nil, let q = currentQ else { return }
        chosen = answer
        timer?.invalidate()
        answers.append(QuizAnswer(question: q, chosen: answer))
        showResult = true
        advance(after: 1.8)
    }

    func endQuiz() {
        isActive = false
        timer?.invalidate()
        QuizWindowController.shared.hide()
        OverlayWindowController.shared.show()
        ArtifyState.shared.resumeAfterQuiz()
        NotificationCenter.default.post(name: NSNotification.Name("ArtifyQuizDone"), object: nil)
    }

    // MARK: - Internals

    private func advance(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.showResult = false
            self.showHint   = false
            self.chosen     = nil
            if self.qIndex + 1 >= self.questions.count {
                self.quizComplete = true
            } else {
                self.qIndex += 1
                self.timeRemaining = self.questionTime
                self.loadPortraitsForCurrentQ()
                self.startTimer()
            }
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.timeRemaining -= 0.05
            if self.timeRemaining <= 0 {
                self.timeRemaining = 0
                self.timer?.invalidate()
                // Timed out — record empty answer
                if let q = self.currentQ {
                    self.answers.append(QuizAnswer(question: q, chosen: ""))
                }
                self.showResult = true
                self.advance(after: 1.8)
            }
        }
    }

    private func loadPortraitsForCurrentQ() {
        portraitURLs = []
        guard let q = currentQ, q.type == .artist else { return }
        ArtistPortraitCache.shared.fetchIfNeeded(for: q.photo.author.name) { [weak self] urls in
            self?.portraitURLs = urls
        }
    }

    // MARK: - Question Builder

    private func buildQuestions(from photos: [Photo]) -> [QuizQuestion] {
        // Assign question types round-robin, then shuffle order
        let types: [QuestionType] = [.artist, .title, .style, .artist, .title]
        var questions: [QuizQuestion] = []

        for (i, photo) in photos.enumerated() {
            let qType = types[i % types.count]
            let correct: String
            var pool: [String]

            switch qType {
            case .artist:
                correct = photo.author.name
                pool = (photos.map { $0.author.name } + fallbackArtists).filter { $0 != correct }
            case .title:
                correct = photo.name
                pool = (photos.map { $0.name } + fallbackTitles).filter { $0 != correct }
            case .style:
                correct = photo.style ?? "Unknown"
                pool = (photos.compactMap { $0.style } + fallbackStyles).filter { $0 != correct }
            }

            let poolArr: [String] = Array(Set(pool))
            var wrongs = poolArr.shuffled().prefix(3).map { String($0) }
            while wrongs.count < 3 { wrongs.append("Unknown") }

            var opts = ([correct] + wrongs).shuffled()
            let cachedURL = ArtifyCacheManager.shared.cachedWallpapers
                .first { $0.lastPathComponent == "\(photo.id).jpg" }

            questions.append(QuizQuestion(photo: photo, type: qType, correctAnswer: correct,
                                          options: opts, cachedImageURL: cachedURL))
        }
        return questions.shuffled()
    }

    // Fallback wrong-answer pools
    private let fallbackArtists = [
        "Claude Monet","Pablo Picasso","Leonardo da Vinci","Michelangelo","Raphael",
        "Pierre-Auguste Renoir","Paul Cézanne","Paul Gauguin","Francisco Goya",
        "J.M.W. Turner","John Constable","Thomas Gainsborough","Benjamin West"
    ]
    private let fallbackStyles = [
        "Impressionism","Baroque","Romanticism","Realism","Renaissance",
        "Post-Impressionism","Dutch Golden Age","Ukiyo-e","Rococo","Neoclassicism",
        "Mannerism","Expressionism","Symbolism","Naturalism"
    ]
    private let fallbackTitles = [
        "The Starry Night","Girl with a Pearl Earring","The Night Watch",
        "The Birth of Venus","Liberty Leading the People","The Great Wave",
        "Wanderer above the Sea of Fog","Water Lilies","The Scream","Guernica"
    ]
}

// ─────────────────────────────────────────────
// MARK: - Quiz Window Controller
// ─────────────────────────────────────────────

class QuizWindowController {
    static let shared = QuizWindowController()
    private var window: NSWindow?

    func present(photos: [Photo]) {
        guard let screen = NSScreen.main else { return }
        OverlayWindowController.shared.hide()

        let w: CGFloat = 800, h: CGFloat = 620
        let frame = NSRect(
            x: (screen.frame.width  - w) / 2,
            y: (screen.frame.height - h) / 2,
            width: w, height: h
        )

        let win = NSWindow(contentRect: frame, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.isOpaque        = false
        win.backgroundColor = .clear
        win.hasShadow       = true
        win.level           = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let hosting = NSHostingView(rootView: QuizRootView())
        hosting.frame = NSRect(x: 0, y: 0, width: w, height: h)
        win.contentView = hosting
        self.window = win

        QuizState.shared.startQuiz(photos: photos)
        win.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

// ─────────────────────────────────────────────
// MARK: - Quiz Root View
// ─────────────────────────────────────────────

struct QuizRootView: View {
    @ObservedObject var quiz = QuizState.shared

    var body: some View {
        ZStack {
            if quiz.quizComplete {
                QuizResultView()
            } else if let q = quiz.currentQ {
                QuizQuestionView(q: q)
            }
        }
        .frame(width: 800, height: 620)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(
                    colors: [Color(red: 0.09, green: 0.06, blue: 0.28),
                             Color(red: 0.05, green: 0.03, blue: 0.18)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .shadow(color: .black.opacity(0.7), radius: 40, x: 0, y: 10)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

// ─────────────────────────────────────────────
// MARK: - Quiz Question View
// ─────────────────────────────────────────────

struct QuizQuestionView: View {
    let q: QuizQuestion
    @ObservedObject var quiz = QuizState.shared

    // Kahoot-style button palette
    private let palette: [(Color, String)] = [
        (Color(red: 0.886, green: 0.106, blue: 0.235), "▲"),
        (Color(red: 0.075, green: 0.408, blue: 0.808), "◆"),
        (Color(red: 1.000, green: 0.651, blue: 0.008), "●"),
        (Color(red: 0.149, green: 0.537, blue: 0.047), "■")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ─────────────────────────────────────────────────
            HStack {
                Text("Q \(quiz.qIndex + 1) / \(quiz.questions.count)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(white: 0.7))
                Spacer()
                // Score pips
                HStack(spacing: 4) {
                    ForEach(0..<quiz.questions.count, id: \.self) { i in
                        Circle()
                            .fill(i < quiz.answers.count
                                  ? (quiz.answers[i].isCorrect ? Color.green : Color.red)
                                  : Color(white: 0.35))
                            .frame(width: 10, height: 10)
                    }
                }
                Spacer()
                Text("⭐ \(quiz.score)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.yellow)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)

            // Timer bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.2)).frame(height: 6)
                    Capsule()
                        .fill(timerColor)
                        .frame(width: geo.size.width * CGFloat(quiz.timeRemaining / 15), height: 6)
                        .animation(.linear(duration: 0.05), value: quiz.timeRemaining)
                }
            }
            .frame(height: 6)
            .padding(.horizontal, 24)
            .padding(.top, 10)

            // ── Painting thumbnail ───────────────────────────────────────
            Group {
                if let url = q.cachedImageURL, let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 280, height: 180)
                        .clipped()
                        .cornerRadius(12)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(white: 0.15))
                        .frame(width: 280, height: 180)
                        .overlay(Text("🖼").font(.system(size: 50)))
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 4)
            .padding(.top, 16)

            // Question text
            Text(q.type.prompt)
                .font(.system(size: 22, weight: .bold, design: .serif))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
                .padding(.horizontal, 40)

            // Hint button (artist questions only)
            if q.type.hasHint {
                Button(action: { quiz.showHint.toggle() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "lightbulb.fill")
                            .foregroundColor(.yellow)
                        Text("Hint")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.yellow)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(Color.yellow.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }

            // Hint panel — portrait slide-up
            if quiz.showHint, let portraitURL = quiz.portraitURLs.first,
               let img = NSImage(contentsOf: portraitURL) {
                HStack(spacing: 12) {
                    Image(nsImage: img)
                        .resizable().scaledToFill()
                        .frame(width: 56, height: 56).clipped()
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.yellow.opacity(0.6), lineWidth: 2))
                    Text("This is the artist.\nDo you recognize them?")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(white: 0.8))
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.12)))
                .padding(.horizontal, 40)
                .padding(.top, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(), value: quiz.showHint)
            }

            Spacer(minLength: 0)

            // ── 2×2 Answer grid ──────────────────────────────────────────
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(Array(q.options.enumerated()), id: \.offset) { idx, option in
                    answerButton(option: option, idx: idx)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }

    @ViewBuilder
    private func answerButton(option: String, idx: Int) -> some View {
        let isChosen  = quiz.chosen == option
        let isCorrect = option == q.correctAnswer
        let answered  = quiz.chosen != nil

        let baseColor = palette[idx % palette.count].0
        let shape = palette[idx % palette.count].1

        Button(action: { if !answered { quiz.select(option) } }) {
            HStack(spacing: 10) {
                Text(shape)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundColor(.white.opacity(0.7))
                Text(option)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(buttonColor(base: baseColor, option: option,
                                      isChosen: isChosen, isCorrect: isCorrect, answered: answered))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(answered && isCorrect ? Color.green : Color.clear, lineWidth: 2)
            )
            .scaleEffect(isChosen && quiz.showResult ? 0.97 : 1.0)
            .animation(.spring(response: 0.2), value: quiz.showResult)
        }
        .buttonStyle(.plain)
        .disabled(answered)
    }

    private func buttonColor(base: Color, option: String, isChosen: Bool,
                              isCorrect: Bool, answered: Bool) -> Color {
        guard answered else { return base }
        if isCorrect { return .green.opacity(0.85) }
        if isChosen  { return .red.opacity(0.7) }
        return base.opacity(0.3)
    }

    private var timerColor: Color {
        if quiz.timeRemaining > 8 { return .green }
        if quiz.timeRemaining > 4 { return .yellow }
        return .red
    }
}

// ─────────────────────────────────────────────
// MARK: - Quiz Result View
// ─────────────────────────────────────────────

struct QuizResultView: View {
    @ObservedObject var quiz = QuizState.shared

    private var tier: (emoji: String, label: String) {
        switch quiz.score {
        case 5:      return ("🏆", "Maestro!")
        case 4:      return ("🥇", "Connoisseur!")
        case 3:      return ("🥈", "Scholar")
        case 2:      return ("🥉", "Apprentice")
        default:     return ("🎨", "Keep Looking!")
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Art Quiz Complete!")
                .font(.system(size: 28, weight: .black, design: .serif))
                .foregroundColor(.white)

            Text(tier.emoji)
                .font(.system(size: 64))

            Text("\(quiz.score) / \(quiz.questions.count)")
                .font(.system(size: 48, weight: .black))
                .foregroundColor(.yellow)

            Text(tier.label)
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .foregroundColor(Color(white: 0.85))
                .italic()

            // Review cards
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(quiz.answers.enumerated()), id: \.offset) { _, answer in
                        reviewCard(answer)
                    }
                }
                .padding(.horizontal, 24)
            }
            .frame(height: 130)

            HStack(spacing: 16) {
                Button("Done") { quiz.endQuiz() }
                    .buttonStyle(QuizButtonStyle(color: Color(white: 0.3)))
            }
            .padding(.bottom, 20)
        }
        .padding(.top, 30)
    }

    @ViewBuilder
    private func reviewCard(_ answer: QuizAnswer) -> some View {
        VStack(spacing: 6) {
            if let url = answer.question.cachedImageURL, let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable().scaledToFill()
                    .frame(width: 80, height: 60).clipped().cornerRadius(8)
            }
            Text(answer.isCorrect ? "✓" : "✗")
                .font(.system(size: 18, weight: .black))
                .foregroundColor(answer.isCorrect ? .green : .red)
            Text(answer.question.correctAnswer)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(Color(white: 0.75))
                .lineLimit(2).multilineTextAlignment(.center)
                .frame(width: 90)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Color(white: 0.1)))
    }
}

struct QuizButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 28).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 10).fill(color))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

// ─────────────────────────────────────────────
// MARK: - App Delegate
// ─────────────────────────────────────────────


class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create menu bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.title = "🎨"
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Pulse the menu bar icon to 🧠 when a quiz is ready
        NotificationCenter.default.addObserver(forName: NSNotification.Name("ArtifyQuizReady"),
                                               object: nil, queue: .main) { [weak self] _ in
            self?.statusItem.button?.title = "🧠"
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("ArtifyQuizDone"),
                                               object: nil, queue: .main) { [weak self] _ in
            self?.statusItem.button?.title = "🎨"
        }

        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 260, height: 340)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarContentView())

        // Show overlay on desktop and kick off first fetch
        OverlayWindowController.shared.show()
        ArtifyState.shared.fetchRandom()
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

// ─────────────────────────────────────────────
// MARK: - Main Entry Point
// ─────────────────────────────────────────────

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // Menu bar app, no dock icon
app.run()
