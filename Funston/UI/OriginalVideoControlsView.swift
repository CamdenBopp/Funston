import UIKit
import AVKit

/// The MKV player's controls, laid out like the system player (AVPlayerViewController
/// on iOS 27, measured on an iPhone 18 Pro Max) so both film paths look and read
/// the same. Buttons use the system glass style, which becomes solid and outlined
/// under Reduce Transparency or Increase Contrast, as the system player does.
@MainActor
final class OriginalVideoControlsView: UIView {
    enum Metrics {
        static let edgeMargin: CGFloat = 22
        static let smallButton: CGFloat = 44
        static let smallGlyph: CGFloat = 17
        static let groupSpacing: CGFloat = 12
        static let playButton: CGFloat = 92
        static let playGlyph: CGFloat = 36
        static let skipButton: CGFloat = 64
        static let skipGlyph: CGFloat = 26
        /// Centre of each skip button from the centre of Play.
        static let skipOffset: CGFloat = 117
        static let titleToScrubber: CGFloat = 12
        static let scrubberRowHeight: CGFloat = 44
        static let scrubberInset: CGFloat = 16
        static let timeToTrack: CGFloat = 12
        static let captionsGap: CGFloat = 16
        /// Title 2 at the default text size; scaled with Dynamic Type from there.
        static let titleSize: CGFloat = 22
        static let timeSize: CGFloat = 13
        /// The scrubber track behind the played part, over the film.
        static let emptyTrackOpacity: CGFloat = 0.3
    }

    enum Transport: Equatable { case loading, playing, paused, ended }

    static let skipInterval: Double = 10

    let closeButton = OriginalVideoControlsView.glassButton(symbol: "xmark", label: "Close")
    let pictureInPictureButton = OriginalVideoControlsView.plainButton(image: AVPictureInPictureController.pictureInPictureButtonStartImage, label: "Picture in Picture")
    let routePicker = AVRoutePickerView()
    let muteButton = OriginalVideoControlsView.glassButton(symbol: "speaker.wave.2.fill", label: "Mute")
    let backButton = OriginalVideoControlsView.glassButton(symbol: "gobackward.10", label: "Go Backward 10 Seconds",
                                                            diameter: Metrics.skipButton, glyph: Metrics.skipGlyph)
    let playButton = OriginalVideoControlsView.glassButton(symbol: "play.fill", label: "Play",
                                                            diameter: Metrics.playButton, glyph: Metrics.playGlyph)
    let forwardButton = OriginalVideoControlsView.glassButton(symbol: "goforward.10", label: "Go Forward 10 Seconds",
                                                               diameter: Metrics.skipButton, glyph: Metrics.skipGlyph)
    func configureSkipIntervals(back: Int, forward: Int) {
        backButton.setImage(UIImage(systemName: "gobackward.\(back)") ?? UIImage(systemName: "gobackward"), for: .normal)
        forwardButton.setImage(UIImage(systemName: "goforward.\(forward)") ?? UIImage(systemName: "goforward"), for: .normal)
        backButton.accessibilityLabel = "Go Backward \(back) Seconds"
        forwardButton.accessibilityLabel = "Go Forward \(forward) Seconds"
    }
    let moreButton = OriginalVideoControlsView.glassButton(symbol: "ellipsis", label: "More")
    let titleLabel = UILabel()
    let scrubber = PlaybackScrubber(style: .bar(fill: .white, track: UIColor.white.withAlphaComponent(Metrics.emptyTrackOpacity)),
                                    label: "Current position", backStep: OriginalVideoControlsView.skipInterval,
                                    forwardStep: OriginalVideoControlsView.skipInterval)
    let noticeLabel = UILabel()
    let spinner = UIActivityIndicatorView(style: .large)
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private let topGroup: UIVisualEffectView = OriginalVideoControlsView.glassCapsule()
    private let scrubberRow: UIVisualEffectView = OriginalVideoControlsView.glassCapsule()
    /// Where captions should sit so the controls don't cover them.
    let captionsGuide = UILayoutGuide()

    override init(frame: CGRect) {
        super.init(frame: frame)
        overrideUserInterfaceStyle = .dark
        titleLabel.font = UIFontMetrics(forTextStyle: .title2).scaledFont(for: .systemFont(ofSize: Metrics.titleSize, weight: .bold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        titleLabel.accessibilityTraits.insert(.header)
        for label in [elapsedLabel, remainingLabel] {
            label.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedDigitSystemFont(ofSize: Metrics.timeSize, weight: .semibold))
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
            // The scrubber's own value says the same thing once, as one stop.
            label.isAccessibilityElement = false
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }
        noticeLabel.font = .preferredFont(forTextStyle: .footnote)
        noticeLabel.adjustsFontForContentSizeCategory = true
        noticeLabel.textColor = .secondaryLabel
        noticeLabel.numberOfLines = 0
        noticeLabel.isHidden = true
        spinner.color = .white
        spinner.hidesWhenStopped = true
        routePicker.tintColor = .white
        routePicker.activeTintColor = .systemBlue
        routePicker.prioritizesVideoDevices = true
        moreButton.showsMenuAsPrimaryAction = true
        // Menus opening upward would otherwise list their items bottom to top.
        moreButton.preferredMenuElementOrder = .fixed

        let groupStack = UIStackView(arrangedSubviews: [pictureInPictureButton, routePicker])
        groupStack.spacing = 4
        groupStack.translatesAutoresizingMaskIntoConstraints = false
        topGroup.contentView.addSubview(groupStack)
        let timeStack = UIStackView(arrangedSubviews: [elapsedLabel, scrubber, remainingLabel])
        timeStack.spacing = Metrics.timeToTrack
        timeStack.alignment = .center
        timeStack.translatesAutoresizingMaskIntoConstraints = false
        scrubberRow.contentView.addSubview(timeStack)
        let titleRow = UIStackView(arrangedSubviews: [titleLabel, moreButton])
        titleRow.alignment = .center
        titleRow.spacing = Metrics.groupSpacing
        let bottom = UIStackView(arrangedSubviews: [noticeLabel, titleRow, scrubberRow])
        bottom.axis = .vertical
        bottom.spacing = Metrics.titleToScrubber
        for view in [closeButton, topGroup, muteButton, backButton, playButton, forwardButton, spinner, bottom] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        addLayoutGuide(captionsGuide)
        let safe = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: Metrics.edgeMargin),
            closeButton.topAnchor.constraint(equalTo: safe.topAnchor),
            topGroup.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: Metrics.groupSpacing),
            topGroup.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            topGroup.heightAnchor.constraint(equalToConstant: Metrics.smallButton),
            // No inset: one button alone makes a circle, two make a capsule.
            groupStack.leadingAnchor.constraint(equalTo: topGroup.contentView.leadingAnchor),
            groupStack.trailingAnchor.constraint(equalTo: topGroup.contentView.trailingAnchor),
            groupStack.centerYAnchor.constraint(equalTo: topGroup.contentView.centerYAnchor),
            pictureInPictureButton.widthAnchor.constraint(equalToConstant: Metrics.smallButton),
            pictureInPictureButton.heightAnchor.constraint(equalToConstant: Metrics.smallButton),
            routePicker.widthAnchor.constraint(equalToConstant: Metrics.smallButton),
            routePicker.heightAnchor.constraint(equalToConstant: Metrics.smallButton),
            muteButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -Metrics.edgeMargin),
            muteButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

            playButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            backButton.centerXAnchor.constraint(equalTo: playButton.centerXAnchor, constant: -Metrics.skipOffset),
            backButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            forwardButton.centerXAnchor.constraint(equalTo: playButton.centerXAnchor, constant: Metrics.skipOffset),
            forwardButton.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: playButton.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),

            bottom.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: Metrics.edgeMargin),
            bottom.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -Metrics.edgeMargin),
            bottom.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            scrubberRow.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.scrubberRowHeight),
            timeStack.leadingAnchor.constraint(equalTo: scrubberRow.contentView.leadingAnchor, constant: Metrics.scrubberInset),
            timeStack.trailingAnchor.constraint(equalTo: scrubberRow.contentView.trailingAnchor, constant: -Metrics.scrubberInset),
            timeStack.topAnchor.constraint(equalTo: scrubberRow.contentView.topAnchor),
            timeStack.bottomAnchor.constraint(equalTo: scrubberRow.contentView.bottomAnchor),

            captionsGuide.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: Metrics.edgeMargin),
            captionsGuide.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -Metrics.edgeMargin),
            captionsGuide.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -Metrics.captionsGap)
        ])
        updateAccessibilityOrder()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Touches between the controls reach the video underneath (tap to hide or show).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    func setTitle(_ title: String) {
        titleLabel.text = title
    }

    func setTransport(_ transport: Transport) {
        let loading = transport == .loading
        loading ? spinner.startAnimating() : spinner.stopAnimating()
        playButton.isHidden = loading
        let (symbol, label) = switch transport {
        case .playing: ("pause.fill", "Pause")
        case .ended: ("arrow.counterclockwise", "Replay")
        case .loading, .paused: ("play.fill", "Play")
        }
        playButton.configuration?.image = Self.symbol(symbol, size: Metrics.playGlyph)
        playButton.accessibilityLabel = label
        updateAccessibilityOrder()
    }

    func setMuted(_ muted: Bool) {
        muteButton.configuration?.image = Self.symbol(muted ? "speaker.slash.fill" : "speaker.wave.2.fill", size: Metrics.smallGlyph)
        muteButton.accessibilityLabel = muted ? "Unmute" : "Mute"
    }

    func setPictureInPictureAvailable(_ available: Bool) {
        pictureInPictureButton.isHidden = !available
        updateAccessibilityOrder()
    }

    func setTime(elapsed: Double, duration: Double?) {
        let known = MediaDuration.validated(duration)
        let showsHours = (known ?? elapsed) >= 3_600
        elapsedLabel.text = Self.clock(elapsed, showsHours: showsHours)
        remainingLabel.text = known.map { "\u{2212}" + Self.clock(max(0, $0 - elapsed), showsHours: showsHours) }
        remainingLabel.isHidden = known == nil
        scrubber.duration = known
        if !scrubber.isTracking { scrubber.position = elapsed }
    }

    func setNotice(_ text: String?) {
        noticeLabel.text = text
        noticeLabel.isHidden = text == nil
    }

    func setEnabled(_ enabled: Bool) {
        for button in [backButton, playButton, forwardButton, moreButton, muteButton, pictureInPictureButton] { button.isEnabled = enabled }
        scrubber.isEnabled = enabled && scrubber.duration != nil
    }

    /// VoiceOver reads top to bottom: leave, where it plays, then transport, then the film's details.
    private func updateAccessibilityOrder() {
        accessibilityElements = [closeButton, pictureInPictureButton, routePicker, muteButton,
                                 backButton, playButton, spinner, forwardButton, noticeLabel, titleLabel, scrubber, moreButton]
            .filter { !$0.isHidden }
    }

    /// "1:57" for short films; "0:01:57" once a film runs an hour, as the system player does.
    static func clock(_ seconds: Double, showsHours: Bool) -> String {
        let total = Int64(MediaDuration.validated(seconds) ?? 0)
        let hours = total / 3_600, minutes = total % 3_600 / 60, secs = total % 60
        return showsHours ? String(format: "%lld:%02lld:%02lld", hours, minutes, secs) : String(format: "%lld:%02lld", minutes, secs)
    }

    private static func symbol(_ name: String, size: CGFloat) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))
    }

    private static func glassButton(symbol name: String, label: String, diameter: CGFloat = Metrics.smallButton,
                                    glyph: CGFloat = Metrics.smallGlyph) -> UIButton {
        var configuration: UIButton.Configuration
        if #available(iOS 26.0, *) { configuration = .glass() } else { configuration = .gray() }
        configuration.image = symbol(name, size: glyph)
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: diameter),
            button.heightAnchor.constraint(equalToConstant: diameter)
        ])
        return button
    }

    private static func plainButton(image: UIImage, label: String) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = image
        configuration.baseForegroundColor = .white
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        return button
    }

    private static func glassCapsule() -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            let view = UIVisualEffectView(effect: UIGlassEffect())
            view.cornerConfiguration = .capsule()
            return view
        }
        let view = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        view.layer.cornerRadius = Metrics.smallButton / 2
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        return view
    }
}
