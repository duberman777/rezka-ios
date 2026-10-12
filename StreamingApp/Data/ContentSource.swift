import Foundation

protocol ContentSource: Sendable {
    func home() async throws -> [MediaItem]
    func search(query: String, page: Int) async throws -> [MediaItem]
    func details(item: MediaItem) async throws -> MediaItem
    func episodes(item: MediaItem, translatorID: String) async throws -> [RezkaSeason]
    func playback(request: PlaybackRequest) async throws -> PlaybackSource
}
