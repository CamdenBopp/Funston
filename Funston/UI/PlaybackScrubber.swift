import UIKit

/// The position bar. VoiceOver treats it as one adjustable control that moves
/// by the step sizes per swipe.
///
/// `.bar` is the system player's thin bar: drag anywhere on it. `.thumb` draws
/// a stock UISlider and, like it, moves only when the thumb is dragged. The
/// slider never receives touches itself: on iOS 26 UISlider keeps coasting
/// after the finger lifts and reports where the coast stopped, so this control
/// tracks the finger and sets the slider's value.
@MainActor
final class PlaybackScrubber: UIControl {
    enum Style {
        case bar(fill: UIColor, track: UIColor)
        case thumb
    }

    private enum Metrics {
        static let trackHeight: CGFloat = 6
        static let trackingHeight: CGFloat = 12
    }
    /// The bar is thin but the touch area meets the minimum target.
    static let touchHeight: CGFloat = 44

    var duration: Double? { didSet { setNeedsLayout(); updateAccessibility() } }
    var position: Double = 0 { didSet { setNeedsLayout(); updateAccessibility() } }
    /// The rate VoiceOver's remaining time is spoken at.
    var playbackRate: Double = 1 { didSet { updateAccessibility() } }
    var backStep: Double
    var forwardStep: Double
    private let style: Style
    private let track = UIView()
    private let fill = UIView()
    private let slider = UISlider()
    /// Where on the thumb the finger landed, so the thumb doesn't jump under it.
    private var grabOffset: CGFloat = 0

    init(style: Style, label: String, backStep: Double, forwardStep: Double) {
        self.style = style
        self.backStep = backStep
        self.forwardStep = forwardStep
        super.init(frame: .zero)
        switch style {
        case let .bar(fillColor, trackColor):
            track.backgroundColor = trackColor
            fill.backgroundColor = fillColor
            for view in [track, fill] {
                view.isUserInteractionEnabled = false
                view.layer.cornerCurve = .continuous
                addSubview(view)
            }
        case .thumb:
            slider.isUserInteractionEnabled = false
            slider.isAccessibilityElement = false
            addSubview(slider)
        }
        isAccessibilityElement = true
        accessibilityLabel = label
        accessibilityTraits = .adjustable
        if case .bar = style { heightAnchor.constraint(equalToConstant: Self.touchHeight).isActive = true }
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The thumb style takes the height its container gives it; the touch
    /// area still grows to the minimum target.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let slack = max(0, Self.touchHeight - bounds.height) / 2
        return bounds.insetBy(dx: 0, dy: -slack).contains(point)
    }

    private var fraction: Double { duration.map { $0 > 0 ? min(1, max(0, position / $0)) : 0 } ?? 0 }

    override func layoutSubviews() {
        super.layoutSubviews()
        switch style {
        case .bar:
            let height = isTracking ? Metrics.trackingHeight : Metrics.trackHeight
            track.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
            track.layer.cornerRadius = height / 2
            fill.frame = CGRect(x: 0, y: track.frame.minY, width: bounds.width * fraction, height: height)
            fill.layer.cornerRadius = height / 2
        case .thumb:
            slider.frame = bounds
            slider.value = Float(fraction)
        }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard duration != nil else { return false }
        switch style {
        case .bar:
            move(to: touch)
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.15) { self.layoutIfNeeded() }
        case .thumb:
            let thumb = thumbFrame(at: slider.value)
            // The full control height counts, so a small thumb still meets the touch target.
            let target = CGRect(x: thumb.minX, y: 0, width: thumb.width, height: bounds.height)
            let x = touch.location(in: self).x
            guard target.contains(CGPoint(x: x, y: bounds.midY)) else { return false }
            grabOffset = x - thumb.midX
        }
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
        let x = touch.location(in: self).x
        switch style {
        case .bar:
            position = min(1, max(0, x / bounds.width)) * duration
        case .thumb:
            // The thumb's centre travels between its frames at the two ends.
            let start = thumbFrame(at: 0).midX, end = thumbFrame(at: 1).midX
            guard end > start else { return }
            position = Double(min(1, max(0, (x - grabOffset - start) / (end - start)))) * duration
        }
        sendActions(for: .valueChanged)
    }

    private func thumbFrame(at value: Float) -> CGRect {
        let frame = slider.thumbRect(forBounds: slider.bounds, trackRect: slider.trackRect(forBounds: slider.bounds), value: value)
        return slider.convert(frame, to: self)
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
