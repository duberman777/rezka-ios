import AVKit
import Combine
import SwiftUI

struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVPlayer
    @State private var selectedQuality: String
    @State private var alternativeIndex = 0
    @State private var pendingSeek: TimeInterval?
    @State private var isRestoringPosition = false
    @State private var hasStarted = false
    @State private var lifecycle = PlaybackLifecycle()
    @State private var itemObservation: AnyCancellable?
    @State private var readyTask: Task<Void, Never>?
    @State private var autoplayTask: Task<Void, Never>?
    @State private var source: PlaybackSource
    @State private var request: PlaybackRequest?
    @State private var isFinished = false
    @State private var isLoadingNext = false

    let item: MediaItem
    let seasons: [RezkaSeason]
    let onFailure: @MainActor (String) -> Void

    init(item: MediaItem, source: PlaybackSource, preferredQuality: String, request: PlaybackRequest? = nil, seasons: [RezkaSeason] = [], onFailure: @escaping @MainActor (String) -> Void = { _ in }) {
        self.item = item
        self.seasons = seasons
        self.onFailure = onFailure
        _source = State(initialValue: source)
        _request = State(initialValue: request)
        let stream = source.streams.first(where: { $0.quality == preferredQuality }) ?? source.streams[0]
        _selectedQuality = State(initialValue: stream.quality)
        _player = State(initialValue: AVPlayer(playerItem: Self.playerItem(url: stream.url, headers: source.headers, title: item.title, request: request)))
    }

    var body: some View {
        NativeFullscreenPlayer(player: player, playbackDescription: playbackDescription, onPresent: startPlayback,
                               onStop: stopPlayback,
                               onClose: { saveAndStop(); dismiss() })
            .ignoresSafeArea()
            .background(Color.black.ignoresSafeArea())
            .statusBarHidden()
            .onChange(of: scenePhase) { if scenePhase != .active { saveProgress() } }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                saveProgress()
            }
            .onReceive(player.publisher(for: \.timeControlStatus)) { status in
                if status == .paused { saveProgress() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
                guard notification.object as? AVPlayerItem === player.currentItem else { return }
                finishEpisode()
            }
    }

    private var playbackDescription: String {
        guard let season = request?.season, let episode = request?.episode else { return item.title }
        return "Season \(season), episode \(episode)"
    }

    private var nextRequest: PlaybackRequest? {
        request.flatMap { RezkaSeason.nextRequest(after: $0, in: seasons) }
    }

    private func finishEpisode() {
        guard !isFinished else { return }
        saveProgress()
        isFinished = true
        if let next = nextRequest {
            model.recordProgress(for: item, position: 0, duration: 0, request: next)
            if model.autoPlayNext {
                autoplayTask?.cancel()
                autoplayTask = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    await changeEpisode(to: next)
                }
            }
        }
    }

    private func changeEpisode(to selection: PlaybackRequest) async {
        guard !isLoadingNext else { return }
        isLoadingNext = true
        defer { isLoadingNext = false }
        do {
            let result = try await model.contentSource.playback(request: selection)
            try Task.checkCancellation()
            request = selection
            source = result
            isFinished = false
            let stream = result.streams.first(where: { $0.quality == selectedQuality }) ?? result.streams[0]
            selectedQuality = stream.quality
            alternativeIndex = 0
            pendingSeek = 0
            isRestoringPosition = true
            player.replaceCurrentItem(with: Self.playerItem(url: stream.url, headers: result.headers, title: item.title, request: selection))
            model.recordProgress(for: item, position: 0, duration: 0, request: selection)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--rezka-ui-fixtures") {
                player.play()
                return
            }
            #endif
            observeCurrentItem()
            // Wait for the seek to finish before advancing the new episode.
        } catch is CancellationError { }
        catch { failPlayback(error.localizedDescription) }
    }

    private func startPlayback() {
        guard !hasStarted else { return }
        hasStarted = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--rezka-ui-fixtures") {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            if ProcessInfo.processInfo.arguments.contains("--rezka-ui-finished-episode") { finishEpisode() }
            else { player.play() }
            return
        }
        #endif
        let record: WatchRecord?
        if let season = request?.season, let episode = request?.episode {
            record = model.episodeRecord(mediaID: item.id, season: season, episode: episode)
        } else { record = model.history.first(where: { $0.item.id == item.id }) }
        pendingSeek = record.flatMap { $0.progress < 1.0 ? $0.resumePosition(for: request) : nil }
        isRestoringPosition = pendingSeek != nil
        model.recordStart(item)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { failPlayback("Audio playback could not be started."); return }
        player.allowsExternalPlayback = true
        observeCurrentItem()
        lifecycle.progressObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { _ in
            MainActor.assumeIsolated { saveProgress() }
        }
        if pendingSeek == nil { player.play() }
    }

    private func observeCurrentItem() {
        readyTask?.cancel()
        readyTask = nil
        itemObservation?.cancel()
        guard let currentItem = player.currentItem else { return }
        // Keep a synchronous subscription: AsyncPublisher can miss a status
        // change while its consumer is suspended (for example during a seek).
        itemObservation = currentItem.publisher(for: \.status)
            .receive(on: RunLoop.main)
            .sink { _ in
                MainActor.assumeIsolated { handleItemStatus(currentItem) }
            }
        handleItemStatus(currentItem)
    }

    private func handleItemStatus(_ currentItem: AVPlayerItem) {
        guard !lifecycle.isStopped, player.currentItem === currentItem else { return }
        if currentItem.status == .failed { useAlternative(); return }
        guard currentItem.status == .readyToPlay, let position = pendingSeek, readyTask == nil else { return }
        readyTask = Task { @MainActor in
            let restored = await player.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                                             toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled, !lifecycle.isStopped, player.currentItem === currentItem else { return }
            readyTask = nil
            guard restored else {
                // Retain the saved point if AVPlayer interrupts the seek.
                useAlternative()
                return
            }
            pendingSeek = nil
            isRestoringPosition = false
            player.playImmediately(atRate: player.defaultRate)
        }
    }

    private var canSaveProgress: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--rezka-ui-fixtures") { return false }
        #endif
        return hasStarted && !isRestoringPosition && !isFinished
    }

    private func saveProgress() {
        guard canSaveProgress, !lifecycle.isStopped else { return }
        model.recordProgress(for: item, position: player.currentTime().seconds,
                             duration: player.currentItem?.duration.seconds ?? 0, request: request)
    }

    private func saveAndStop() {
        saveProgress()
        stopPlayback()
    }

    private func stopPlayback() {
        guard lifecycle.stop(player: player) else { return }
        // Capture before AVKit releases the item. Defer the model write until
        // after SwiftUI dismantles the host, without reading player state later.
        if canSaveProgress {
            let position = player.currentTime().seconds
            let duration = player.currentItem?.duration.seconds ?? 0
            let stoppedRequest = request
            let stoppedItem = item
            let recordedAt = Date.now
            let savedModel = model
            Task { @MainActor in
                savedModel.recordProgress(for: stoppedItem, position: position, duration: duration,
                                          request: stoppedRequest, recordedAt: recordedAt)
            }
        }
        itemObservation?.cancel()
        readyTask?.cancel()
        autoplayTask?.cancel()
        player.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func replaceURL(_ url: URL) {
        let position = player.currentTime().seconds
        // A failed stream may still report zero during the initial restore.
        // Never replace the original saved point with that temporary value.
        if !isRestoringPosition, position.isFinite, position > 0 {
            pendingSeek = position
            isRestoringPosition = true
        }
        player.pause()
        player.replaceCurrentItem(with: Self.playerItem(url: url, headers: source.headers, title: item.title, request: request))
        observeCurrentItem()
        if pendingSeek == nil { player.playImmediately(atRate: player.defaultRate) }
    }

    private func useAlternative() {
        guard let stream = source.streams.first(where: { $0.quality == selectedQuality }), alternativeIndex < stream.alternatives.count else {
            failPlayback("This video could not be played. Choose another quality on the title page or try again.")
            return
        }
        let url = stream.alternatives[alternativeIndex]
        alternativeIndex += 1
        replaceURL(url)
    }

    private func failPlayback(_ message: String) {
        saveAndStop()
        onFailure(message)
        dismiss()
    }

    private static func playerItem(url: URL, headers: [String: String], title: String, request: PlaybackRequest?) -> AVPlayerItem {
        var playbackURL = url
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--rezka-ui-fixtures"),
           let fixture = Bundle.main.url(forResource: "NativePlayerFixture", withExtension: "mp4") {
            playbackURL = fixture
        }
        #endif
        let asset = AVURLAsset(url: playbackURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        let name = AVMutableMetadataItem()
        name.identifier = .commonIdentifierTitle
        name.value = title as NSString
        item.externalMetadata = [name]
        if let season = request?.season, let episode = request?.episode {
            let subtitle = AVMutableMetadataItem()
            subtitle.identifier = .iTunesMetadataTrackSubTitle
            subtitle.value = "Season \(season), episode \(episode)" as NSString
            item.externalMetadata.append(subtitle)
        }
        return item
    }
}

/// Reference storage allows idempotent cleanup during SwiftUI dismantling
/// without mutating @State or an observable model inside that callback.
@MainActor
final class PlaybackLifecycle {
    var progressObserver: Any?
    private(set) var isStopped = false

    @discardableResult
    func stop(player: AVPlayer) -> Bool {
        guard !isStopped else { return false }
        isStopped = true
        if let progressObserver {
            player.removeTimeObserver(progressObserver)
            self.progressObserver = nil
        }
        return true
    }
}
