import Foundation

struct DemoContentSource: ContentSource {
    static let items: [MediaItem] = [
        MediaItem(
            id: "last-horizon", title: "The Last Horizon", originalTitle: nil, year: 2026,
            kind: .movie, genre: "Science fiction", synopsis: "A quiet signal from beyond the edge of the solar system sends one crew on a journey that changes everything they know about home.", durationMinutes: 118, symbol: "sparkles", paletteIndex: 0, streamURL: nil
        ),
        MediaItem(
            id: "glass-city", title: "Glass City", originalTitle: nil, year: 2025,
            kind: .series, genre: "Mystery", synopsis: "A new archivist uncovers a hidden history in a city where every family keeps a different version of the past.", durationMinutes: nil, symbol: "building.2.fill", paletteIndex: 1, streamURL: nil
        ),
        MediaItem(
            id: "wild-ember", title: "Wild Ember", originalTitle: nil, year: 2024,
            kind: .movie, genre: "Adventure", synopsis: "Two estranged siblings return to the mountain town where their story began, just as a forest fire changes the landscape around them.", durationMinutes: 104, symbol: "mountain.2.fill", paletteIndex: 2, streamURL: nil
        ),
        MediaItem(
            id: "blue-hour", title: "Blue Hour", originalTitle: nil, year: 2025,
            kind: .series, genre: "Drama", synopsis: "Over one summer, a group of friends discover that growing up does not have to mean growing apart.", durationMinutes: nil, symbol: "moon.stars.fill", paletteIndex: 3, streamURL: nil
        ),
        MediaItem(
            id: "paper-kingdom", title: "Paper Kingdom", originalTitle: nil, year: 2023,
            kind: .animation, genre: "Family", synopsis: "A curious inventor finds a tiny world hidden inside the pages of an old book and sets out to help it find a new home.", durationMinutes: 92, symbol: "book.closed.fill", paletteIndex: 4, streamURL: nil
        ),
        MediaItem(
            id: "northbound", title: "Northbound", originalTitle: nil, year: 2024,
            kind: .movie, genre: "Thriller", synopsis: "A late-night train ride takes an unexpected turn when a passenger notices a detail no one else can see.", durationMinutes: 111, symbol: "tram.fill", paletteIndex: 5, streamURL: nil
        ),
        MediaItem(
            id: "small-worlds", title: "Small Worlds", originalTitle: nil, year: 2025,
            kind: .anime, genre: "Adventure", synopsis: "A young cartographer draws maps of places that appear only for a few minutes at a time.", durationMinutes: nil, symbol: "globe.europe.africa.fill", paletteIndex: 6, streamURL: nil
        ),
        MediaItem(
            id: "deep-current", title: "Deep Current", originalTitle: nil, year: 2022,
            kind: .series, genre: "Documentary", synopsis: "A research team follows the path of a single ocean current and the lives connected to it.", durationMinutes: nil, symbol: "water.waves", paletteIndex: 7, streamURL: nil
        )
    ]

    func home() async throws -> [MediaItem] { Self.items }

    func search(query: String, page: Int) async throws -> [MediaItem] {
        guard !query.isEmpty else { return Self.items }
        return Self.items.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.genre.localizedCaseInsensitiveContains(query)
        }
    }

    func details(item: MediaItem) async throws -> MediaItem {
        guard let item = Self.items.first(where: { $0.id == item.id }) else {
            throw ContentSourceError.missingMedia
        }
        return item
    }

    func playback(request: PlaybackRequest) async throws -> PlaybackSource {
        throw ContentSourceError.unavailable
    }

    func episodes(item: MediaItem, translatorID: String) async throws -> [RezkaSeason] { [] }
}
