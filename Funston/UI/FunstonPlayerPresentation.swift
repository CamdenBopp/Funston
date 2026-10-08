import UIKit
import SwiftUI
import LNPopupController

/// Owns player presentation only; playback, downloads and image caching stay in the app.
@MainActor
final class FunstonPlayerPresentation: NSObject, LNPopupPresentationDelegate, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
    /// Bare glass over a white page measured 2.17:1 behind the title and
    /// 3.29:1 behind the subtitle. Darkening that glass (sRGB ~0.69) to the
    /// 0.29 the grey subtitle needs for 4.5:1 takes at least 0.58 of the
    /// background color composited on top.
    private static let legibilityBackingOpacity: CGFloat = 0.6
    private let environment: AppEnvironment
    private weak var container: UIViewController?
    private var content: UIHostingController<FullPlayer>?
    private var artworkTask: Task<Void, Never>?
    private var artworkIdentifier: String?
    private var reopenAfterAttach = false
    private var progressVisible = false
    private var undoToast: UIHostingController<StoppedListeningToast>?
    private var undoExpiry: Task<Void, Never>?
    private var stoppedContext: PlaybackContext?

    private lazy var dismissPan: UIPanGestureRecognizer = {
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(didDragMiniPlayer(_:)))
        gesture.delegate = self
        return gesture
    }()
    private lazy var toggle = UIBarButtonItem(image: UIImage(systemName: "play.fill"), primaryAction: UIAction { [weak self] _ in
        self?.environment.playback.togglePlayback()
    })

    init(environment: AppEnvironment) { self.environment = environment; super.init() }
    deinit { artworkTask?.cancel(); undoExpiry?.cancel() }

    func detach() {
        guard let container else { return }
        removeUndoToast()
        reopenAfterAttach = container.popupPresentationState == .open
        setProgressVisible(false)
        container.dismissPopupBar(animated: false)
        container.popupPresentationDelegate = nil
        self.container = nil
    }

    func attach(to container: UIViewController) {
        self.container = container
        container.popupPresentationDelegate = self
        container.popupInteractionStyle = .automatic
        container.popupContentView.popupInteractionGestureRecognizer.delegate = self
        container.popupContentView.popupCloseButtonStyle = .chevron
        container.popupContentView.popupCloseButton.tintColor = .secondaryLabel
        container.popupContentView.popupCloseButton.accessibilityLabel = "Close player"
        let appearance = LNPopupBarAppearance()
        appearance.marqueeScrollEnabled = false
        appearance.subtitleTextAttributes = AttributeContainer().foregroundColor(UIColor.funstonSecondaryLabel)
        appearance.floatingBackgroundColor = UIColor.systemBackground.withAlphaComponent(Self.legibilityBackingOpacity)
        container.popupBar.inheritsAppearanceFromDockingView = false
        container.popupBar.standardAppearance = appearance
        container.popupBar.accessibilityIdentifier = "compactPlayer.open"
        container.popupBar.addGestureRecognizer(dismissPan)
        container.popupBar.addInteraction(UIContextMenuInteraction(delegate: self))
        container.popupBar.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Stop and close player", target: self, selector: #selector(stopListening))
        ]
        if let content {
            container.presentPopupBar(with: content, openPopup: reopenAfterAttach, animated: false)
        }
        reopenAfterAttach = false
    }

    func update(context: PlaybackContext?, phase: PlaybackPhase, wantsToPlay: Bool) {
        guard let context else {
            setProgressVisible(false)
            artworkTask?.cancel()
            artworkIdentifier = nil
            container?.dismissPopupBar(animated: !UIAccessibility.isReduceMotionEnabled)
            content = nil
            return
        }
        if environment.playback.context != nil { removeUndoToast() }
        let isNew = content == nil
        let controller: UIHostingController<FullPlayer>
        if let content { controller = content }
        else {
            controller = UIHostingController(rootView: FullPlayer(playback: environment.playback, downloads: environment.downloads))
            controller.view.backgroundColor = .systemBackground
            content = controller
        }
        controller.popupItem.title = context.track.title
        controller.popupItem.subtitle = phase == .playing || phase == .paused ? context.artifact.title : phase.spokenValue
        controller.popupItem.accessibilityLabel = "\(context.track.title). \(context.artifact.title)"
        controller.popupItem.accessibilityValue = phase.spokenValue
        controller.popupItem.accessibilityHint = "Opens player"
        controller.popupItem.accessibilityImageLabel = context.artifact.title
        let isPlaying = phase.showsPauseControl(wantsToPlay: wantsToPlay)
        toggle.image = UIImage(systemName: isPlaying ? "pause.fill" : "play.fill")
        toggle.accessibilityLabel = isPlaying ? "Pause" : "Play"
        toggle.accessibilityIdentifier = "compactPlayer.toggle"
        controller.popupItem.barButtonItems = [toggle]
        if isNew { container?.presentPopupBar(with: controller, animated: !UIAccessibility.isReduceMotionEnabled) }
        loadArtwork(identifier: context.artifact.identifier)
    }

    func popupPresentationController(_ popupPresentationController: UIViewController, willOpenPopupWithContentController popupContentController: UIViewController, animated: Bool) {
        setProgressVisible(true)
    }

    func popupPresentationController(_ popupPresentationController: UIViewController, didClosePopupWithContentController popupContentController: UIViewController, animated: Bool) {
        setProgressVisible(false)
    }

    @objc private func didDragMiniPlayer(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended, gesture.translation(in: gesture.view).y > 24 else { return }
        _ = stopListening()
    }

    @objc private func stopListening() -> Bool {
        guard let container, container.popupPresentationState == .barPresented,
              environment.playback.acceptsAudioCommands else { return false }
        guard let stopped = environment.playback.stopListening() else { return false }
        showUndoToast(stopped)
        return true
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard container?.popupPresentationState == .barPresented else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [UIAction(title: "Stop and close player", image: UIImage(systemName: "stop.circle")) { [weak self] _ in
                _ = self?.stopListening()
            }])
        }
    }

    private func showUndoToast(_ stopped: PlaybackContext) {
        removeUndoToast()
        guard let container else { return }
        stoppedContext = stopped
        let toast = UIHostingController(rootView: StoppedListeningToast(title: stopped.track.title) { [weak self] in
            guard let self, let stopped = stoppedContext else { return }
            removeUndoToast()
            environment.playback.undoStopListening(stopped)
        })
        toast.view.backgroundColor = .clear
        toast.view.translatesAutoresizingMaskIntoConstraints = false
        toast.sizingOptions = .intrinsicContentSize
        container.addChild(toast)
        container.view.addSubview(toast.view)
        NSLayoutConstraint.activate([
            toast.view.leadingAnchor.constraint(equalTo: container.view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            toast.view.trailingAnchor.constraint(equalTo: container.view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            toast.view.bottomAnchor.constraint(equalTo: container.view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
        toast.didMove(toParent: container)
        undoToast = toast
        UIAccessibility.post(notification: .announcement, argument: "Stopped \(stopped.track.title). Undo available.")
        let seconds = UIAccessibility.isVoiceOverRunning ? 10 : 4
        undoExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.removeUndoToast()
        }
    }

    private func removeUndoToast() {
        undoExpiry?.cancel(); undoExpiry = nil
        undoToast?.willMove(toParent: nil)
        undoToast?.view.removeFromSuperview()
        undoToast?.removeFromParent()
        undoToast = nil
        stoppedContext = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === dismissPan {
            let velocity = dismissPan.velocity(in: dismissPan.view)
            return container?.popupPresentationState == .barPresented && velocity.y > abs(velocity.x)
        }
        if container?.popupPresentationState == .barPresented,
           let pan = gestureRecognizer as? UIPanGestureRecognizer {
            let velocity = pan.velocity(in: container?.popupBar)
            // Leave a downward swipe to dismissal; upward pans still open the player.
            return velocity.y <= 0
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    private func setProgressVisible(_ visible: Bool) {
        guard progressVisible != visible else { return }
        progressVisible = visible
        if visible { environment.playback.beginVisibleProgress() }
        else { environment.playback.endVisibleProgress() }
    }

    private func loadArtwork(identifier: String) {
        guard artworkIdentifier != identifier else { return }
        artworkIdentifier = identifier
        artworkTask?.cancel()
        content?.popupItem.image = UIImage(systemName: "waveform")
        let scale = container?.traitCollection.displayScale ?? 2
        artworkTask = Task { [weak self] in
            let image = try? await ArtworkPipeline.shared.image(
                url: ArchiveURLs.thumbnail(identifier: identifier),
                pointSize: CGSize(width: 64, height: 64), scale: scale)
            guard !Task.isCancelled, let self, artworkIdentifier == identifier else { return }
            if let image { content?.popupItem.image = image.value }
        }
    }
}

private struct StoppedListeningToast: View {
    let title: String
    let undo: () -> Void
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { message; undoButton }
            VStack(alignment: .leading, spacing: 12) { message; undoButton }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
    private var message: some View { Text("Stopped \(title)").fixedSize(horizontal: false, vertical: true) }
    private var undoButton: some View {
        Button("Undo", action: undo).buttonStyle(.bordered).accessibilityIdentifier("compactPlayer.undo")
    }
}
