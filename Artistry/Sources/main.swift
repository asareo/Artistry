// Artistry — Modern macOS Wallpaper App
// v3.1: Network debug pass — detailed status and forced network behavior.

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

struct APISearchResponse: Codable {
    let code: Int
    let message: String
    let data: [Photo]?
}

// ─────────────────────────────────────────────
// MARK: - Image Cache Manager
// ─────────────────────────────────────────────

class ArtifyCacheManager {
    static let shared = ArtifyCacheManager()

    private let cacheDir: URL
    private let maxCached = 2000
    private let maxCacheBytes: Int64 = 5 * 1024 * 1024 * 1024  // 5 GB
    private(set) var cachedWallpapers: [URL] = []

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = base.appendingPathComponent("Artistry", isDirectory: true)
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
        portraitDir = base.appendingPathComponent("Artistry/portraits", isDirectory: true)
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
        req.setValue("Artistry/1.0 (educational art app)", forHTTPHeaderField: "User-Agent")
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
    static let currentVersion = "3.2"

    @Published var updateAvailable = false
    @Published var updateNotes = ""
    @Published var updateURL = ""
    @Published var updateVersion = ""
    @Published var isCheckingForUpdates = false
    @Published var updateCheckMessage: String? = nil

    @Published var currentPhoto: Photo?
    @Published var isLoading = false
    @Published var loadingStatus: String? // Detailed status (e.g. "Downloading from Wikimedia...")
    @Published var lastError: String?
    @Published var shuffleInterval: TimeInterval = 180 // 180 = 3 min default
    @Published var overlayVisible = true
    @Published var quizReady = false   // true = menu bar shows "Quiz Ready" button
    @Published var favoritedIDs: Set<String> = []
    @Published var artistSearchQuery: String = ""
    @Published var discoveryQuery: String = ""
    @Published var isDiscovering = false
    @Published var discoveryMessage: String? = nil

    // Ring buffer of the last 10 successfully shown photos (for quiz)
    private(set) var recentlyShownPhotos: [Photo] = []
    private var photosUntilQuiz: Int = Int.random(in: 5...8)
    @Published var consecutiveCachedShown: Int = 0 // Tracks how many cached images shown in a row
    @Published var forceNetworkOnly = true // Default to fresh network downloads

    private init() {
        // Load favorites from UserDefaults
        if let saved = UserDefaults.standard.stringArray(forKey: "ArtifyFavoriteIDs") {
            favoritedIDs = Set(saved)
        }
        // Initialize default shuffle interval to 3 minutes
        setShuffleInterval(180)
    }

    // ── Favorites persistence ──────────────────────────────────────────

    func isFavorited(_ photo: Photo) -> Bool {
        favoritedIDs.contains(photo.id)
    }

    func toggleFavorite(_ photo: Photo) {
        if favoritedIDs.contains(photo.id) {
            favoritedIDs.remove(photo.id)
            removeFavoriteData(photoID: photo.id)
        } else {
            favoritedIDs.insert(photo.id)
            saveFavoriteData(photo)
        }
        UserDefaults.standard.set(Array(favoritedIDs), forKey: "ArtifyFavoriteIDs")
    }

    /// Load all favorited Photo objects from disk
    func loadFavoritePhotos() -> [Photo] {
        favoritedIDs.compactMap { id -> Photo? in
            let key = "ArtifyFav_\(id)"
            guard let data = UserDefaults.standard.data(forKey: key),
                  let photo = try? JSONDecoder().decode(Photo.self, from: data) else { return nil }
            return photo
        }.sorted { $0.name < $1.name }
    }

    private func saveFavoriteData(_ photo: Photo) {
        if let data = try? JSONEncoder().encode(photo) {
            UserDefaults.standard.set(data, forKey: "ArtifyFav_\(photo.id)")
        }
    }

    private func removeFavoriteData(photoID: String) {
        UserDefaults.standard.removeObject(forKey: "ArtifyFav_\(photoID)")
    }

    /// Returns the local cached image URL for a photo, if it was downloaded
    func cachedImageURL(for photo: Photo) -> URL? {
        ArtifyCacheManager.shared.cachedWallpapers
            .first { $0.lastPathComponent == "\(photo.id).jpg" }
    }

    private var shuffleTimer: Timer?
    private var lastPhotoID: String?
    private var currentWallpaperURL: URL?
    private var fetchRetryCount = 0
    private var hasAttemptedDiscoveryForCurrentQuery = false
    private var downloadFailCount = 0   // separate counter for image-level failures
    private let maxFetchRetries = 5    // max times to retry same-ID API response
    private let maxDownloadRetries = 8  // max image download failures before giving up
    private let downloadTimeoutSeconds: TimeInterval = 20  // generous for large art images

    let apiBase = "https://artistry-wsnw.onrender.com/api"

    func discoverArt() {
        guard !discoveryQuery.isEmpty else { return }
        let query = discoveryQuery
        isDiscovering = true
        discoveryMessage = "Searching..."
        discoveryQuery = ""
        
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(apiBase)/discover?q=\(encoded)") else {
            isDiscovering = false
            discoveryMessage = "Invalid query URL"
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isDiscovering = false
                
                if let error = error {
                    self.discoveryMessage = "Error: \(error.localizedDescription)"
                    self.fetchRandom()
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    self.discoveryMessage = "Failed to discover art (Server error)"
                    self.fetchRandom()
                    return
                }
                
                guard let data = data else {
                    self.discoveryMessage = "No response from server"
                    self.fetchRandom()
                    return
                }
                
                struct APIDiscoverResponse: Codable {
                    let code: Int
                    let message: String
                    let data: String?
                }
                
                if let discoverResp = try? JSONDecoder().decode(APIDiscoverResponse.self, from: data),
                   let output = discoverResp.data {
                    if output.contains("No paintings found") {
                        self.discoveryMessage = "No images found for '\(query)'"
                    } else if let range = output.range(of: "Success: Inserted ") {
                        let sub = output[range.upperBound...]
                        if let spaceIndex = sub.firstIndex(of: " ") {
                            let countStr = sub[..<spaceIndex]
                            if let count = Int(countStr) {
                                if count > 0 {
                                    self.discoveryMessage = "Added \(count) new images for '\(query)'"
                                } else {
                                    self.discoveryMessage = "No new images added (already in library) for '\(query)'"
                                }
                            } else {
                                self.discoveryMessage = "Search complete for '\(query)'"
                            }
                        } else {
                            self.discoveryMessage = "Search complete for '\(query)'"
                        }
                    } else {
                        self.discoveryMessage = "Search complete for '\(query)'"
                    }
                } else {
                    self.discoveryMessage = "Search complete for '\(query)'"
                }
                
                // Fetch a random photo immediately to show a new result from the discovery
                self.fetchRandom()
            }
        }.resume()
    }

    func discoverArtAndRetry(for artist: String) {
        hasAttemptedDiscoveryForCurrentQuery = true
        isDiscovering = true
        loadingStatus = "Discovering new art for '\(artist)'..."
        
        let encoded = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(apiBase)/discover?q=\(encoded)") else {
            isDiscovering = false
            self.fetchRandom(isRetry: true)
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isDiscovering = false
                self.fetchRetryCount = 0
                self.fetchRandom(isRetry: true)
            }
        }.resume()
    }

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
            hasAttemptedDiscoveryForCurrentQuery = false
        }

        // If already loading and this isn't a retry, ignore
        if isLoading && !isRetry { return }

        isLoading = true
        lastError = nil
        loadingStatus = "Fetching masterpiece info..."

        // Freshness Guarantee: If we've shown too many cached images in a row,
        // force a fresh API fetch to get new masterpieces.
        
        let urlString: String
        if !artistSearchQuery.isEmpty {
            let encodedQuery = artistSearchQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            loadingStatus = "Searching for '\(artistSearchQuery)'..."
            urlString = "\(apiBase)/search/photos?q=\(encodedQuery)"
        } else {
            urlString = "\(apiBase)/feature/random"
        }

        guard let url = URL(string: urlString) else {
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

                // 1. Try decoding as a single photo (Feature Random)
                if let apiResp = try? JSONDecoder().decode(APIResponse.self, from: data),
                   let photo = apiResp.data {
                    self.processFetchResult(photo: photo)
                    return
                }
                
                // 2. Try decoding as an array (Search result)
                if let searchResp = try? JSONDecoder().decode(APISearchResponse.self, from: data),
                   let photos = searchResp.data, !photos.isEmpty {
                    // Shuffle results so we don't always show the same 'first' hit
                    let photo = photos.shuffled()[0] 
                    self.processFetchResult(photo: photo)
                    return
                }
                
                // If we get here, neither worked (returned empty list or decode failed)
                if !self.artistSearchQuery.isEmpty {
                    if !self.hasAttemptedDiscoveryForCurrentQuery {
                        self.fetchRetryCount += 1
                        if self.fetchRetryCount >= 3 {
                            self.discoverArtAndRetry(for: self.artistSearchQuery)
                        } else {
                            self.isLoading = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                self.fetchRandom(isRetry: true)
                            }
                        }
                    } else {
                        // Already tried discovery and got nothing, fall back to random
                        self.artistSearchQuery = ""
                        self.fetchRandom()
                    }
                    return
                }
                self.lastError = "No photo found in response"
                self.isLoading = false
            }
        }.resume()
    }

    private func processFetchResult(photo: Photo) {
        // 1. Same-as-last-one check (API giving us the same ID twice)
        if photo.id == self.lastPhotoID && self.fetchRetryCount < self.maxFetchRetries {
            self.fetchRetryCount += 1
            if self.fetchRetryCount >= 3 && !self.artistSearchQuery.isEmpty && !self.hasAttemptedDiscoveryForCurrentQuery {
                self.discoverArtAndRetry(for: self.artistSearchQuery)
                return
            }
            self.isLoading = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.fetchRandom(isRetry: true)
            }
            return
        }

        // 2. Recent history check (Don't show the same image within the last 10)
        if recentlyShownPhotos.contains(where: { $0.id == photo.id }) && self.fetchRetryCount < self.maxFetchRetries {
            self.fetchRetryCount += 1
            if self.fetchRetryCount >= 3 && !self.artistSearchQuery.isEmpty && !self.hasAttemptedDiscoveryForCurrentQuery {
                self.discoverArtAndRetry(for: self.artistSearchQuery)
                return
            }
            self.isLoading = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.fetchRandom(isRetry: true)
            }
            return
        }

        self.fetchRetryCount = 0
        self.lastPhotoID = photo.id
        self.currentPhoto = photo
        self.setWallpaper(from: photo.image_url, photoID: photo.id)
    }


    func setWallpaper(from urlString: String, photoID: String) {
        guard let imageURL = URL(string: urlString) else {
            isLoading = false
            retryWithNewPhoto(reason: "Malformed image URL")
            return
        }

        // Serve instantly from local cache if we already downloaded this painting
        let cachedFile = ArtifyCacheManager.shared.cachedWallpapers
            .first { $0.lastPathComponent == "\(photoID).jpg" }
        
        // If we are NOT in a 'force fresh' mode, we can use the cache
        // But if 'forceNetworkOnly' is ON, we ALWAYS download.
        if !forceNetworkOnly, let existing = cachedFile, consecutiveCachedShown < 8 {
            consecutiveCachedShown += 1
            downloadFailCount = 0  // success path resets failure counter
            applyWallpaper(localURL: existing)
            isLoading = false
            return
        }

        // Otherwise, we must download a fresh copy or we forced a refresh
        consecutiveCachedShown = 0 // Reset since we are attempting a download
        
        let host = imageURL.host ?? "server"
        loadingStatus = "Downloading from \(host)..."
        
        // Timeout guard — both paths always touch `completed` on the main queue only
        var completed = false

        DispatchQueue.main.asyncAfter(deadline: .now() + downloadTimeoutSeconds) { [weak self] in
            guard let self = self, !completed else { return }
            completed = true
            self.isLoading = false
            // Timeout = try a different photo, don't give up
            self.retryWithNewPhoto(reason: "Download timed out")
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
            }
            
            DispatchQueue.main.async {
                if !completed {
                    completed = true
                    if let stable = stableURL {
                        self.downloadFailCount = 0
                        self.applyWallpaper(localURL: stable)
                        self.isLoading = false
                    } else {
                        self.retryWithNewPhoto(reason: "Download failed (status \(httpStatus))")
                    }
                }
            }
        }.resume()
    }

    private func applyFallbackIfAvailable() {
        // If the user wants Network Only, DO NOT show cached art even if retries fail.
        // This makes the network errors visible so we can debug them.
        if forceNetworkOnly {
            lastError = "Network Only Mode: Failed to download masterpiece. (No fallback)"
            return
        }

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
    private func retryWithNewPhoto(reason: String? = nil) {
        downloadFailCount += 1
        if let reason = reason {
            print("Download failed: \(reason)")
            loadingStatus = "Retrying... (\(reason))"
        }
        
        if downloadFailCount > maxDownloadRetries {
            // Truly stuck — show cached art and reset
            downloadFailCount = 0
            lastError = "Several images unavailable — showing cached art"
            if let reason = reason {
                lastError = "Network error: \(reason). Showing cached art."
            }
            applyFallbackIfAvailable()
            return
        }

        // Kick off a fresh API request after a short delay to prevent fast-looping
        lastError = nil
        isLoading = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.fetchRandom(isRetry: true)
        }
    }

    private func applyWallpaper(localURL: URL) {
        currentWallpaperURL = localURL

        // Dynamic Scaling: Choose between Fill (crop) and Fit (show all)
        // based on how well the image aspect ratio matches the screen.
        let image = NSImage(contentsOf: localURL)
        let imageSize = image?.size ?? .zero

        for screen in NSScreen.screens {
            let screenRatio = screen.frame.width / screen.frame.height
            let imageRatio = imageSize.width > 0 ? (imageSize.width / imageSize.height) : screenRatio
            
            // If aspect ratios differ by more than 15%, use 'Fit' (allowClipping: false)
            // so we don't crop off important parts of wide/tall masterpieces.
            let ratioDiff = abs(screenRatio - imageRatio) / screenRatio
            let shouldFit = ratioDiff > 0.15

            let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
                .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
                .allowClipping: NSNumber(value: !shouldFit) // false = Fit (show all), true = Fill (crop)
            ]
            
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

    // NOTE: isFavorited, toggleFavorite, and helpers are defined in the init block above.

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
            // Only pause shuffle if the user is actually IN a quiz window right now
            guard QuizWindowController.shared.isPresented == false else { return }
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

    func checkForUpdates(manual: Bool = false) {
        isCheckingForUpdates = true
        updateCheckMessage = manual ? "Checking for updates..." : nil
        
        guard let url = URL(string: "\(apiBase)/version/update?build_version=\(Self.currentVersion)") else {
            isCheckingForUpdates = false
            return
        }
        
        session.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isCheckingForUpdates = false
                
                if let error = error {
                    if manual {
                        self.updateCheckMessage = "Connection error: \(error.localizedDescription)"
                    }
                    return
                }
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    if manual {
                        self.updateCheckMessage = "Invalid response from server"
                    }
                    return
                }
                
                if httpResponse.statusCode == 204 {
                    if manual {
                        self.updateCheckMessage = "You're up to date! (v\(Self.currentVersion))"
                    }
                    return
                }
                
                guard let data = data else {
                    if manual {
                        self.updateCheckMessage = "Empty update response"
                    }
                    return
                }
                
                struct UpdateResponse: Codable {
                    struct UpdateData: Codable {
                        let build_version: String
                        let url: String
                        let notes: String?
                    }
                    let code: Int
                    let message: String
                    let data: UpdateData?
                }
                
                do {
                    let decoder = JSONDecoder()
                    let resp = try decoder.decode(UpdateResponse.self, from: data)
                    if let update = resp.data {
                        self.updateAvailable = true
                        self.updateNotes = update.notes ?? ""
                        self.updateURL = update.url
                        self.updateVersion = update.build_version
                        if manual {
                            self.updateCheckMessage = "New version \(update.build_version) is available!"
                        }
                        
                        let alert = NSAlert()
                        alert.messageText = "Update Available"
                        alert.informativeText = "A new version of Artify (v\(update.build_version)) is available.\n\nRelease Notes:\n\(update.notes ?? "No release notes provided.")"
                        alert.addButton(withTitle: "Download Now")
                        alert.addButton(withTitle: "Later")
                        if alert.runModal() == .alertFirstButtonReturn {
                            if let updateURL = URL(string: update.url) {
                                NSWorkspace.shared.open(updateURL)
                            }
                        }
                    } else {
                        if manual {
                            self.updateCheckMessage = "You're up to date! (v\(Self.currentVersion))"
                        }
                    }
                } catch {
                    if manual {
                        self.updateCheckMessage = "Failed to parse update info"
                    }
                }
            }
        }.resume()
    }

    func promptForCustomShuffleInterval() {
        let alert = NSAlert()
        alert.messageText = "Custom Shuffle Interval"
        alert.informativeText = "Enter shuffle interval in minutes (between 0.25 and 60 minutes):\nNote: 0.25 minutes is 15 seconds."
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.placeholderString = "e.g., 3, 5, 10"
        
        if shuffleInterval > 0 {
            let currentMins = shuffleInterval / 60.0
            input.stringValue = String(format: "%.2f", currentMins)
        }
        
        alert.accessoryView = input
        
        if alert.runModal() == .alertFirstButtonReturn {
            let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let mins = Double(text) {
                let secs = mins * 60.0
                if secs >= 15.0 && secs <= 3600.0 {
                    setShuffleInterval(secs)
                    updateCheckMessage = "Shuffle set to \(mins) min"
                } else {
                    let errAlert = NSAlert()
                    errAlert.messageText = "Invalid Interval"
                    errAlert.informativeText = "The shuffle interval must be between 0.25 minutes (15 seconds) and 60 minutes."
                    errAlert.addButton(withTitle: "OK")
                    errAlert.runModal()
                }
            } else {
                let errAlert = NSAlert()
                errAlert.messageText = "Invalid Number"
                errAlert.informativeText = "Please enter a valid numeric value."
                errAlert.addButton(withTitle: "OK")
                errAlert.runModal()
            }
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
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing bufferingType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: bufferingType, defer: flag)
        self.isMovableByWindowBackground = true // Native macOS dragging
        self.level = .floating
        self.hidesOnDeactivate = false // CRITICAL: Keep interactable even when clicking desktop
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
    }

    // Capture mouse down to ensure dragging works even over some SwiftUI elements
    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        self.makeKeyAndOrderFront(nil)
        self.performDrag(with: event)
    }
}

// ─────────────────────────────────────────────
// MARK: - About Window Controller
// ─────────────────────────────────────────────

class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w: CGFloat = 360, h: CGFloat = 400
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            win.isReleasedWhenClosed = false
            win.center()
            win.title = "About Artistry"
            win.titlebarAppearsTransparent = true
            win.isMovableByWindowBackground = true
            
            let hosting = NSHostingView(rootView: AboutView())
            hosting.frame = NSRect(x: 0, y: 0, width: w, height: h)
            win.contentView = hosting
            self.window = win
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AboutView: View {
    @ObservedObject var state = ArtifyState.shared
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "paintbrush.fill")
                .font(.system(size: 60))
                .foregroundColor(.accentColor)
                .padding(.top, 40)
            
            Text("Artistry")
                .font(.system(size: 24, weight: .bold))
            
            Text("v\(ArtifyState.currentVersion)")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider().padding(.horizontal, 40)
            
            VStack(spacing: 8) {
                Text("Developed by Owuraku")
                    .font(.headline)
                Text("Bringing the world's masterpieces to your desktop.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                let cacheCount = ArtifyCacheManager.shared.cachedWallpapers.count
                let portraitCount = ArtistPortraitCache.shared.totalCount
                
                HStack {
                    Image(systemName: "photo.on.rectangle")
                    Text("\(cacheCount) paintings cached")
                }
                HStack {
                    Image(systemName: "person.crop.rectangle")
                    Text("\(portraitCount) artist portraits saved")
                }
            }
            .font(.caption)
            .padding(15)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.1)))
            
            Spacer()
            
            Text("© 2026 Owuraku. All rights reserved.")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
        }
        .frame(width: 360, height: 400)
    }
}

// ─────────────────────────────────────────────
// MARK: - Gallery Window Controller
// ─────────────────────────────────────────────

class GalleryWindowController {
    static let shared = GalleryWindowController()
    private var window: NSWindow?

    func show() {
        // Always create a fresh window so gallery data is current
        window?.close()
        window = nil

        let w: CGFloat = 860, h: CGFloat = 640
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.center()
        win.title = "Masterpiece Gallery"
        win.titlebarAppearsTransparent = true
        win.minSize = NSSize(width: 640, height: 480)

        let hosting = NSHostingView(rootView: GalleryView())
        hosting.frame = NSRect(x: 0, y: 0, width: w, height: h)
        win.contentView = hosting
        self.window = win

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct GalleryView: View {
    @ObservedObject var state = ArtifyState.shared
    @State private var favorites: [Photo] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Masterpiece Gallery")
                        .font(.system(size: 22, weight: .bold, design: .serif))
                    Text("\(favorites.count) saved work\(favorites.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "heart.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.red.opacity(0.7))
            }
            .padding(.horizontal, 30)
            .padding(.top, 50)
            .padding(.bottom, 16)

            Divider()

            if favorites.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "heart.slash")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text("No favorites yet")
                        .font(.title2.bold())
                    Text("Click the ♥ on the overlay while viewing a painting")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 240), spacing: 16)],
                        spacing: 16
                    ) {
                        ForEach(favorites, id: \.id) { photo in
                            GalleryItem(photo: photo)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .onAppear { reload() }
        // Re-read whenever the user hearts/unhearts something
        .onChange(of: state.favoritedIDs) { _ in reload() }
    }

    private func reload() {
        favorites = state.loadFavoritePhotos()
    }
}

struct GalleryItem: View {
    let photo: Photo
    @ObservedObject var state = ArtifyState.shared
    @State private var isHovering = false
    @State private var showInfo = false

    private var cachedURL: URL? { state.cachedImageURL(for: photo) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── Thumbnail ──────────────────────────────────────────────
            ZStack(alignment: .topTrailing) {
                Group {
                    if let url = cachedURL {
                        ThumbnailImage(url: url)
                    } else {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.system(size: 30))
                                    .foregroundColor(.secondary)
                            )
                    }
                }
                .frame(height: 170)
                .clipped()

                // Info toggle
                Button(action: { withAnimation(.spring()) { showInfo.toggle() } }) {
                    Image(systemName: showInfo ? "info.circle.fill" : "info.circle")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                }
                .buttonStyle(.plain)
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // ── Info panel ────────────────────────────────────────────
            if showInfo {
                VStack(alignment: .leading, spacing: 6) {
                    Text(photo.name)
                        .font(.system(size: 13, weight: .bold, design: .serif))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 4) {
                        Text(photo.author.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                        if let date = photo.date, !date.isEmpty {
                            Text("· \(date)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack(spacing: 6) {
                        if let style = photo.style, !style.isEmpty {
                            galleryBadge(style)
                        }
                        if let media = photo.media, !media.isEmpty {
                            galleryBadge(media.split(separator: ",").first.map(String.init) ?? media)
                        }
                    }

                    if let info = photo.info, !info.isEmpty {
                        let blurb = info.hasPrefix("JEOPARDY KEY:") ?
                            String(info.dropFirst("JEOPARDY KEY:".count)).trimmingCharacters(in: .whitespaces) : info
                        Text(blurb.prefix(200) + (blurb.count > 200 ? "…" : ""))
                            .font(.system(size: 10, weight: .light))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Open in Photos / reveal in Finder buttons
                    HStack(spacing: 8) {
                        if let url = cachedURL {
                            Button(action: { openInPhotos(url) }) {
                                Label("Save to Photos", systemImage: "photo.badge.plus")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)

                            Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                                Label("Finder", systemImage: "folder")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }

                        Spacer()

                        // Unfavorite from gallery
                        Button(action: { state.toggleFavorite(photo) }) {
                            Image(systemName: "heart.slash")
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .help("Remove from favorites")
                    }
                    .padding(.top, 2)
                }
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor))
                .transition(.opacity.combined(with: .move(edge: .top)))

            } else {
                // Compact name/artist row
                VStack(alignment: .leading, spacing: 2) {
                    Text(photo.name)
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .lineLimit(1)
                    Text(photo.author.name)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(isHovering ? 0.18 : 0.08), radius: isHovering ? 12 : 6)
        )
        .scaleEffect(isHovering ? 1.015 : 1.0)
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.3), value: isHovering)
        .animation(.spring(response: 0.3), value: showInfo)
    }

    @ViewBuilder
    private func galleryBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundColor(.accentColor)
    }

    private func openInPhotos(_ url: URL) {
        // More robust AppleScript for Photos.app import
        let script = "tell application \"Photos\" to import {POSIX file \"\(url.path)\"}"
        let osa = "osascript -e '\(script)'"
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", osa]
        try? task.run()
    }
}

/// A stability-focused image view that loads downsampled thumbnails
/// to prevent crashes when displaying many high-resolution masterpieces.
struct ThumbnailImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.1)
                    .onAppear { loadThumbnail() }
            }
        }
    }

    private func loadThumbnail() {
        DispatchQueue.global(qos: .userInitiated).async {
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else { return }
            
            // Create a 500px thumbnail (large enough for gallery cards but small in memory)
            let downsampleOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 500
            ] as CFDictionary
            
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) {
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 250, height: 250))
                DispatchQueue.main.async {
                    self.image = nsImage
                }
            }
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
    @State private var isHoveringTitle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let photo = state.currentPhoto {

                // Title Area with Hover Reveal
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(photo.name)
                            .font(.system(size: 17, weight: .bold, design: .serif))
                            .foregroundColor(.white)
                            .lineLimit(isHoveringTitle ? 4 : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .onHover { isHoveringTitle = $0 }
                            .animation(.spring(), value: isHoveringTitle)
                        
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
                    }
                    
                    Spacer()
                    
                    // Favorite Button
                    Button(action: { state.toggleFavorite(photo) }) {
                        Image(systemName: state.isFavorited(photo) ? "heart.fill" : "heart")
                            .font(.system(size: 20))
                            .foregroundColor(state.isFavorited(photo) ? .red : .white.opacity(0.6))
                            .padding(8)
                            .background(Circle().fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
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
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    if let status = state.loadingStatus {
                        Text(status)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    } else {
                        Text("Curating Masterpiece...")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 4)
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
        VStack(alignment: .leading, spacing: 6) {
            // Header with current artwork + gear Settings menu
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    if let photo = state.currentPhoto {
                        Text(photo.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text("by \(photo.author.name)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Artify")
                            .font(.headline)
                        Text("No photo loaded")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                
                // Unified Settings menu (gear icon)
                Menu {
                    // Shuffle interval sub-menu
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
                        Button(state.shuffleInterval == 180 ? "✓ 3 min" : "3 min") {
                            state.setShuffleInterval(180)
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
                        
                        let isStandard = [0.0, 30.0, 60.0, 180.0, 300.0, 600.0, 1800.0].contains(state.shuffleInterval)
                        if !isStandard && state.shuffleInterval > 0 {
                            let mins = state.shuffleInterval / 60.0
                            Button(String(format: "✓ Custom (%.2f min)", mins)) {
                                state.promptForCustomShuffleInterval()
                            }
                        }
                        
                        Divider()
                        
                        Button("Custom Interval...") {
                            state.promptForCustomShuffleInterval()
                        }
                    }

                    // Check for updates
                    Button(state.isCheckingForUpdates ? "⏳  Checking..." : "🔄  Check for Updates...") {
                        state.checkForUpdates(manual: true)
                    }
                    .disabled(state.isCheckingForUpdates)

                    Button("ℹ️  About Artify") {
                        AboutWindowController.shared.show()
                    }

                    Divider()

                    Button("Quit") {
                        NSApplication.shared.terminate(nil)
                    }
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24, height: 24)
            }

            if !state.artistSearchQuery.isEmpty {
                Divider()
                HStack {
                    Text("🎨 Filtering: \(state.artistSearchQuery)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(red: 0.90, green: 0.60, blue: 0.15))
                        .lineLimit(1)
                    Spacer()
                    Button(action: {
                        state.artistSearchQuery = ""
                        state.fetchRandom()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(Color(red: 0.90, green: 0.60, blue: 0.15).opacity(0.12))
                .cornerRadius(6)
            }

            Divider()

            // Primary actions row (Randomize + Gallery)
            HStack(spacing: 8) {
                Button(action: {
                    state.fetchRandom()
                }) {
                    HStack {
                        if state.isLoading {
                            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                            Text("Loading…")
                        } else {
                            Text("🎲  Random")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .keyboardShortcut("r")
                .disabled(state.isLoading)

                Button(action: {
                    GalleryWindowController.shared.show()
                }) {
                    HStack {
                        Image(systemName: "photo.on.rectangle")
                        Text("Gallery")
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Divider()

            // Primary Toggle for Info Overlay
            Button(action: {
                state.toggleOverlay()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: state.overlayVisible ? "eye.slash" : "eye")
                    Text(state.overlayVisible ? "Hide Info Overlay" : "Show Info Overlay")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }

            Divider()

            // Discovery Search (Seeds DB)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Discover & Add New Art")
                        .font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    if state.isDiscovering {
                        ProgressView().scaleEffect(0.4).frame(width: 12, height: 12)
                    }
                }
                TextField("e.g. Surrealism, Monet...", text: $state.discoveryQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        state.discoverArt()
                    }
                
                if let msg = state.discoveryMessage {
                    Text(msg)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(msg.contains("Error") || msg.contains("No images found") || msg.contains("Failed") ? .orange : .green)
                        .padding(.top, 2)
                }
            }

            // Quiz ready banner — launches the Kahoot-style art quiz
            if state.quizReady {
                Divider()
                Button(action: {
                    let photos = Array(ArtifyState.shared.recentlyShownPhotos.suffix(5))
                    QuizWindowController.shared.present(photos: photos)
                }) {
                    HStack {
                        Text("🧠  Art Quiz Ready! Start →")
                            .font(.headline)
                            .foregroundColor(Color(red: 0.90, green: 0.60, blue: 0.15))
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.vertical, 4)
                    .background(Color(red: 0.90, green: 0.60, blue: 0.15).opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            // Status or Error notifications in a tiny font to preserve vertical height
            if let error = state.lastError {
                Divider()
                Text("⚠️ \(error)")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
            } else if let status = state.updateCheckMessage {
                Divider()
                Text(status)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
        .padding(10)
        .frame(width: 250)
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
                let name = photo.author.name.trimmingCharacters(in: .whitespacesAndNewlines)
                correct = name.isEmpty ? "Unknown Artist" : name
                pool = (photos.map { $0.author.name.trimmingCharacters(in: .whitespacesAndNewlines) } + fallbackArtists)
                    .filter { !$0.isEmpty && $0 != correct }
            case .title:
                let title = photo.name.trimmingCharacters(in: .whitespacesAndNewlines)
                correct = title.isEmpty ? "Untitled" : title
                pool = (photos.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) } + fallbackTitles)
                    .filter { !$0.isEmpty && $0 != correct }
            case .style:
                let style = photo.style?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                correct = style.isEmpty ? "Unknown" : style
                pool = (photos.compactMap { p -> String? in
                    let s = p.style?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return s.isEmpty ? nil : s
                } + fallbackStyles)
                    .filter { $0 != correct }
            }

            let poolArr: [String] = Array(Set(pool))
            var wrongs = poolArr.shuffled().prefix(3).map { String($0) }
            while wrongs.count < 3 { wrongs.append("Unknown") }

            let opts = ([correct] + wrongs).shuffled()
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
    
    var isPresented: Bool { window != nil }

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
                        .scaledToFit()
                        .frame(width: 480, height: 260)
                        .background(Color.black.opacity(0.15))
                        .cornerRadius(12)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(white: 0.15))
                        .frame(width: 480, height: 260)
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
        let artistName = answer.question.photo.author.name
        VStack(spacing: 6) {
            if let url = answer.question.cachedImageURL, let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable().scaledToFill()
                    .frame(width: 80, height: 60).clipped().cornerRadius(8)
            }
            Text(answer.isCorrect ? "✓" : "✗")
                .font(.system(size: 16, weight: .black))
                .foregroundColor(answer.isCorrect ? .green : .red)
            Text(answer.question.photo.name)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(width: 100)
            Text("by \(artistName)")
                .font(.system(size: 8))
                .foregroundColor(Color(white: 0.7))
                .lineLimit(1)
                .frame(width: 100)
            
            Button(action: {
                ArtifyState.shared.artistSearchQuery = artistName
                ArtifyState.shared.fetchRandom()
                QuizState.shared.endQuiz()
            }) {
                Text("Explore Artist")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Capsule().stroke(Color.yellow, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
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
        // Build a standard Edit menu in the system menu bar so cut/copy/paste shortcuts function
        setupEditMenu()

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

    private func setupEditMenu() {
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        
        editMenuItem.submenu = editMenu
        NSApplication.shared.mainMenu = mainMenu
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
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
