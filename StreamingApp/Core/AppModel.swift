import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let contentSource: RezkaContentSource
    let browser: RezkaBrowserSession
    private let defaults: UserDefaults
    let watchSync = WatchSyncManager()

    private(set) var catalogueItems: [MediaItem] = []
    private(set) var isLoadingHome = false
    private(set) var homeError: String?
    private(set) var activeMirror = "Automatic"
    private(set) var hasMoreHome = false
    private var homePage = 1
    var selectedTab = 0
    private(set) var categories: [RezkaCategory] = []
    private(set) var collectionPicks: [RezkaCollection] = []
    private(set) var popularPicks: [MediaItem] = []
    private(set) var popularSeriesPicks: [MediaItem] = []
    private var isLoadingDiscovery = false
    private var detailItems: [String: MediaItem] = [:]
    private var originalArtworkURLs: [String: URL] = [:]
    private var previewArtworkURLs: [String: URL] = [:]
    @ObservationIgnored private var previewRequests = Set<String>()
    @ObservationIgnored private var attemptedPreviewRequests = Set<String>()
    private(set) var customItems: [MediaItem]
    private(set) var favoriteIDs: Set<String>
    private(set) var history: [WatchRecord]
    private(set) var episodeHistory: [String: WatchRecord]
    var playbackEngine: String {
        didSet { defaults.set(playbackEngine, forKey: "playbackEngine") }
    }
    private(set) var downloadedItems: [MediaItem]
    private(set) var recentSearches: [String]
    var preferredQuality: String {
        didSet { defaults.set(preferredQuality, forKey: "preferredQuality") }
    }
    var autoPlayNext: Bool {
        didSet { defaults.set(autoPlayNext, forKey: "autoPlayNext") }
    }
    var excludedCountryCodes: Set<String> {
        didSet { defaults.set(Array(excludedCountryCodes).sorted(), forKey: "excludedCountryCodes") }
    }
    private var countryCodesByMediaID: [String: [String]] = [:]
    var errorMessage: String?
    private(set) var downloadProgress: [String: Double] = [:]
    private(set) var downloadTitles: [String: String] = [:]

    init(defaults injectedDefaults: UserDefaults = .standard) {
        let defaults: UserDefaults
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--rezka-ui-fixtures") {
            defaults = UserDefaults(suiteName: "RezkaUIFixtures")!
            defaults.removePersistentDomain(forName: "RezkaUIFixtures")
        } else { defaults = injectedDefaults }
        #else
        defaults = injectedDefaults
        #endif
        self.defaults = defaults
        let browser = RezkaBrowserSession()
        self.browser = browser
        let transport: any RezkaTransport
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--rezka-ui-fixtures") { transport = RezkaUITestTransport() }
        else { transport = RezkaURLSessionTransport() }
        #else
        transport = RezkaURLSessionTransport()
        #endif
        contentSource = RezkaContentSource(client: RezkaHttpClient(transport: transport, browserFetch: { request in
            try await browser.fetch(request)
        }))
        customItems = Self.decode([MediaItem].self, key: "customItems", defaults: defaults) ?? []
        favoriteIDs = Set(Self.decode([String].self, key: "favoriteIDs", defaults: defaults) ?? [])
        history = Self.decode([WatchRecord].self, key: "watchHistory", defaults: defaults) ?? []
        episodeHistory = Self.decode([String: WatchRecord].self, key: "episodeHistory", defaults: defaults) ?? [:]
        #if DEBUG
        playbackEngine = ProcessInfo.processInfo.arguments.contains("--rezka-ui-fixtures") ? "native"
            : (defaults.string(forKey: "playbackEngine") == "native" ? "native" : "website")
        #else
        playbackEngine = defaults.string(forKey: "playbackEngine") == "native" ? "native" : "website"
        #endif
        downloadedItems = Self.decode([MediaItem].self, key: "downloadedItems", defaults: defaults) ?? []
        recentSearches = Self.decode([String].self, key: "recentSearches", defaults: defaults) ?? []
        preferredQuality = defaults.string(forKey: "preferredQuality") ?? "Auto"
        autoPlayNext = defaults.object(forKey: "autoPlayNext") as? Bool ?? true
        excludedCountryCodes = Set(defaults.stringArray(forKey: "excludedCountryCodes") ?? [])
        originalArtworkURLs = Self.decode([String: URL].self, key: "originalArtworkURLs", defaults: defaults) ?? [:]
        previewArtworkURLs = Self.decode([String: URL].self, key: "previewArtworkURLs", defaults: defaults) ?? [:]
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--rezka-ui-fixtures") {
            autoPlayNext = ProcessInfo.processInfo.arguments.contains("--rezka-ui-autoplay")
        }
        #endif
    }

    private var allItems: [MediaItem] {
        let overrides = Dictionary(uniqueKeysWithValues: customItems.map { ($0.id, $0) })
        let replaced = catalogueItems.map { overrides[$0.id] ?? detailItems[$0.id] ?? $0 }
        let extraItems = customItems.filter { custom in !catalogueItems.contains(where: { $0.id == custom.id }) }
        return replaced + extraItems
    }

    var items: [MediaItem] { visibleItems(allItems) }

    func visibleItems(_ items: [MediaItem]) -> [MediaItem] {
        guard !excludedCountryCodes.isEmpty else { return items }
        return items.filter { item in
            var resolved = item
            resolved.countryCodes = item.countryCodes?.nonEmptyCountries
                ?? MediaCountry.codes(in: item.metadata?.information["Страна"] ?? "").nonEmptyCountries
                ?? countryCodesByMediaID[item.id]
            return !MediaCountry.isExcluded(resolved, codes: excludedCountryCodes)
        }
    }

    func countryChecked(_ items: [MediaItem]) async -> [MediaItem] {
        guard !excludedCountryCodes.isEmpty else { return items }
        let resolved = await contentSource.countryMetadata(for: items)
        for item in resolved { countryCodesByMediaID[item.id] = item.countryCodes ?? [] }
        return resolved
    }

    func checkCatalogueCountries() async {
        _ = await countryChecked(catalogueItems + popularPicks)
    }

    var favorites: [MediaItem] {
        allItems.filter { favoriteIDs.contains($0.id) }
    }

    var continueWatching: [WatchRecord] {
        history.filter { ($0.position > 0 || $0.episodeID != nil) && $0.progress < 1.0 }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func item(id: String) -> MediaItem? {
        allItems.first { $0.id == id } ?? detailItems[id] ?? history.first { $0.item.id == id }?.item ?? downloadedItems.first { $0.id == id }
    }

    func loadHome(reset: Bool = true) async {
        guard !isLoadingHome else { return }
        isLoadingHome = true
        homeError = nil
        defer { isLoadingHome = false }
        do {
            let nextPage = reset ? 1 : homePage + 1
            let result = try await contentSource.catalogue(page: nextPage)
            let checked = await countryChecked(result.items)
            if reset { catalogueItems = checked; categories = result.categories }
            else { catalogueItems += checked.filter { candidate in !catalogueItems.contains(where: { $0.id == candidate.id }) } }
            homePage = nextPage
            hasMoreHome = result.hasNextPage
            activeMirror = try await contentSource.mirrors.activeURL().host ?? "Automatic"
        } catch is CancellationError { }
        catch { homeError = error.localizedDescription }
    }

    func search(_ query: String) async -> [MediaItem] {
        do { return visibleItems(await countryChecked(try await contentSource.search(query: query, page: 1))) }
        catch is CancellationError { return [] }
        catch { errorMessage = error.localizedDescription; return [] }
    }

    func loadDetails(_ item: MediaItem) async throws -> MediaItem {
        let result = try await contentSource.details(item: item)
        detailItems[item.id] = result
        if let url = result.posterURL {
            originalArtworkURLs[item.id] = url
            persist(originalArtworkURLs, key: "originalArtworkURLs")
        }
        if let url = result.previewPosterURL {
            previewArtworkURLs[item.id] = url
            persist(previewArtworkURLs, key: "previewArtworkURLs")
        }
        countryCodesByMediaID[item.id] = result.countryCodes ?? []
        if favoriteIDs.contains(item.id) { upsert(result) }
        return result
    }

    func artworkItem(for item: MediaItem) -> MediaItem {
        var result = item
        result.posterURL = originalArtworkURLs[item.id] ?? item.posterURL
        return result
    }

    func hasOriginalArtwork(for item: MediaItem) -> Bool {
        originalArtworkURLs[item.id] != nil || item.metadata != nil
    }

    func previewArtworkItem(for item: MediaItem) -> MediaItem {
        var result = item
        result.posterURL = originalArtworkURLs[item.id] ?? previewArtworkURLs[item.id] ?? item.previewPosterURL ?? item.posterURL
        return result
    }

    func preparePreviewArtwork(for item: MediaItem) async {
        guard item.rezka != nil, originalArtworkURLs[item.id] == nil,
              previewArtworkURLs[item.id] == nil, !attemptedPreviewRequests.contains(item.id) else { return }
        do {
            // Briefly passing a card should not start another page request.
            try await Task.sleep(for: .milliseconds(400))
            while previewRequests.count >= 3 { try await Task.sleep(for: .milliseconds(150)) }
            try Task.checkCancellation()
            guard previewArtworkURLs[item.id] == nil, !previewRequests.contains(item.id) else { return }
            previewRequests.insert(item.id)
            defer { previewRequests.remove(item.id) }
            if let url = try await contentSource.previewArtwork(item: item) {
                try Task.checkCancellation()
                previewArtworkURLs[item.id] = url
                persist(previewArtworkURLs, key: "previewArtworkURLs")
            }
            attemptedPreviewRequests.insert(item.id)
        } catch is CancellationError { }
        catch { attemptedPreviewRequests.insert(item.id) }
    }

    func selectMirror(_ host: String) async {
        do {
            try await contentSource.mirrors.select(host)
            activeMirror = try await contentSource.mirrors.activeURL().host ?? "Automatic"
            await loadHome()
        } catch { errorMessage = error.localizedDescription }
    }

    func loadDiscovery(force: Bool = false) async {
        guard !isLoadingDiscovery, force || collectionPicks.isEmpty || popularPicks.isEmpty || popularSeriesPicks.isEmpty else { return }
        isLoadingDiscovery = true
        defer { isLoadingDiscovery = false }
        do {
            let base = try await contentSource.mirrors.activeURL()
            async let collections = contentSource.collections()
            async let popular = contentSource.catalogue(url: base.appendingPathComponent("films/"), filter: "popular")
            async let series = contentSource.catalogue(url: base.appendingPathComponent("series/"), filter: "popular")
            let results = await (try? collections, try? popular, try? series)
            if let collections = results.0 { collectionPicks = collections }
            if let popular = results.1 { popularPicks = await countryChecked(popular.items) }
            if let series = results.2 { popularSeriesPicks = await countryChecked(series.items) }
        } catch { }
    }

    func rememberSearch(_ query: String) {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        recentSearches.removeAll { $0.localizedCaseInsensitiveCompare(cleaned) == .orderedSame }
        recentSearches.insert(cleaned, at: 0)
        recentSearches = Array(recentSearches.prefix(8))
        persist(recentSearches, key: "recentSearches")
    }

    func clearSearchHistory() {
        recentSearches = []
        persist(recentSearches, key: "recentSearches")
    }

    func toggleFavorite(_ item: MediaItem) {
        if favoriteIDs.contains(item.id) {
            favoriteIDs.remove(item.id)
        } else {
            favoriteIDs.insert(item.id)
            upsert(item)
        }
        persist(Array(favoriteIDs), key: "favoriteIDs")
    }

    func isFavorite(_ item: MediaItem) -> Bool {
        favoriteIDs.contains(item.id)
    }

    func upsert(_ item: MediaItem) {
        if let index = customItems.firstIndex(where: { $0.id == item.id }) {
            customItems[index] = item
        } else {
            customItems.append(item)
        }
        persist(customItems, key: "customItems")
    }

    func recordProgress(for item: MediaItem, position: TimeInterval, duration: TimeInterval, request: PlaybackRequest? = nil, recordedAt: Date = .now) {
        guard position.isFinite, position >= 0 else { return }
        let latest = history.first(where: { $0.item.id == item.id })
        let previous: WatchRecord?
        if let season = request?.season, let episode = request?.episode {
            previous = episodeRecord(mediaID: item.id, season: season, episode: episode)
        } else {
            previous = latest.flatMap { $0.seasonID == nil && $0.episodeID == nil ? $0 : nil }
        }
        // A final checkpoint may arrive after a newly opened player has saved.
        guard previous.map({ $0.updatedAt <= recordedAt }) ?? true,
              latest.map({ $0.updatedAt <= recordedAt }) ?? true else { return }
        let knownDuration = duration.isFinite && duration > 0 ? duration : previous?.duration ?? 0
        let record = WatchRecord(item: item, position: position, duration: knownDuration, updatedAt: recordedAt,
                                 translatorID: request?.translatorID, seasonID: request?.season, episodeID: request?.episode)
        if let season = request?.season, let episode = request?.episode {
            episodeHistory[episodeKey(item.id, season, episode)] = record
            persist(episodeHistory, key: "episodeHistory")
        }
        history.removeAll { $0.item.id == item.id }
        history.insert(record, at: 0)
        if record.progress >= 1.0 {
            history.removeAll { $0.item.id == item.id }
        }
        persist(history, key: "watchHistory")
        watchSync.schedule(records: cloudHistoryRecords)
    }

    func recordStart(_ item: MediaItem) {
        var record = history.first { $0.item.id == item.id } ?? WatchRecord(item: item, position: 0, duration: 0, updatedAt: .now)
        record.item = item
        record.updatedAt = .now
        history.removeAll { $0.item.id == item.id }
        history.insert(record, at: 0)
        persist(history, key: "watchHistory")
        watchSync.schedule(records: cloudHistoryRecords)
    }

    func episodeRecord(mediaID: String, season: String, episode: String) -> WatchRecord? {
        episodeHistory[episodeKey(mediaID, season, episode)]
            ?? history.first(where: { $0.item.id == mediaID && $0.seasonID == season && $0.episodeID == episode })
    }

    private func episodeKey(_ mediaID: String, _ season: String, _ episode: String) -> String {
        "\(mediaID):\(season):\(episode)"
    }

    func clearHistory() {
        history = []
        episodeHistory = [:]
        persist(history, key: "watchHistory")
        persist(episodeHistory, key: "episodeHistory")
        watchSync.clearRemoteHistory()
    }

    var cloudHistoryRecords: [WatchRecord] {
        var records = episodeHistory.values.reduce(into: [String: WatchRecord]()) { result, record in
            result["\(record.item.id):\(record.seasonID ?? "movie"):\(record.episodeID ?? "movie")"] = record
        }
        for record in history {
            let key = "\(record.item.id):\(record.seasonID ?? "movie"):\(record.episodeID ?? "movie")"
            if records[key].map({ $0.updatedAt < record.updatedAt }) ?? true { records[key] = record }
        }
        return Array(records.values).sorted { $0.updatedAt > $1.updatedAt }.prefix(500).map { $0 }
    }

    func installCloudHistory(_ records: [WatchRecord]) {
        var episodes: [String: WatchRecord] = [:]
        var latest: [String: WatchRecord] = [:]
        for record in records {
            if let season = record.seasonID, let episode = record.episodeID {
                episodes[episodeKey(record.item.id, season, episode)] = record
            }
            if latest[record.item.id].map({ $0.updatedAt < record.updatedAt }) ?? true { latest[record.item.id] = record }
        }
        episodeHistory = episodes
        history = Array(latest.values).sorted { $0.updatedAt > $1.updatedAt }
        persist(episodeHistory, key: "episodeHistory")
        persist(history, key: "watchHistory")
    }

    func syncHistoryOnLaunch() async {
        let records = await watchSync.restore(local: cloudHistoryRecords)
        installCloudHistory(records)
    }

    func refreshCloudHistory() async {
        let records = await watchSync.refresh(local: cloudHistoryRecords)
        installCloudHistory(records)
    }

    func syncHistoryBeforeLeaving() async {
        await watchSync.syncNow(records: cloudHistoryRecords)
    }

    func syncHistoryNow() async {
        await watchSync.syncNow(records: cloudHistoryRecords)
    }

    func downloadID(for item: MediaItem, request: PlaybackRequest? = nil) -> String {
        "offline:\(item.id):\(request?.season ?? "movie"):\(request?.episode ?? "movie")"
    }

    func saveOfflineCopy(of item: MediaItem, request: PlaybackRequest? = nil) async {
        let id = downloadID(for: item, request: request)
        guard downloadProgress[id] == nil, !downloadedItems.contains(where: { $0.id == id }) else { return }
        downloadProgress[id] = 0
        downloadTitles[id] = item.title
        defer { downloadProgress[id] = nil; downloadTitles[id] = nil }
        do {
            let source: PlaybackSource
            if let url = item.streamURL {
                guard !url.isFileURL else { return }
                source = PlaybackSource(streams: [VideoStream(quality: "Original", url: url)], subtitles: [])
            } else {
                guard let request else { throw ContentSourceError.missingMedia }
                source = try await contentSource.playback(request: request)
            }
            let stream = source.streams.first(where: { $0.quality == preferredQuality }) ?? source.streams[0]
            let localURL = try await OfflineVideoDownloader().download(url: stream.url, headers: source.headers, title: item.title) { [weak self] fraction in
                guard self?.downloadTitles[id] != nil else { return }
                self?.downloadProgress[id] = fraction
            }
            var offlineItem = item
            offlineItem.id = id
            offlineItem.streamURL = localURL
            offlineItem.rezka = nil
            if let season = request?.season, let episode = request?.episode {
                offlineItem.title = "\(item.title), season \(season) episode \(episode)"
            }
            downloadedItems.insert(offlineItem, at: 0)
            persist(downloadedItems, key: "downloadedItems")
        } catch is CancellationError { }
        catch { errorMessage = "This video could not be downloaded. \(error.localizedDescription)" }
    }

    func removeDownload(_ item: MediaItem) {
        if let url = item.streamURL, url.isFileURL { try? FileManager.default.removeItem(at: url) }
        downloadedItems.removeAll { $0.id == item.id }
        persist(downloadedItems, key: "downloadedItems")
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
