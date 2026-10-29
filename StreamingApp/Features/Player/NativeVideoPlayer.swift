import AVKit
import Combine
import SwiftUI

struct NativeFullscreenPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let playbackDescription: String
    let onPresent: @MainActor () -> Void
    let onStop: @MainActor () -> Void
    let onClose: @MainActor () -> Void
    let onPlaybackStarted: @MainActor (AVPlayerItem) -> Void

    func makeUIViewController(context: Context) -> NativePlayerHost {
        let host = NativePlayerHost()
        host.configure(player: player, playbackDescription: playbackDescription,
                       onPresent: onPresent, onStop: onStop, onClose: onClose, onPlaybackStarted: onPlaybackStarted)
        return host
    }

    func updateUIViewController(_ host: NativePlayerHost, context: Context) {
        host.configure(player: player, playbackDescription: playbackDescription,
                       onPresent: onPresent, onStop: onStop, onClose: onClose, onPlaybackStarted: onPlaybackStarted)
    }

    static func dismantleUIViewController(_ host: NativePlayerHost, coordinator: ()) { host.tearDown() }
}

/// UIKit owns the player's full-screen bounds throughout orientation changes.
/// AVPlayerViewController is intentionally used directly, as required by AVKit.
final class NativePlayerHost: UIViewController, @preconcurrency AVPlayerViewControllerDelegate, UIAdaptivePresentationControllerDelegate {
    private let playback = AVPlayerViewController()
    private var didPresent = false
    private var isInPictureInPicture = false
    private var isClosing = false
    private var isTearingDown = false
    private var onPresent: (@MainActor () -> Void)?
    private var onStop: (@MainActor () -> Void)?
    private var onClose: (@MainActor () -> Void)?
    private var onPlaybackStarted: (@MainActor (AVPlayerItem) -> Void)?
    private var itemObservation: AnyCancellable?
    private var playbackObservation: AnyCancellable?
    private var displayObservation: AnyCancellable?
    private var bufferObservation: AnyCancellable?
    private var timeJumpObservation: AnyCancellable?
    private var hasRequestedPlayback = false
    private var didRequestLongBuffer = false
    private var didDeliverPlaybackStart = false
    private var didRequestImmediateStart = false
    private weak var bufferingItem: AVPlayerItem?
    private let bufferLabel = UILabel()
    private let bufferBadge = UIStackView()

    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    func configure(player: AVPlayer, playbackDescription: String, onPresent: @escaping @MainActor () -> Void,
                   onStop: @escaping @MainActor () -> Void, onClose: @escaping @MainActor () -> Void,
                   onPlaybackStarted: @escaping @MainActor (AVPlayerItem) -> Void) {
        if playback.player !== player {
            playback.player = player
            itemObservation = player.publisher(for: \.currentItem)
                .receive(on: RunLoop.main)
                .sink { [weak self] item in
                    MainActor.assumeIsolated {
                        guard let self, self.playback.player?.currentItem === item else { return }
                        self.updatePlaybackDescription(item)
                        self.observeBuffering(item)
                    }
                }
            playbackObservation = player.publisher(for: \.timeControlStatus)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.updatePauseBuffer() }
                }
        }
        self.onClose = onClose
        updatePlaybackDescription(player.currentItem, fallback: playbackDescription)
        self.onPresent = onPresent
        self.onStop = onStop
        self.onPlaybackStarted = onPlaybackStarted
    }

    private func updatePlaybackDescription(_ item: AVPlayerItem?, fallback: String? = nil) {
        let subtitle = item?.externalMetadata.first(where: { $0.identifier == .iTunesMetadataTrackSubTitle })?.stringValue
        let title = item?.externalMetadata.first(where: { $0.identifier == .commonIdentifierTitle })?.stringValue
        playback.view.accessibilityValue = subtitle ?? title ?? fallback
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        playback.modalPresentationStyle = .fullScreen
        playback.modalPresentationCapturesStatusBarAppearance = true
        playback.delegate = self
        playback.showsPlaybackControls = true
        playback.allowsPictureInPicturePlayback = true
        playback.canStartPictureInPictureAutomaticallyFromInline = true
        playback.exitsFullScreenWhenPlaybackEnds = false
        playback.loadViewIfNeeded()
        playback.view.accessibilityIdentifier = "native-player"
        displayObservation = playback.publisher(for: \.isReadyForDisplay)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePauseBuffer() }
            }
        installBufferBadge()
    }

    private func installBufferBadge() {
        guard let overlay = playback.contentOverlayView else { return }
        bufferLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        bufferLabel.textColor = .white
        bufferLabel.textAlignment = .center
        bufferLabel.numberOfLines = 2
        bufferLabel.accessibilityIdentifier = "paused-buffer-status"
        bufferBadge.addArrangedSubview(bufferLabel)
        bufferBadge.isLayoutMarginsRelativeArrangement = true
        bufferBadge.layoutMargins = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        bufferBadge.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        bufferBadge.layer.cornerRadius = 12
        bufferBadge.isUserInteractionEnabled = false
        bufferBadge.isHidden = true
        bufferBadge.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(bufferBadge)
        NSLayoutConstraint.activate([
            bufferBadge.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            bufferBadge.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 64),
            bufferBadge.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            bufferBadge.trailingAnchor.constraint(lessThanOrEqualTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -16)
        ])
        updatePauseBuffer()
    }

    private func observeBuffering(_ item: AVPlayerItem?) {
        guard bufferingItem !== item else { updatePauseBuffer(); return }
        bufferObservation = nil
        timeJumpObservation = nil
        bufferingItem = item
        hasRequestedPlayback = false
        didRequestLongBuffer = false
        didDeliverPlaybackStart = false
        didRequestImmediateStart = false
        guard let item else { updatePauseBuffer(); return }
        bufferObservation = item.publisher(for: \.loadedTimeRanges)
            .combineLatest(item.publisher(for: \.status))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePauseBuffer() }
            }
        timeJumpObservation = NotificationCenter.default.publisher(for: AVPlayerItem.timeJumpedNotification, object: item)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePauseBuffer() }
            }
        updatePauseBuffer()
    }

    private func updatePauseBuffer() {
        guard !isTearingDown, let player = playback.player, let item = player.currentItem else {
            bufferBadge.isHidden = true
            return
        }
        guard bufferingItem === item else { observeBuffering(item); return }
        if player.timeControlStatus != .paused { hasRequestedPlayback = true }
        let position = player.currentTime().seconds
        let duration = item.duration.seconds
        let ahead = PauseBufferPolicy.bufferedSecondsAhead(at: position, ranges: item.loadedTimeRanges.map(\.timeRangeValue))
        // Skip conservative startup prediction once a frame and one second of
        // data are ready. Keep automatic stall recovery enabled at all times.
        if !didDeliverPlaybackStart, !didRequestImmediateStart, playback.isReadyForDisplay,
           player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
           player.reasonForWaitingToPlay == .toMinimizeStalls, ahead >= 1 {
            didRequestImmediateStart = true
            player.playImmediately(atRate: player.defaultRate)
        }
        if !didDeliverPlaybackStart, player.timeControlStatus == .playing, playback.isReadyForDisplay {
            didDeliverPlaybackStart = true
            onPlaybackStarted?(item)
        }
        let hasEnded = duration.isFinite && duration > 0 && position >= duration
        let paused = hasRequestedPlayback && player.timeControlStatus == .paused && item.status == .readyToPlay && !hasEnded
        // Startup uses a small target. Once the user pauses, retain the
        // larger target for this episode so resuming does not shrink the reserve.
        if paused { didRequestLongBuffer = true }
        let preferred = didRequestLongBuffer ? PauseBufferPolicy.requestedSeconds(at: position, duration: duration)
            : (didDeliverPlaybackStart ? 0 : PlaybackStartupPolicy.initialBufferSeconds)
        if item.preferredForwardBufferDuration != preferred { item.preferredForwardBufferDuration = preferred }
        bufferBadge.isHidden = !paused
        guard paused else { return }
        let seconds = Int(min(ahead, Double(Int.max / 2)))
        let target = Int(preferred)
        bufferLabel.text = String(format: "Завантажено наперед: %d:%02d · ціль %d:%02d", seconds / 60, seconds % 60, target / 60, target % 60)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if didPresent {
            closeIfDismissed()
            return
        }
        guard !isTearingDown else { return }
        didPresent = true
        present(playback, animated: false) { [weak self] in self?.onPresent?() }
        playback.presentationController?.delegate = self
    }

    private func closeIfDismissed() {
        guard didPresent, !isInPictureInPicture, !isTearingDown, !isClosing,
              playback.presentingViewController == nil else { return }
        isClosing = true
        onClose?()
    }

    func playerViewController(_ playerViewController: AVPlayerViewController,
                              willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator) {
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard !context.isCancelled else { return }
            self?.closeIfDismissed()
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { closeIfDismissed() }

    func tearDown() {
        isTearingDown = true
        onStop?()
        onStop = nil
        onClose = nil
        onPresent = nil
        onPlaybackStarted = nil
        itemObservation = nil
        playbackObservation = nil
        displayObservation = nil
        bufferObservation = nil
        timeJumpObservation = nil
        playback.delegate = nil
        playback.player = nil
        playback.dismiss(animated: false)
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) { isInPictureInPicture = true }
    func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool { false }
    func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: any Error) { isInPictureInPicture = false }
    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) { isInPictureInPicture = false }
    func playerViewController(_ playerViewController: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        if playback.presentingViewController == nil {
            present(playback, animated: true) { completionHandler(true) }
        } else { completionHandler(true) }
    }
}

enum PauseBufferPolicy {
    static let targetSeconds: TimeInterval = 10 * 60

    static func requestedSeconds(at position: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard position.isFinite, position >= 0, duration.isFinite, duration > 0 else { return targetSeconds }
        return min(targetSeconds, max(0, duration - position))
    }

    /// Only count continuous playable data from the current position, not
    /// disconnected ranges left over after seeking to a different scene.
    static func bufferedSecondsAhead(at position: TimeInterval, ranges: [CMTimeRange]) -> TimeInterval {
        guard position.isFinite, position >= 0 else { return 0 }
        let intervals = ranges.compactMap { range -> (start: Double, end: Double)? in
            let start = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            guard start.isFinite, end.isFinite, end >= start else { return nil }
            return (start, end)
        }.sorted { $0.start < $1.start }
        var end = position
        for interval in intervals {
            if interval.end <= end { continue }
            guard interval.start <= end + 0.05 else { break }
            end = interval.end
        }
        return max(0, end - position)
    }
}
