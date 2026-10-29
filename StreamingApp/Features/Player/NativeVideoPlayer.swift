import AVKit
import Combine
import Observation
import SwiftUI
import WebKit

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
    private var playbackObservation: AnyCancellable?
    private var bufferObservation: AnyCancellable?
    private var timeJumpObservation: AnyCancellable?
    private var hasRequestedPlayback = false
    private var didRequestLongBuffer = false
    private weak var bufferingItem: AVPlayerItem?
    private let bufferLabel = UILabel()
    private let bufferBadge = UIStackView()

    override var shouldAutorotate: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    func configure(player: AVPlayer, playbackDescription: String, onPresent: @escaping @MainActor () -> Void,
                   onStop: @escaping @MainActor () -> Void, onClose: @escaping @MainActor () -> Void) {
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
        let hasEnded = duration.isFinite && duration > 0 && position >= duration
        let paused = hasRequestedPlayback && player.timeControlStatus == .paused && item.status == .readyToPlay && !hasEnded
        // Initial startup remains automatic. Once the user pauses, retain the
        // larger target for this episode so resuming does not shrink the reserve.
        if paused { didRequestLongBuffer = true }
        let preferred = didRequestLongBuffer ? PauseBufferPolicy.requestedSeconds(at: position, duration: duration) : 0
        if item.preferredForwardBufferDuration != preferred { item.preferredForwardBufferDuration = preferred }
        bufferBadge.isHidden = !paused
        guard paused else { return }
        let ahead = PauseBufferPolicy.bufferedSecondsAhead(at: position, ranges: item.loadedTimeRanges.map(\.timeRangeValue))
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
        itemObservation = nil
        playbackObservation = nil
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

/// Uses the actual website and its player rather than a reconstructed stream URL.
struct WebsitePlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var session = WebsitePlayerSession()
    let item: MediaItem
    let pageURL: URL
    let request: PlaybackRequest
    let startOver: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Закрити") { Task { await session.flush(stop: true); dismiss() } }
                Spacer()
                Text("Вебплеєр сайту").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Оновити") { Task { await session.reload() } }
            }
            .padding(12)
            Text("Якість обирається на сайті. Якщо потрібно, натисни Play у його плеєрі.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 8)
            if let error = session.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
            WebsitePlaybackWebView(pageURL: pageURL, request: request, resumePositions: resumePositions,
                                  startOver: startOver, session: session, onProgress: recordProgress)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onChange(of: scenePhase) {
            if scenePhase != .active { Task { await session.flush() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            Task { await session.flush() }
        }
    }

    private var resumePositions: [String: Double] {
        var positions: [String: Double] = [:]
        for record in model.cloudHistoryRecords where record.item.id == item.id && record.progress < 1 && record.position.isFinite {
            let key = record.seasonID.flatMap { season in record.episodeID.map { "\(season):\($0)" } } ?? "movie"
            positions[key] = record.position
        }
        return positions
    }

    private func recordProgress(_ checkpoint: WebsiteCheckpoint) {
        var actual = request
        if request.season != nil {
            guard let season = checkpoint.season, let episode = checkpoint.episode else { return }
            actual.season = season
            actual.episode = episode
        }
        actual.translatorID = checkpoint.translator ?? actual.translatorID
        model.recordProgress(for: item, position: checkpoint.position, duration: checkpoint.duration,
                             request: actual, recordedAt: checkpoint.recordedAt)
    }
}

struct WebsiteCheckpoint {
    let position: Double
    let duration: Double
    let season: String?
    let episode: String?
    let translator: String?
    let recordedAt: Date

    init?(_ body: Any) {
        guard let value = body as? [String: Any],
              let position = value["position"] as? Double, let duration = value["duration"] as? Double,
              position.isFinite, position >= 0, duration.isFinite, duration > 0, position <= duration + 1 else { return nil }
        self.position = position
        self.duration = duration
        season = (value["season"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        episode = (value["episode"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        translator = (value["translator"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        recordedAt = .now
    }
}

@MainActor
@Observable
final class WebsitePlayerSession {
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored var onProgress: ((WebsiteCheckpoint) -> Void)?
    @ObservationIgnored private var lastCheckpoint: WebsiteCheckpoint?
    @ObservationIgnored var configuration: [String: Any] = [:]
    var errorMessage: String?

    func accept(_ body: Any) {
        guard let checkpoint = WebsiteCheckpoint(body) else { return }
        lastCheckpoint = checkpoint
        var positions = configuration["resume"] as? [String: Double] ?? [:]
        let key = checkpoint.season.flatMap { season in checkpoint.episode.map { "\(season):\($0)" } } ?? "movie"
        positions[key] = checkpoint.position < checkpoint.duration ? checkpoint.position : 0
        configuration["resume"] = positions
        configuration["season"] = checkpoint.season ?? ""
        configuration["episode"] = checkpoint.episode ?? ""
        configuration["translator"] = checkpoint.translator ?? ""
        configuration["startOver"] = false
        onProgress?(checkpoint)
    }

    func flush(stop: Bool = false) async {
        guard let webView else { return }
        if let result = try? await webView.callAsyncJavaScript(
            "const value = window.__rezkaSnapshot ? window.__rezkaSnapshot() : null; if (stop) document.querySelectorAll('video').forEach(v => v.pause()); return value;",
            arguments: ["stop": stop], in: nil, contentWorld: .defaultClient) {
            accept(result)
        }
    }

    func reload() async {
        await flush()
        guard let webView else { return }
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: WebsitePlaybackScript.make(configuration: configuration),
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        webView.reload()
    }

    func finish() {
        let checkpoint = lastCheckpoint
        let callback = onProgress
        onProgress = nil
        webView = nil
        if let checkpoint { Task { @MainActor in callback?(checkpoint) } }
    }
}

struct WebsitePlaybackWebView: UIViewRepresentable {
    let pageURL: URL
    let request: PlaybackRequest
    let resumePositions: [String: Double]
    let startOver: Bool
    let session: WebsitePlayerSession
    let onProgress: (WebsiteCheckpoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(pageURL: pageURL, session: session) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "rezkaProgress")
        let values: [String: Any] = ["path": pageURL.path, "translator": request.translatorID ?? "",
                                   "season": request.season ?? "", "episode": request.episode ?? "",
                                   "resume": resumePositions, "startOver": startOver]
        let script = WebsitePlaybackScript.make(configuration: values)
        session.configuration = values
        configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd,
                                                                       forMainFrameOnly: true, in: .defaultClient))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.accessibilityIdentifier = "website-player"
        session.webView = webView
        session.onProgress = onProgress
        context.coordinator.loadingTask = Task { @MainActor [weak webView] in
            guard let webView else { return }
            let host = pageURL.host ?? ""
            for cookie in HTTPCookieStorage.shared.cookies ?? [] {
                let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                if host == domain || host.hasSuffix("." + domain) {
                    await configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
                }
            }
            guard !Task.isCancelled else { return }
            webView.load(URLRequest(url: pageURL))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // A progress write must never reload the website or recreate its player.
        session.onProgress = onProgress
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.loadingTask?.cancel()
        coordinator.session.finish()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "rezkaProgress", contentWorld: .defaultClient)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        let pageURL: URL
        let session: WebsitePlayerSession
        var loadingTask: Task<Void, Never>?

        init(pageURL: URL, session: WebsitePlayerSession) { self.pageURL = pageURL; self.session = session }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.webView === session.webView, message.frameInfo.isMainFrame,
                  message.frameInfo.request.url?.path == pageURL.path else { return }
            session.accept(message.body)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url, ["http", "https", "about"].contains(url.scheme ?? "") else { return .cancel }
            if navigationAction.targetFrame?.isMainFrame == true, url.host != pageURL.host { return .cancel }
            return .allow
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { session.errorMessage = nil }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            session.errorMessage = error.localizedDescription
        }
    }
}

enum WebsitePlaybackScript {
    static func make(configuration: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: configuration), let json = String(data: data, encoding: .utf8) else { return "" }
        return template.replacingOccurrences(of: "__CONFIG__", with: json)
    }

    static let template = #"""
    (() => {
      const c = __CONFIG__;
      if ((location.pathname !== c.path && decodeURIComponent(location.pathname) !== c.path) || window.__rezkaSnapshot) return;
      let lastClick = 0, selectionReady = false, manual = false, blockedSource = null;
      let activeVideo = null, mediaKey = '', restoring = false, target = 0, lastEmit = 0, scrolled = false, consumedStartOver = false;
      const clicked = new Set();
      const attached = new WeakSet();
      const find = (selector, attr, value) => Array.from(document.querySelectorAll(selector)).find(n => n.getAttribute(attr) === value);
      const selected = (selector, attr) => document.querySelector(selector + '.active')?.getAttribute(attr) || '';
      const selection = () => ({
        translator: selected('.b-translator__item', 'data-translator_id') || c.translator,
        season: selected('.b-simple_season__item', 'data-tab_id'),
        episode: Array.from(document.querySelectorAll('.b-simple_episode__item.active')).find(n => n.getClientRects().length)?.getAttribute('data-episode_id') || ''
      });
      function chooseInitial() {
        if (manual) return true;
        if (Date.now() - lastClick < 800) return false;
        for (const [selector, attr, value] of [
          ['.b-translator__item', 'data-translator_id', c.translator],
          ['.b-simple_season__item', 'data-tab_id', c.season],
          ['.b-simple_episode__item', 'data-episode_id', c.episode]
        ]) {
          if (!value) continue;
          const nodes = Array.from(document.querySelectorAll(selector));
          if (!nodes.length && selector === '.b-translator__item') continue;
          const node = nodes.find(n => n.getAttribute(attr) === value && (selector !== '.b-simple_episode__item' || n.getClientRects().length));
          if (!node) return false;
          if (node.classList.contains('active')) continue;
          const key = selector + value;
          if (clicked.has(key)) return false;
          clicked.add(key);
          blockedSource = document.querySelector('video')?.currentSrc || null;
          lastClick = Date.now();
          node.click();
          return false;
        }
        return true;
      }
      function snapshot() {
        const v = activeVideo;
        if (!v || !selectionReady || restoring || v.seeking || Date.now() - lastClick < 800) return null;
        if (blockedSource && v.currentSrc === blockedSource) return null;
        if (!Number.isFinite(v.currentTime) || !Number.isFinite(v.duration) || v.duration <= 0) return null;
        const s = selection();
        if (c.season && (!s.season || !s.episode)) return null;
        if ((s.season ? s.season + ':' + s.episode : 'movie') + '|' + v.currentSrc !== mediaKey) return null;
        return {...s, position: v.currentTime, duration: v.duration};
      }
      function emit(force = false) {
        if (!force && Date.now() - lastEmit < 1000) return;
        const value = snapshot();
        if (value) {
          c.resume[value.season ? value.season + ':' + value.episode : 'movie'] = activeVideo.ended ? 0 : value.position;
          lastEmit = Date.now(); window.webkit.messageHandlers.rezkaProgress.postMessage(value);
        }
      }
      function tick() {
        if (!selectionReady) selectionReady = chooseInitial();
        if (!selectionReady || Date.now() - lastClick < 800) return;
        const candidates = Array.from(document.querySelectorAll('video')).filter(v => v.getClientRects().length);
        const v = candidates.sort((a,b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0];
        if (!v || !v.currentSrc || (blockedSource && v.currentSrc === blockedSource)) return;
        blockedSource = null;
        const s = selection();
        if (c.season && (!s.season || !s.episode)) return;
        const key = (s.season ? s.season + ':' + s.episode : 'movie') + '|' + v.currentSrc;
        if (v !== activeVideo || key !== mediaKey) {
          activeVideo = v; mediaKey = key;
          const recordKey = s.season ? s.season + ':' + s.episode : 'movie';
          const reset = c.startOver && !consumedStartOver && (!c.season || (s.season === c.season && s.episode === c.episode));
          target = reset ? 0 : Number(c.resume[recordKey] || 0);
          if (reset) consumedStartOver = true;
          restoring = true;
          if (!attached.has(v)) {
            attached.add(v);
            for (const event of ['pause','seeked','ended']) v.addEventListener(event, () => emit(true));
            v.addEventListener('timeupdate', () => emit());
          }
          v.setAttribute('playsinline', '');
        }
        if (restoring && v.readyState >= 1 && Number.isFinite(v.duration) && v.duration > target) {
          if (Math.abs(v.currentTime - target) > 0.75) {
            if (!v.seeking) { try { v.currentTime = target; } catch (_) {} }
          } else if (!v.seeking) {
            restoring = false;
            const p = v.play(); if (p?.catch) p.catch(() => {});
          }
        }
        if (!scrolled) { scrolled = true; v.scrollIntoView({block:'center', behavior:'smooth'}); }
        emit();
      }
      document.addEventListener('click', e => {
        if (e.isTrusted && e.target.closest?.('.b-translator__item,.b-simple_season__item,.b-simple_episode__item')) {
          manual = true; lastClick = Date.now(); blockedSource = activeVideo?.currentSrc || null;
        }
      }, true);
      document.addEventListener('visibilitychange', () => emit(true));
      window.addEventListener('pagehide', () => emit(true));
      window.__rezkaSnapshot = snapshot;
      setInterval(tick, 500);
      tick();
    })();
    """#
}
