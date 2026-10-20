import UIKit

/// The position bar. Drag anywhere on it, as with the system player; VoiceOver
/// treats it as one adjustable control that moves by the step sizes per swipe.
@MainActor
final class PlaybackScrubber: UIControl {
    private enum Metrics {
        static let trackHeight: CGFloat = 6
        static let trackingHeight: CGFloat = 12
        static let touchHeight: CGFloat = 44
    }

    var duration: Double? { didSet { setNeedsLayout(); updateAccessibility() } }
    var position: Double = 0 { didSet { setNeedsLayout(); updateAccessibility() } }
    /// The rate VoiceOver's remaining time is spoken at.
    var playbackRate: Double = 1 { didSet { updateAccessibility() } }
    var backStep: Double
    var forwardStep: Double
    private let track = UIView()
    private let fill = UIView()

    init(fillColor: UIColor, trackColor: UIColor, label: String, backStep: Double, forwardStep: Double) {
        self.backStep = backStep
        self.forwardStep = forwardStep
        super.init(frame: .zero)
        track.backgroundColor = trackColor
        fill.backgroundColor = fillColor
        for view in [track, fill] {
            view.isUserInteractionEnabled = false
            view.layer.cornerCurve = .continuous
            addSubview(view)
        }
        isAccessibilityElement = true
        accessibilityLabel = label
        accessibilityTraits = .adjustable
        heightAnchor.constraint(equalToConstant: Metrics.touchHeight).isActive = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = isTracking ? Metrics.trackingHeight : Metrics.trackHeight
        track.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        track.layer.cornerRadius = height / 2
        let fraction = duration.map { $0 > 0 ? min(1, max(0, position / $0)) : 0 } ?? 0
        fill.frame = CGRect(x: 0, y: track.frame.minY, width: bounds.width * fraction, height: height)
        fill.layer.cornerRadius = height / 2
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard duration != nil else { return false }
        move(to: touch)
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.15) { self.layoutIfNeeded() }
        return true
    }
    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool { move(to: touch); return true }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch { move(to: touch) }
        setNeedsLayout()
        sendActions(for: .primaryActionTriggered)
    }
    override func cancelTracking(with event: UIEvent?) { setNeedsLayout() }

    private func move(to touch: UITouch) {
        guard let duration, bounds.width > 0 else { return }
        position = min(1, max(0, touch.location(in: self).x / bounds.width)) * duration
        sendActions(for: .valueChanged)
    }

    override func accessibilityIncrement() { step(by: forwardStep) }
    override func accessibilityDecrement() { step(by: -backStep) }
    private func step(by seconds: Double) {
        guard let duration else { return }
        position = min(duration, max(0, position + seconds))
        sendActions(for: .primaryActionTriggered)
    }

    private func updateAccessibility() {
        guard let duration else { accessibilityValue = PlayerTimePresentation.spoken(position); return }
        accessibilityValue = PlayerTimePresentation.spokenPosition(position, duration: duration, rate: playbackRate)
    }
}
