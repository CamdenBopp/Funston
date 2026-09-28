import UIKit
import AVKit
import Combine

/// Preparation/error UI owns the session; playback is presented by AVKit itself.
/// Do not embed its controls under a second, permanently visible navigation bar.
@MainActor
final class ArtifactVideoController: UIViewController, @preconcurrency AVPlayerViewControllerDelegate {
    private enum Presentation { case waiting, presenting, playing, pictureInPicture, closing }
    private let session: VideoPlaybackSession
    let video = AVPlayerViewController()
    private var subscription: AnyCancellable?
    private var presentation: Presentation = .waiting
    private var appeared = false
    private var nativePresentationInFlight = false

    init(session: VideoPlaybackSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        title = session.summary.title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "video.viewer"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.close()
        })
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "video.done"
        video.delegate = self
        video.allowsPictureInPicturePlayback = true
        // Archival playback doesn't use visual lookup. Avoid background frame
        // analysis and its extra accessibility affordance on paused films.
        video.allowsVideoFrameAnalysis = false
        video.videoGravity = .resizeAspect
        video.modalPresentationStyle = .fullScreen
        video.view.accessibilityIdentifier = "video.player"
        subscription = session.$state.removeDuplicates().sink { [weak self] state in self?.render(state) }
        session.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        // Also handles programmatic/nonanimated native-player dismissal. Merely
        // requesting presentation is not proof that the player appeared.
        if presentation == .playing, video.presentingViewController == nil {
            close()
        } else { render(session.state) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        appeared = false
        // AVKit fullscreen transitions and app backgrounding are not dismissal.
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            if let transitionCoordinator {
                transitionCoordinator.animate(alongsideTransition: nil) { [weak self] context in
                    if !context.isCancelled { self?.finish() }
                }
            } else { finish() }
        }
    }

    private func render(_ state: VideoPlaybackSession.State) {
        guard presentation != .closing else { return }
        // Loading/errors use adaptive system surfaces; only the film canvas is black.
        view.backgroundColor = state == .ready ? .black : .systemBackground
        switch state {
        case .ready:
            contentUnavailableConfiguration = nil
            video.player = session.player
            guard presentation == .waiting, appeared, presentedViewController == nil else { return }
            presentation = .presenting
            nativePresentationInFlight = true
            present(video, animated: true) { [weak self] in
                guard let self else { return }
                self.nativePresentationInFlight = false
                if self.presentation == .presenting, self.session.state == .ready {
                    self.presentation = .playing
                } else if self.presentation == .waiting {
                    // Preparation may fail while UIKit is still presenting AVKit.
                    // Reconcile only after that transition completes.
                    self.returnToPreparation()
                }
            }
        case .loading:
            returnToPreparation()
            var configuration = UIContentUnavailableConfiguration.loading()
            configuration.text = "Opening film"
            contentUnavailableConfiguration = configuration
        case .failed(let message):
            returnToPreparation()
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.text = "Could not play film"
            configuration.secondaryText = message
            configuration.button.title = "Try Again"
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.session.start() }
            contentUnavailableConfiguration = configuration
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        case .idle:
            returnToPreparation()
            contentUnavailableConfiguration = nil
        }
    }

    private func close() {
        finish()
        navigationController?.dismiss(animated: true)
    }

    private func finish() {
        guard presentation != .closing else { return }
        presentation = .closing
        video.player = nil
        session.stop()
    }

    private func returnToPreparation() {
        presentation = .waiting
        video.player = nil
        if !nativePresentationInFlight, video.presentingViewController != nil, !video.isBeingDismissed {
            video.dismiss(animated: true)
        }
    }

    func playerViewController(_ playerViewController: AVPlayerViewController,
                              willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator) {
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard let self, !context.isCancelled, self.presentation == .playing,
                  self.session.state == .ready else { return }
            self.close()
        }
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        guard playerViewController === video, session.state == .ready,
              presentation == .playing || presentation == .presenting else { return }
        presentation = .pictureInPicture
    }

    func playerViewController(_ playerViewController: AVPlayerViewController, failedToStartPictureInPictureWithError error: any Error) {
        guard playerViewController === video, presentation == .pictureInPicture,
              session.state == .ready else { return }
        presentation = .playing
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        guard presentation == .pictureInPicture else { return }
        presentation = .playing
        if video.presentingViewController == nil { close() }
    }

    nonisolated func playerViewControllerShouldAutomaticallyDismissAtPictureInPictureStart(_ playerViewController: AVPlayerViewController) -> Bool { false }

    nonisolated func playerViewController(_ playerViewController: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void) {
        // PiP never discards this modal. The system brings its existing scene back;
        // do not construct a second player or lose the current playback position.
        Task { @MainActor [weak self] in
            guard let self else { completionHandler(false); return }
            completionHandler(self.video.presentingViewController != nil && self.presentation != .closing)
        }
    }
}
