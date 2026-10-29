import Foundation

enum MediaKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case movie
    case series
    case animation
    case anime

    var id: String { rawValue }

    var cataloguePath: String {
        switch self {
        case .movie: "films/"
        case .series: "series/"
        case .animation: "cartoons/"
        case .anime: "animation/"
        }
    }

    var title: String {
        switch self {
        case .movie: "Movie"
        case .series: "Series"
        case .animation: "Animation"
        case .anime: "Anime"
        }
    }
}

struct MediaItem: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var originalTitle: String?
    var year: Int?
    var kind: MediaKind
    var genre: String
    var synopsis: String
    var durationMinutes: Int?
    var symbol: String
    var paletteIndex: Int
    var streamURL: URL?
    var posterURL: URL?
    var previewPosterURL: URL? = nil
    var rezka: RezkaMedia?
    var metadata: RezkaMetadata?
    var countryCodes: [String]?

    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct WatchRecord: Identifiable, Codable, Hashable, Sendable {
    var id: String { item.id }
    var item: MediaItem
    var position: TimeInterval
    var duration: TimeInterval
    var updatedAt: Date
    var translatorID: String?
    var seasonID: String?
    var episodeID: String?

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    var remainingMinutes: Int? {
        guard duration > 0 else { return nil }
        return max(Int((duration - position) / 60), 0)
    }

    var positionLabel: String {
        guard position.isFinite, position > 0 else { return "0:00" }
        let seconds = Int(min(position, Double(Int.max / 2)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func resumePosition(for request: PlaybackRequest?) -> TimeInterval? {
        guard position.isFinite, position > 0, seasonID == request?.season, episodeID == request?.episode else { return nil }
        return position
    }
}

struct PlaybackRequest: Hashable, Sendable {
    var mediaID: String
    var translatorID: String? = nil
    var season: String? = nil
    var episode: String? = nil
    var pageURL: URL? = nil
}

struct VideoStream: Hashable, Sendable {
    var quality: String
    var url: URL
    var alternatives: [URL] = []
    var isPremium: Bool = false

    var resolution: Int {
        Int(quality.prefix(while: { $0.isNumber })) ?? 0
    }
}

struct SubtitleTrack: Hashable, Sendable {
    var language: String
    var label: String
    var url: URL
}

struct PlaybackSource: Sendable {
    var streams: [VideoStream]
    var subtitles: [SubtitleTrack]
    var defaultSubtitle: String? = nil
    var headers: [String: String] = [:]
}

enum ContentSourceError: Error {
    case unavailable
    case missingMedia
}

// Saved records can come from other app versions, where some fields are absent or shaped differently.
extension MediaItem {
    private enum CodingKeys: String, CodingKey {
        case id, title, originalTitle, year, kind, genre, synopsis, durationMinutes, symbol, paletteIndex
        case streamURL, posterURL, previewPosterURL, rezka, metadata, countryCodes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        originalTitle = try? container.decodeIfPresent(String.self, forKey: .originalTitle)
        year = try? container.decodeIfPresent(Int.self, forKey: .year)
        kind = try container.decode(MediaKind.self, forKey: .kind)
        genre = (try? container.decodeIfPresent(String.self, forKey: .genre)) ?? ""
        synopsis = (try? container.decodeIfPresent(String.self, forKey: .synopsis)) ?? ""
        durationMinutes = (try? container.decodeIfPresent(Double.self, forKey: .durationMinutes)).flatMap { $0.map(Int.init) }
        symbol = (try? container.decodeIfPresent(String.self, forKey: .symbol)) ?? (kind == .series ? "tv" : "film")
        paletteIndex = (try? container.decodeIfPresent(Int.self, forKey: .paletteIndex)) ?? 0
        streamURL = try? container.decodeIfPresent(URL.self, forKey: .streamURL)
        posterURL = try? container.decodeIfPresent(URL.self, forKey: .posterURL)
        previewPosterURL = try? container.decodeIfPresent(URL.self, forKey: .previewPosterURL)
        rezka = try? container.decodeIfPresent(RezkaMedia.self, forKey: .rezka)
        metadata = try? container.decodeIfPresent(RezkaMetadata.self, forKey: .metadata)
        countryCodes = try? container.decodeIfPresent([String].self, forKey: .countryCodes)
    }
}

/// Decodes the readable elements of an array and skips the rest.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    private struct Skip: Decodable {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) { elements.append(element) }
            else { _ = try? container.decode(Skip.self) }
        }
        self.elements = elements
    }
}
