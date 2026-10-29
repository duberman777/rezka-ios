import Foundation
#if DEBUG && canImport(AVFoundation)
import AVFoundation
#endif

struct RezkaAjaxResponse: Decodable, Sendable {
    var success: Bool
    var message: String?
    var seasons: String
    var episodes: String
    var url: String
    var subtitle: String
    var subtitleLanguages: [String: String]
    var defaultSubtitle: String?

    private enum CodingKeys: String, CodingKey {
        case success, message, seasons, episodes, url, subtitle
        case subtitleLanguages = "subtitle_lns"
        case defaultSubtitle = "subtitle_def"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let flag = try? container.decode(Bool.self, forKey: .success) { success = flag }
        else if let flag = try? container.decode(Int.self, forKey: .success) { success = flag == 1 }
        else { success = ["true", "1"].contains((try? container.decode(String.self, forKey: .success)) ?? "") }
        message = try? container.decode(String.self, forKey: .message)
        seasons = (try? container.decode(String.self, forKey: .seasons)) ?? ""
        episodes = (try? container.decode(String.self, forKey: .episodes)) ?? ""
        url = (try? container.decode(String.self, forKey: .url)) ?? ""
        subtitle = (try? container.decode(String.self, forKey: .subtitle)) ?? ""
        subtitleLanguages = (try? container.decode([String: String].self, forKey: .subtitleLanguages)) ?? [:]
        defaultSubtitle = (try? container.decode(String.self, forKey: .defaultSubtitle))
            ?? (try? container.decode(Int.self, forKey: .defaultSubtitle)).map(String.init)
        if defaultSubtitle == "0" || defaultSubtitle == "" { defaultSubtitle = nil }
    }

    static func parse(_ response: RezkaHTTPResponse) throws -> Self {
        let result: Self
        do { result = try JSONDecoder().decode(Self.self, from: response.data) }
        catch { throw RezkaError.invalidPage("Rezka returned an unexpected playback response. Try again shortly.") }
        guard result.success else { throw RezkaError.server(result.message?.nonEmpty ?? "This title is unavailable from Rezka.") }
        return result
    }
}

struct RezkaEpisodeService: Sendable {
    let client: RezkaHttpClient
    let parser = RezkaPageParser()

    func episodes(movieID: String, translatorID: String, pageURL: URL, baseURL: URL) async throws -> [RezkaSeason] {
        let url = try RezkaEndpoints.ajaxURL(path: RezkaEndpoints.player, baseURL: baseURL)
        let form = ["id": movieID, "translator_id": translatorID, "action": "get_episodes"]
        let response = try RezkaAjaxResponse.parse(await client.fetch(client.request(url: url, referer: pageURL, form: form)))
        let seasons = try parser.episodeList(seasonsHTML: response.seasons, episodesHTML: response.episodes, baseURL: baseURL)
        guard !seasons.isEmpty, seasons.contains(where: { !$0.episodes.isEmpty }) else {
            throw RezkaError.invalidPage("No episodes are available for this translation.")
        }
        return seasons
    }
}

struct RezkaStreamService: Sendable {
    let client: RezkaHttpClient
    let decoder = RezkaStreamDecoder()

    func playback(request: PlaybackRequest, media: RezkaMedia, baseURL: URL, allowBrowser: Bool = true) async throws -> PlaybackSource {
        let translators = media.playableTranslators
        guard let translatorID = request.translatorID ?? translators.first(where: \.isSelected)?.id ?? translators.first?.id,
              !media.translators.contains(where: { $0.id == translatorID && $0.isPremium }) else {
            throw RezkaError.missingTranslator
        }
        if media.isSeries, (request.season == nil || request.episode == nil) { throw RezkaError.missingEpisode }
        let url = try RezkaEndpoints.ajaxURL(path: RezkaEndpoints.player, baseURL: baseURL)
        // APK fb.v defaults film season and episode to one and chooses get_movie for films.
        let form = ["id": media.movieID, "translator_id": translatorID,
                    "season": request.season ?? "1", "episode": request.episode ?? "1",
                    "action": media.isSeries ? "get_stream" : "get_movie"]
        #if DEBUG
        if let data = try? JSONSerialization.data(withJSONObject: ["fields": form, "page": media.pageURL.absoluteString,
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                "timestamp": Date().timeIntervalSince1970]) {
            RezkaPlaybackDiagnostics.save(data, name: "playback-request.json")
        }
        #endif
        var httpRequest = client.request(url: url, referer: media.pageURL, form: form)
        // Speculative preparation must yield quickly on slow connections and
        // must never present a browser verification screen before Play is tapped.
        if !allowBrowser { httpRequest.timeoutInterval = 8 }
        let httpResponse = try await client.fetch(httpRequest, allowBrowser: allowBrowser)
        #if DEBUG
        RezkaPlaybackDiagnostics.save(httpResponse.data, name: "playback-response.json")
        #endif
        let response = try RezkaAjaxResponse.parse(httpResponse)
        return PlaybackSource(streams: try decoder.streams(response.url),
            subtitles: try decoder.subtitles(response.subtitle, languages: response.subtitleLanguages),
            defaultSubtitle: response.defaultSubtitle,
            headers: ["Referer": media.pageURL.absoluteString, "User-Agent": RezkaHttpClient.userAgent])
    }
}

#if DEBUG
enum RezkaPlaybackDiagnostics {
    static func save(_ data: Data, name: String) {
        guard let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let path = folder.appendingPathComponent("RezkaDiagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try? data.write(to: path.appendingPathComponent(name), options: [.atomic])
    }

    @MainActor static func probe(source: RezkaContentSource) async {
        do {
            let query = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--rezka-probe-title=") })?.components(separatedBy: "=").dropFirst().joined(separator: "=")
            let items: [MediaItem]
            if let query { items = try await source.search(query: query, page: 1) }
            else { items = try await source.catalogue(page: 1).items }
            guard let first = query == nil ? items.first : items.sorted(by: { ($0.year ?? 0) > ($1.year ?? 0) }).first else { throw ContentSourceError.missingMedia }
            let item = try await source.details(item: first)
            guard let media = item.rezka, let translator = media.playableTranslators.first(where: \.isSelected) ?? media.playableTranslators.first else {
                throw RezkaError.missingTranslator
            }
            var request = PlaybackRequest(mediaID: item.id, translatorID: translator.id)
            if media.isSeries {
                let seasons = try await source.episodes(item: item, translatorID: translator.id)
                request.season = seasons.first?.id
                request.episode = seasons.first?.episodes.first?.id
            }
            let result = try await source.playback(request: request)
            var report: [String: Any] = ["success": true, "title": item.title, "id": item.id,
                "qualities": result.streams.map(\.quality), "translatorID": translator.id,
                "premiumTranslators": media.translators.filter(\.isPremium).map(\.id),
                "availableTranslators": media.playableTranslators.map(\.id)]
            #if canImport(AVFoundation)
            if let stream = result.streams.first {
                let asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": result.headers])
                let timeout = Task {
                    try await Task.sleep(for: .seconds(20))
                    asset.cancelLoading()
                }
                defer { timeout.cancel() }
                report["isPlayable"] = try await asset.load(.isPlayable)
                let duration = try await asset.load(.duration).seconds
                if duration.isFinite { report["durationSeconds"] = duration }
            }
            #endif
            let data = try JSONSerialization.data(withJSONObject: report)
            save(data, name: "probe-result.json")
        } catch {
            if let data = try? JSONSerialization.data(withJSONObject: ["success": false, "error": error.localizedDescription]) {
                save(data, name: "probe-result.json")
            }
        }
    }
}
#endif
