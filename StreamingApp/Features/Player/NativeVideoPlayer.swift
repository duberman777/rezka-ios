import AVKit
import Combine
import SwiftUI

struct NativeFullscreenPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let playbackDescription: String
    let onPresent: @MainActor () -> Void
    let onStop: @MainActor () -> Void
    let onClose: @MainActor () -> Void

    func makeUIViewController(context: Context) -> NativePlayerHost {
        let host = NativePlayerHost()
        host.configure(player: player, playbackDescription: playbackDescription,
                       onPresent: onPresent, onStop: onStop, onClose: onClose)
        return host
    }

    func updateUIViewController(_ host: NativePlayerHost, context: Context) {
        host.configure(player: player, playbackDescription: playbackDescription,
                       onPresent: onPresent, onStop: onStop, onClose: onClose)
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
    private var itemObservation: AnyCancellable?

    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    func configure(player: AVPlayer, playbackDescription: String, onPresent: @escaping @MainActor () -> Void,
                   onStop: @escaping @MainActor () -> Void, onClose: @escaping @MainActor () -> Void) {
        if playback.player !== player {
            playback.player = player
            itemObservation = player.publisher(for: \.currentItem).sink { [weak self] item in
                self?.updatePlaybackDescription(item)
            }
        }
        self.onClose = onClose
        updatePlaybackDescription(player.currentItem, fallback: playbackDescription)
        self.onPresent = onPresent
        self.onStop = onStop
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
        itemObservation = nil
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
