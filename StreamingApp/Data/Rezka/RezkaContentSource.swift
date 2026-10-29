import Foundation

actor RezkaContentSource: ContentSource {
    let client: RezkaHttpClient
    let mirrors: RezkaMirrorManager
    private let parser = RezkaPageParser()
    private var cache: [String: MediaItem] = [:]
    private struct PlaybackKey: Hashable {
        let request: PlaybackRequest
        let mirror: URL
    }
    private struct PreparedPlayback {
        let source: PlaybackSource
        let expiresAt: ContinuousClock.Instant
    }
    private var preparedPlayback: [PlaybackKey: PreparedPlayback] = [:]
    private var preparationTasks: [PlaybackKey: Task<PlaybackSource, Error>] = [:]

    init(client: RezkaHttpClient, mirrors: RezkaMirrorManager? = nil) {
        self.client = client
        self.mirrors = mirrors ?? RezkaMirrorManager(client: client)
    }

    func home() async throws -> [MediaItem] {
        try await catalogue().items
    }

    func catalogue(url: URL? = nil, page: Int = 1, filter: String? = nil) async throws -> RezkaCataloguePage {
        let base = try await mirrors.activeURL()
        var components = URLComponents(url: url ?? base, resolvingAgainstBaseURL: true)!
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "page" || $0.name == "filter" }
        // Catalogue pagination is a path segment in the APK; search uses a query parameter.
        if page > 1 {
            let path = components.path.replacingOccurrences(of: "/page/[0-9]+/?$", with: "/", options: .regularExpression)
            components.path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            components.path = "/" + components.path + (components.path.isEmpty ? "" : "/") + "page/\(page)/"
        }
        if let filter { query.append(URLQueryItem(name: "filter", value: filter)) }
        components.queryItems = query.isEmpty ? nil : query
        guard let requestURL = components.url else { throw RezkaError.invalidURL }
        let (html, resolvedURL) = try await fetchPage(requestURL)
        let result = try parser.catalogue(html: html, baseURL: resolvedURL, page: page)
        if result.items.isEmpty, page == 1 { throw RezkaError.invalidPage("The catalogue could not be read. Try another mirror.") }
        remember(result.items)
        return result
    }

    func search(query: String, page: Int) async throws -> [MediaItem] {
        try await searchPage(query: query, page: page).items
    }

    func searchPage(query: String, page: Int) async throws -> RezkaCataloguePage {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return RezkaCataloguePage(items: [], hasNextPage: false) }
        let base = try await mirrors.activeURL()
        var components = URLComponents(url: base.appendingPathComponent(RezkaEndpoints.search), resolvingAgainstBaseURL: true)!
        components.queryItems = [URLQueryItem(name: "do", value: "search"), URLQueryItem(name: "subaction", value: "search"),
                                 URLQueryItem(name: "q", value: cleaned), URLQueryItem(name: "page", value: String(max(page, 1)))]
        guard let url = components.url else { throw RezkaError.invalidURL }
        let (html, resolvedURL) = try await fetchPage(url)
        let result = try parser.catalogue(html: html, baseURL: resolvedURL, page: page)
        guard html.contains("b-content") || !result.items.isEmpty else { throw RezkaError.invalidPage("The search page could not be read.") }
        remember(result.items)
        return result
    }

    func details(item: MediaItem) async throws -> MediaItem {
        guard let media = item.rezka else { return item }
        let (html, resolvedURL) = try await fetchPage(media.pageURL)
        #if DEBUG
        RezkaPlaybackDiagnostics.save(Data(html.utf8), name: "title-page.html")
        #endif
        let result = try parser.details(html: html, baseURL: resolvedURL, item: item)
        cache[item.id] = result
        return result
    }

    func countryMetadata(for items: [MediaItem]) async -> [MediaItem] {
        var result: [MediaItem] = []
        for var item in items {
            if item.countryCodes == nil {
                if let cached = cache[item.id], cached.countryCodes != nil || cached.metadata != nil {
                    item.countryCodes = cached.countryCodes ?? []
                } else if !Task.isCancelled, item.rezka != nil, let detailed = try? await details(item: item) {
                    item.countryCodes = detailed.countryCodes ?? []
                }
            }
            result.append(item)
        }
        return result
    }

    /// Fetch only the medium cover link. Background artwork never opens verification UI.
    func previewArtwork(item: MediaItem) async throws -> URL? {
        if let preview = cache[item.id]?.previewPosterURL { return preview }
        guard let media = item.rezka else { return item.posterURL }
        let base = try await mirrors.activeURL()
        let url = try await mirrors.rebased(media.pageURL, onto: base)
        var request = client.request(url: url)
        request.timeoutInterval = 8
        let response = try await client.fetch(request, allowBrowser: false)
        return try parser.previewArtwork(html: response.text(), baseURL: response.url)
    }

    func episodes(item: MediaItem, translatorID: String) async throws -> [RezkaSeason] {
        guard let media = item.rezka else { return [] }
        let client = client
        let mirrors = mirrors
        return try await withMirror { base in
            let pageURL = try await mirrors.rebased(media.pageURL, onto: base)
            return try await RezkaEpisodeService(client: client).episodes(movieID: media.movieID, translatorID: translatorID, pageURL: pageURL, baseURL: base)
        }
    }

    func playback(request: PlaybackRequest) async throws -> PlaybackSource {
        try Task.checkCancellation()
        let key = PlaybackKey(request: request, mirror: try await mirrors.activeURL())
        prunePreparedPlayback()
        if let prepared = preparedPlayback[key] { return prepared.source }
        if let task = preparationTasks[key] {
            do {
                let source = try await task.value
                try Task.checkCancellation()
                return source
            } catch {
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        // A failed background request is retried interactively, so a challenge
        // can still be solved normally after the user explicitly presses Play.
        return try await resolvePlayback(request: request)
    }

    /// Resolves only the selected episode's small AJAX response, not video bytes.
    func preparePlayback(request: PlaybackRequest) async {
        guard !Task.isCancelled, let item = cache[request.mediaID],
              let media = item.rezka, !media.translators.isEmpty,
              !media.isSeries || (request.season != nil && request.episode != nil),
              let base = try? await mirrors.activeURL() else { return }
        let key = PlaybackKey(request: request, mirror: base)
        prunePreparedPlayback()
        guard preparedPlayback[key] == nil, preparationTasks[key] == nil else { return }
        // Limit speculative work during rapid episode/voice-over changes.
        guard preparationTasks.count < 2 else { return }
        let client = client
        let mirrors = mirrors
        let task = Task {
            var rebasedMedia = media
            rebasedMedia.pageURL = try await mirrors.rebased(media.pageURL, onto: base)
            // Speculation never changes the active mirror. Foreground playback
            // retains normal failover if this lightweight request fails.
            return try await RezkaStreamService(client: client).playback(
                request: request, media: rebasedMedia, baseURL: base, allowBrowser: false)
        }
        preparationTasks[key] = task
        defer { preparationTasks[key] = nil }
        guard let source = try? await task.value else { return }
        preparedPlayback[key] = PreparedPlayback(source: source, expiresAt: ContinuousClock.now.advanced(by: .seconds(45)))
        prunePreparedPlayback()
    }

    func invalidatePreparedPlayback(request: PlaybackRequest) {
        for key in Array(preparedPlayback.keys) where key.request == request {
            preparedPlayback[key] = nil
        }
    }

    private func prunePreparedPlayback() {
        let now = ContinuousClock.now
        preparedPlayback = preparedPlayback.filter { $0.value.expiresAt > now }
        while preparedPlayback.count > 4,
              let oldest = preparedPlayback.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            preparedPlayback[oldest] = nil
        }
    }

    private func resolvePlayback(request: PlaybackRequest, allowBrowser: Bool = true) async throws -> PlaybackSource {
        guard var item = cache[request.mediaID], item.rezka != nil else { throw ContentSourceError.missingMedia }
        if item.rezka?.translators.isEmpty == true { item = try await details(item: item) }
        guard let originalMedia = item.rezka else { throw ContentSourceError.missingMedia }
        let client = client
        let mirrors = mirrors
        return try await withMirror { base in
            var media = originalMedia
            media.pageURL = try await mirrors.rebased(media.pageURL, onto: base)
            return try await RezkaStreamService(client: client).playback(request: request, media: media, baseURL: base, allowBrowser: allowBrowser)
        }
    }

    func collections(page: Int = 1) async throws -> [RezkaCollection] {
        let base = try await mirrors.activeURL()
        let path = page > 1 ? "\(RezkaEndpoints.collections)page/\(page)/" : RezkaEndpoints.collections
        let (html, url) = try await fetchPage(base.appendingPathComponent(path))
        return try parser.collections(html: html, baseURL: url)
    }

    func person(url: URL) async throws -> RezkaPerson {
        let (html, resolvedURL) = try await fetchPage(url)
        let result = try parser.person(html: html, baseURL: resolvedURL)
        remember(result.filmography)
        return result
    }

    func comments(item: MediaItem, page: Int = 1) async throws -> RezkaCommentPage {
        guard let media = item.rezka else { return RezkaCommentPage(comments: [], pages: []) }
        let base = try await mirrors.activeURL()
        let url = try RezkaEndpoints.ajaxURL(path: RezkaEndpoints.comments, baseURL: base)
        let referer = try await mirrors.rebased(media.pageURL, onto: base)
        let response = try await client.fetch(client.request(url: url, referer: referer,
            form: ["news_id": media.movieID, "cstart": String(max(page, 1)), "type": "0", "comment_id": "0", "skin": "hdrezka"]))
        var html = try response.text()
        if let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] {
            if (json["success"] as? Bool) == false { throw RezkaError.server(json["message"] as? String ?? "Comments are unavailable.") }
            html = ((json["comments"] as? String) ?? (json["html"] as? String) ?? html) + ((json["navigation"] as? String) ?? "")
        }
        return try parser.comments(html: html, baseURL: base)
    }

    private func remember(_ items: [MediaItem]) {
        for item in items where cache[item.id]?.metadata == nil { cache[item.id] = item }
    }

    private func fetchPage(_ originalURL: URL) async throws -> (String, URL) {
        let client = client
        let mirrors = mirrors
        return try await withMirror { base in
            let url = try await mirrors.rebased(originalURL, onto: base)
            return try await client.html(url: url)
        }
    }

    private func withMirror<T: Sendable>(_ operation: @Sendable (URL) async throws -> T) async throws -> T {
        let base = try await mirrors.activeURL()
        do { return try await operation(base) }
        catch {
            try Task.checkCancellation()
            // Verification cancellations and site messages must remain visible to the user.
            if let error = error as? RezkaError {
                switch error {
                case .browserCancelled, .challengeRequired, .server, .invalidStream, .missingTranslator, .missingEpisode, .invalidPage: throw error
                case .httpStatus(let code) where code == 404 || code == 429: throw error
                default: break
                }
            }
            let replacement = try await mirrors.selectWorkingMirror(excluding: Set([base.host ?? ""]))
            return try await operation(replacement)
        }
    }
}
