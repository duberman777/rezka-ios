import Foundation

struct RezkaMedia: Codable, Hashable, Sendable {
    var movieID: String
    var pageURL: URL
    var isSeries: Bool
    var translators: [RezkaTranslator] = []
    var seasons: [RezkaSeason] = []
    var playerFlags: [String: String] = [:]

    var playableTranslators: [RezkaTranslator] { translators.filter { !$0.isPremium } }
}

struct RezkaTranslator: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String?
    var isPremium: Bool = false
    var isSelected: Bool = false
    var flags: [String: String] = [:]
}

struct RezkaSeason: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var episodes: [RezkaEpisode]

    static func nextRequest(after request: PlaybackRequest, in seasons: [RezkaSeason]) -> PlaybackRequest? {
        let episodes = seasons.flatMap { season in season.episodes.map { (season.id, $0.id) } }
        guard let index = episodes.firstIndex(where: { $0.0 == request.season && $0.1 == request.episode }),
              index + 1 < episodes.count else { return nil }
        var next = request
        next.season = episodes[index + 1].0
        next.episode = episodes[index + 1].1
        return next
    }
}

struct RezkaEpisode: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var seasonID: String
}

struct RezkaLink: Identifiable, Codable, Hashable, Sendable {
    var id: String { url.absoluteString }
    var name: String
    var url: URL
    var imageURL: URL? = nil
}

struct RezkaRating: Codable, Hashable, Sendable {
    var value: String
    var url: URL?
}

struct RezkaFranchiseItem: Identifiable, Codable, Hashable, Sendable {
    var id: String { url.absoluteString }
    var title: String
    var url: URL
    var year: String
    var rating: String
}

struct RezkaSchedule: Codable, Hashable, Sendable {
    var title: String
    var rows: [Row]

    struct Row: Codable, Hashable, Sendable {
        var episode: String
        var title: String
        var date: String
    }
}

struct RezkaMetadata: Codable, Hashable, Sendable {
    var rating: String?
    var imdb: RezkaRating?
    var kinopoisk: RezkaRating?
    var directors: [RezkaLink] = []
    var actors: [RezkaLink] = []
    var genres: [String] = []
    var information: [String: String] = [:]
    var rankings: [RezkaLink] = []
    var collections: [RezkaLink] = []
    var franchiseTitle: String?
    var franchise: [RezkaFranchiseItem] = []
    var schedule: [RezkaSchedule] = []
}

struct RezkaCollection: Identifiable, Sendable {
    var id: String { url.absoluteString }
    var title: String
    var url: URL
    var imageURL: URL?
    var count: String
}

struct RezkaComment: Identifiable, Sendable {
    var id: String
    var parentID: String?
    var indent: Int
    var author: String
    var date: String
    var text: String
    var likes: String
    var avatarURL: URL?
}

struct RezkaCommentPage: Sendable {
    var comments: [RezkaComment]
    var pages: [RezkaLink]
}

struct RezkaPerson: Sendable {
    var name: String
    var originalName: String
    var imageURL: URL?
    var birthDate: String
    var jobs: [String]
    var careers: [RezkaLink]
    var filmography: [MediaItem]
}

struct RezkaCataloguePage: Sendable {
    var items: [MediaItem]
    var hasNextPage: Bool
    var categories: [RezkaCategory] = []
}

struct RezkaCategory: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    var title: String
    var url: URL
    var kind: MediaKind
}

enum RezkaError: LocalizedError {
    case noWorkingMirror
    case invalidURL
    case httpStatus(Int)
    case challengeRequired
    case browserCancelled
    case invalidPage(String)
    case server(String)
    case invalidStream
    case missingTranslator
    case missingEpisode
    case unsupportedEncoding

    var errorDescription: String? {
        switch self {
        case .noWorkingMirror: "No Rezka mirror could be reached. Try again or choose a mirror in Settings."
        case .invalidURL: "This Rezka link is invalid."
        case .httpStatus(let code): "Rezka returned an error with code \(code). Try again shortly."
        case .challengeRequired: "Complete the website verification to continue."
        case .browserCancelled: "Website verification was cancelled. Try again when you are ready."
        case .invalidPage(let message), .server(let message): message
        case .invalidStream: "Rezka did not return a supported video stream."
        case .missingTranslator: "No translation is available for this title."
        case .missingEpisode: "Choose a season and episode before playing."
        case .unsupportedEncoding: "The website response could not be read."
        }
    }
}

extension RezkaMedia {
    private enum CodingKeys: String, CodingKey { case movieID, pageURL, isSeries, translators, seasons, playerFlags }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        movieID = try container.decode(String.self, forKey: .movieID)
        pageURL = try container.decode(URL.self, forKey: .pageURL)
        isSeries = (try? container.decodeIfPresent(Bool.self, forKey: .isSeries)) ?? false
        translators = (try? container.decodeIfPresent(LossyArray<RezkaTranslator>.self, forKey: .translators))?.elements ?? []
        seasons = (try? container.decodeIfPresent(LossyArray<RezkaSeason>.self, forKey: .seasons))?.elements ?? []
        playerFlags = (try? container.decodeIfPresent([String: String].self, forKey: .playerFlags)) ?? [:]
    }
}

extension RezkaTranslator {
    private enum CodingKeys: String, CodingKey { case id, name, description, isPremium, isSelected, flags }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try? container.decodeIfPresent(String.self, forKey: .description)
        isPremium = (try? container.decodeIfPresent(Bool.self, forKey: .isPremium)) ?? false
        isSelected = (try? container.decodeIfPresent(Bool.self, forKey: .isSelected)) ?? false
        flags = (try? container.decodeIfPresent([String: String].self, forKey: .flags)) ?? [:]
    }
}
