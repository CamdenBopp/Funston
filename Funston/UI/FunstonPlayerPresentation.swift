import UIKit
import SwiftUI
import LNPopupController

/// Owns player presentation only; playback, downloads and image caching stay in the app.
@MainActor
final class FunstonPlayerPresentation: NSObject, LNPopupPresentationDelegate {
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
    private lazy var toggle = UIBarButtonItem(image: UIImage(systemName: "play.fill"), primaryAction: UIAction { [weak self] _ in
        self?.environment.playback.togglePlayback()
    })

    init(environment: AppEnvironment) { self.environment = environment; super.init() }
    deinit { artworkTask?.cancel() }

    func detach() {
        guard let container else { return }
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
            container?.dismissPopupBar(animated: false)
            content = nil
            return
        }
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
