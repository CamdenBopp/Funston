import SwiftUI
import AVKit
import Combine

struct FullPlayer: View {
    let playback: PlaybackController
    let downloads: DownloadManager
    @StateObject private var presentation: PlayerPresentationState
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showingQueue = false
    @State private var showingSpeed = false

    init(playback: PlaybackController, downloads: DownloadManager) {
        self.playback = playback
        self.downloads = downloads
        _presentation = StateObject(wrappedValue: PlayerPresentationState(playback: playback))
    }

    var body: some View {
        GeometryReader { geometry in
            playerLayout {
                if let context = presentation.context {
                    VStack(alignment: .leading, spacing: typeSize.isAccessibilitySize ? 22 : 12) {
                        GeometryReader { artworkBounds in
                            ArtifactArtwork(identifier: context.artifact.identifier,
                                            size: 360, flexible: true,
                                            mediaType: context.artifact.mediaType, url: context.artifact.artworkURL)
                                .frame(width: artworkBounds.size.width, height: artworkBounds.size.height)
                        }
                            .frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 140 : 0, maxHeight: typeSize.isAccessibilitySize ? 220 : .infinity)
                            .layoutPriority(-1)
                            .overlay(alignment: .bottom) {
                                if presentation.phase != .playing && presentation.phase != .paused {
                                    Text(presentation.phase.spokenValue)
                                        .font(.caption).padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(.regularMaterial, in: Capsule())
                                        .accessibilityIdentifier("player.state")
                                }
                            }
                        VStack(alignment: .leading, spacing: 7) {
                            Text(context.track.title).font(.title2.weight(.semibold)).lineLimit(typeSize.isAccessibilitySize ? nil : 2).accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("player.trackTitle")
                            Text(context.artifact.title).font(.subheadline).lineLimit(typeSize.isAccessibilitySize ? nil : 1).foregroundStyle(Color.funstonSecondaryText)
                        }
                        if case .failed(let message) = presentation.phase {
                            Text(message).font(.callout)
                            Button("Try Again") { playback.load(artifact: context.artifact, tracks: context.tracks, trackIndex: context.trackIndex) }
                        }
                        PlaybackPositionView(playback: playback)
                        HStack {
                            transport("Back \(Int(playback.skipBackInterval)) seconds", symbol: "gobackward.\(Int(playback.skipBackInterval))") { playback.skip(by: -playback.skipBackInterval) }
                            Spacer()
                            Button { playback.togglePlayback() } label: {
                                Image(systemName: presentation.showsPauseControl ? "pause.fill" : "play.fill")
                                    .font(.system(size: 36, weight: .semibold)).frame(width: 88, height: 88)
                            }.accessibilityLabel(presentation.showsPauseControl ? "Pause" : "Play")
                                .accessibilityValue(presentation.phase.spokenValue)
                                .accessibilityIdentifier("player.toggle")
                            Spacer()
                            transport("Forward \(Int(playback.skipForwardInterval)) seconds", symbol: "goforward.\(Int(playback.skipForwardInterval))") { playback.skip(by: playback.skipForwardInterval) }
                        }.buttonStyle(PlayerControlStyle()).foregroundStyle(.primary).padding(.horizontal, 8)
                        if context.tracks.count > 1 {
                            HStack {
                                Button { playback.previousTrack() } label: { Image(systemName: "backward.end.fill").frame(width: 48, height: 48) }.accessibilityLabel("Previous recording")
                                Spacer()
                                Button { showingQueue = true } label: {
                                    Label("\(context.trackIndex + 1) of \(context.tracks.count)", systemImage: "list.bullet").font(.subheadline).padding(.horizontal, 14).frame(minHeight: 48)
                                }.accessibilityLabel("Recordings, \(context.trackIndex + 1) of \(context.tracks.count)")
                                Spacer()
                                Button { playback.nextTrack() } label: { Image(systemName: "forward.end.fill").frame(width: 48, height: 48) }.accessibilityLabel("Next recording").disabled(context.trackIndex + 1 >= context.tracks.count)
                            }.font(.callout).buttonStyle(PlayerControlStyle())
                        }
                        HStack(alignment: .top, spacing: 12) {
                            DownloadButton(downloads: downloads, artifact: context.artifact,
                                           file: context.file, compact: true)
                                .frame(maxWidth: .infinity)
                            Button { showingSpeed = true } label: {
                                VStack(spacing: 6) {
                                    Text("\(presentation.playbackRate.formatted())×").font(.headline).frame(height: 48)
                                    Text("Speed").font(.caption).foregroundStyle(Color.funstonSecondaryText)
                                }.frame(maxWidth: .infinity)
                            }.buttonStyle(.plain).accessibilityLabel("Playback speed")
                                .accessibilityValue("\(presentation.playbackRate.formatted()) times")
                                .accessibilityIdentifier("player.speed")
                                .popover(isPresented: $showingSpeed, arrowEdge: .bottom) {
                                    PlaybackSpeedPopover(playback: playback)
                                }
                            SleepTimerMenu(timer: playback.sleepTimer, compact: true)
                                .frame(maxWidth: .infinity)
                            VStack(spacing: 6) {
                                RoutePicker().frame(width: 48, height: 48)
                                    .accessibilityLabel("Audio output")
                                    .accessibilityIdentifier("player.audioOutput")
                                Text("AirPlay").font(.caption).foregroundStyle(Color.funstonSecondaryText)
                                    .accessibilityHidden(true)
                            }.frame(maxWidth: .infinity)
                        }.padding(.top, 8)

                    }.padding(.horizontal, 24).padding(.top, 44).padding(.bottom, 12).frame(maxWidth: 520)
                        .frame(maxHeight: typeSize.isAccessibilitySize ? nil : geometry.size.height)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $showingQueue) {
            if let context = presentation.context {
                RecordingQueueView(playback: playback, identifier: context.artifact.identifier)
            }
        }
    }

    @ViewBuilder private func playerLayout<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if typeSize.isAccessibilitySize { ScrollView { content() } }
        else { content() }
    }

    private func transport(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 28, weight: .medium)).frame(width: 64, height: 64) }.accessibilityLabel(label)
    }
}

/// Deliberate surfaces avoid automatic system button fills while retaining
/// the user's request for stronger control boundaries.
private struct PlayerControlStyle: ButtonStyle {
    @Environment(\.accessibilityShowBorders) private var showBorders
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(.primary.opacity(configuration.isPressed ? 0.18 : 0.08), in: Capsule())
            .overlay {
                Capsule().strokeBorder(.primary.opacity(showBorders ? 0.55 : 0.12),
                                       lineWidth: showBorders ? 2 : 1)
            }
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Only transport/context changes invalidate artwork and the queue. Progress stays in its own subtree.
@MainActor
private final class PlayerPresentationState: ObservableObject {
    @Published private(set) var context: PlaybackContext?
    @Published private(set) var phase: PlaybackPhase
    @Published private(set) var wantsToPlay: Bool
    @Published private(set) var playbackRate: Double
    var showsPauseControl: Bool { phase.showsPauseControl(wantsToPlay: wantsToPlay) }
    private var subscriptions = Set<AnyCancellable>()
    init(playback: PlaybackController) {
        context = playback.context; phase = playback.phase; wantsToPlay = playback.wantsToPlay
        playbackRate = playback.playbackRate
        playback.$playbackRate.removeDuplicates().sink { [weak self] in self?.playbackRate = $0 }.store(in: &subscriptions)
        playback.$context.removeDuplicates().sink { [weak self] in self?.context = $0 }.store(in: &subscriptions)
        playback.$phase.removeDuplicates().sink { [weak self] in self?.phase = $0 }.store(in: &subscriptions)
        playback.$wantsToPlay.removeDuplicates().sink { [weak self] in self?.wantsToPlay = $0 }.store(in: &subscriptions)
    }
}

private struct PlaybackPositionView: View {
    @ObservedObject var playback: PlaybackController
    @State private var seeking = false
    @State private var proposedTime = 0.0
    var body: some View {
        if let duration = MediaDuration.validated(playback.duration), duration > 0 {
            VStack(spacing: 8) {
                Slider(value: Binding(get: { PlayerTimePresentation.clampedPosition(seeking ? proposedTime : playback.elapsed, duration: duration) }, set: { proposedTime = PlayerTimePresentation.clampedPosition($0, duration: duration) }), in: 0...duration) { editing in
                    seeking = editing
                    if !editing { playback.seek(to: proposedTime) }
                }
                .accessibilityLabel("Playback position")
                .accessibilityValue(PlayerTimePresentation.spokenPosition(playback.elapsed, duration: duration, rate: playback.playbackRate))
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: playback.skip(by: playback.skipForwardInterval)
                    case .decrement: playback.skip(by: -playback.skipBackInterval)
                    @unknown default: break
                    }
                }
                HStack {
                    Text(PlayerTimePresentation.clock(seeking ? proposedTime : playback.elapsed))
                    Spacer()
                    Text("−" + PlayerTimePresentation.clock(duration - PlayerTimePresentation.clampedPosition(seeking ? proposedTime : playback.elapsed, duration: duration)))
                }.font(.caption.monospacedDigit()).foregroundStyle(Color.funstonSecondaryText).accessibilityHidden(true)
            }
            .onAppear { proposedTime = playback.elapsed }
            .onChange(of: playback.elapsed) { _, value in if !seeking { proposedTime = value } }
            .onChange(of: playback.context?.track.id) { _, _ in seeking = false }
        }
    }
}

enum PlayerTimePresentation {
    static func clampedPosition(_ value: Double, duration: Double) -> Double {
        guard let duration = MediaDuration.validated(duration) else { return 0 }
        return min(duration, MediaDuration.validated(value) ?? 0)
    }

    static func clock(_ seconds: Double) -> String {
        guard let value = MediaDuration.validated(seconds) else { return "—" }
        let total = Int64(value)
        return String(format: "%lld:%02lld", total / 60, total % 60)
    }

    static func spoken(_ seconds: Double) -> String {
        guard let value = MediaDuration.validated(seconds) else { return "Time unavailable" }
        // Integer Duration construction avoids floating-point conversion overflow.
        return Duration.seconds(Int64(value)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    /// The position slider's value: "4 minutes, 12 seconds of 28 minutes, 57 seconds,
    /// 25 minutes left". Time left is listening time, so it shrinks at faster speeds.
    static func spokenPosition(_ elapsed: Double, duration: Double, rate: Double) -> String {
        let position = clampedPosition(elapsed, duration: duration)
        let speed = rate.isFinite && rate > 0 ? rate : 1
        let remaining = spokenRemaining((duration - position) / speed)
        // Mid-sentence, "Less than a minute left" loses its capital.
        return "\(spoken(position)) of \(spoken(duration)), \(remaining.prefix(1).lowercased() + remaining.dropFirst())"
    }

    /// "24 minutes left". Whole minutes are enough to decide whether to keep listening.
    static func spokenRemaining(_ seconds: Double) -> String {
        guard let value = MediaDuration.validated(seconds) else { return "Time unavailable" }
        guard let minutes = roundedMinutes(value) else { return "Less than a minute left" }
        return minutes + " left"
    }

    /// "12 minutes played", for a recording whose length isn't known.
    static func spokenPlayed(_ seconds: Double) -> String {
        guard let value = MediaDuration.validated(seconds) else { return "Time unavailable" }
        guard let minutes = roundedMinutes(value) else { return "Less than a minute played" }
        return minutes + " played"
    }

    private static func roundedMinutes(_ seconds: Double) -> String? {
        let minutes = Int64((seconds / 60).rounded())
        guard minutes > 0 else { return nil }
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }
}

struct DownloadButton: View {
    let downloads: DownloadManager
    let artifact: ArtifactSummary
    let file: ArchiveFile
    var noun = "Recording"
    var compact = false
    @State private var record: DownloadRecord?
    @State private var subscription: AnyCancellable?
    @State private var isVisible = false
    @Environment(\.accessibilityShowBorders) private var showBorders
    private var identity: DownloadButtonIdentity { DownloadButtonIdentity(identifier: artifact.identifier, fileName: file.name) }
    private var label: String {
        switch record?.state {
        case .completed: "Downloaded"
        case .downloading: progressValue.isEmpty ? "Downloading" : "Downloading, \(Int(min(100, max(0, Double(record?.receivedBytes ?? 0) / Double(record?.totalBytes ?? record?.expectedBytes ?? 1) * 100)))) percent"
        case .queued: "Download queued"
        case .failed, .missing, .cancelled: "Retry Download"
        case nil: "Download \(noun)"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if record?.state == .completed {
                if compact {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 23))
                            .foregroundStyle(.tint).frame(width: 48, height: 48)
                        Text("Downloaded").font(.caption).foregroundStyle(Color.funstonSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Downloaded")
                        .accessibilityHint("Available offline. Manage this download in Downloads.")
                        .accessibilityIdentifier("player.downloaded")
                } else {
                    Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.tint)
                        .accessibilityElement(children: .ignore).accessibilityLabel("Downloaded")
                        .accessibilityHint("Available offline. Manage this download in Downloads.")
                }
            } else if compact {
                Button {
                    Task { await downloads.start(identifier: artifact.identifier, artifactTitle: artifact.title, file: file) }
                } label: {
                    VStack(spacing: 6) {
                        Group {
                            if record?.state == .downloading {
                                if let total = record?.totalBytes ?? record?.expectedBytes, total > 0 {
                                    ZStack {
                                        Circle().stroke(.secondary.opacity(0.2), lineWidth: 3)
                                        Circle().trim(from: 0, to: min(1, max(0, Double(record?.receivedBytes ?? 0) / Double(total))))
                                            .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                            .rotationEffect(.degrees(-90))
                                    }.frame(width: 24, height: 24)
                                } else { ProgressView() }
                            } else {
                                Image(systemName: downloadSymbol).font(.system(size: 23))
                            }
                        }.frame(width: 48, height: 48)
                            .overlay { Circle().strokeBorder(.primary.opacity(showBorders ? 0.55 : 0), lineWidth: 2) }
                        Text(compactTitle).font(.caption).foregroundStyle(Color.funstonSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel(record == nil ? "Download" : label)
                .accessibilityValue("")
                .accessibilityHint(record?.errorMessage ?? "Download this recording for offline listening.")
                .accessibilityIdentifier("player.download")
                .disabled(record?.state == .completed || record?.state == .downloading || record?.state == .queued)
            } else {
                Button {
                    Task { await downloads.start(identifier: artifact.identifier, artifactTitle: artifact.title, file: file) }
                } label: {
                    HStack {
                        if record?.state == .downloading { downloadProgress }
                        else { Image(systemName: "arrow.down.circle") }
                        Text(label)
                    }
                }.accessibilityLabel(label)
                .buttonStyle(.bordered).controlSize(.large)
                .disabled(record?.state == .completed || record?.state == .downloading || record?.state == .queued)
                if let message = record?.errorMessage { Text(message).font(.caption).foregroundStyle(Color.funstonSecondaryText) }
            }
        }
        .onAppear { isVisible = true; bindRecord() }
        .onChange(of: identity) { _, _ in if isVisible { bindRecord() } }
        .onDisappear { isVisible = false; subscription = nil }
    }

    @ViewBuilder private var downloadProgress: some View {
        if let total = record?.totalBytes ?? record?.expectedBytes, total > 0 {
            ZStack {
                Circle().stroke(.secondary.opacity(0.2), lineWidth: 3)
                Circle().trim(from: 0, to: min(1, max(0, Double(record?.receivedBytes ?? 0) / Double(total))))
                    .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
            }.frame(width: 24, height: 24)
        } else { ProgressView() }
    }

    private var downloadSymbol: String {
        switch record?.state {
        case .completed: "checkmark.circle.fill"
        case .queued: "clock.arrow.circlepath"
        case .failed, .missing, .cancelled: "arrow.clockwise.circle"
        default: "arrow.down.circle"
        }
    }

    private var compactTitle: String {
        switch record?.state {
        case .completed: "Downloaded"
        case .downloading: progressValue.isEmpty ? "Downloading" : progressValue
        case .queued: "Queued"
        case .failed, .missing, .cancelled: "Retry"
        case nil: "Download"
        }
    }

    private var progressValue: String {
        guard record?.state == .downloading,
              let total = record?.totalBytes ?? record?.expectedBytes, total > 0 else { return "" }
        return min(1, max(0, Double(record?.receivedBytes ?? 0) / Double(total))).formatted(.percent.precision(.fractionLength(0)))
    }

    private func bindRecord() {
        subscription = nil
        record = nil
        let identity = identity
        subscription = downloads.$records
            .map { records in records.first { $0.identifier == identity.identifier && $0.fileName == identity.fileName } }
            .removeDuplicates()
            .sink { record = $0 }
    }
}

private struct DownloadButtonIdentity: Hashable {
    let identifier: String
    let fileName: String
}

struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView { AVRoutePickerView() }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// Sleep timer choices in a native menu. The remaining time updates once a
/// minute, and only while a countdown is running.
struct SleepTimerMenu: View {
    @ObservedObject var timer: SleepTimer
    var compact = false
    @Environment(\.accessibilityShowBorders) private var showBorders
    private static let refreshInterval: TimeInterval = 60

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.refreshInterval)) { context in
            Menu {
                ForEach(SleepTimer.choices, id: \.self) { duration in
                    Button(SleepTimer.spoken(duration).capitalizedFirstLetter) { timer.start(after: duration) }
                }
                Button("End of This Recording") { timer.stopAtEndOfRecording() }
                if timer.setting != .off {
                    Button("Turn Off Sleep Timer", role: .destructive) { timer.turnOff() }
                }
            } label: {
                if compact {
                    VStack(spacing: 6) {
                        Image(systemName: timer.setting == .off ? "moon.zzz" : "moon.zzz.fill")
                            .font(.system(size: 23)).frame(width: 48, height: 48)
                            .overlay { Circle().strokeBorder(.primary.opacity(showBorders ? 0.55 : 0), lineWidth: 2) }
                        Text(timer.setting == .endOfRecording ? "End" : visibleTitle(at: context.date))
                            .font(.caption).foregroundStyle(Color.funstonSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity).contentShape(Rectangle())
                } else {
                    Label(visibleTitle(at: context.date), systemImage: timer.setting == .off ? "moon.zzz" : "moon.zzz.fill")
                        .font(.subheadline).frame(minHeight: 44)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel("Sleep timer")
            .accessibilityValue(spokenValue(at: context.date))
            .accessibilityIdentifier("player.sleepTimer")
        }
    }

    private func visibleTitle(at date: Date) -> String {
        switch timer.setting {
        case .off: "Sleep"
        case .until: "\(timer.minutesRemaining(at: date) ?? 0) min"
        case .endOfRecording: "End of recording"
        }
    }

    private func spokenValue(at date: Date) -> String {
        switch timer.setting {
        case .off:
            return "Off"
        case .until:
            let minutes = timer.minutesRemaining(at: date) ?? 0
            return minutes == 1 ? "1 minute left" : "\(minutes) minutes left"
        case .endOfRecording:
            return "Stops at the end of this recording"
        }
    }
}

private extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}

/// Modeled on the iOS 26 Podcasts speed popover and the Camera zoom dial: a
/// small popover above the button holding one number line. Ticks mark tenths,
/// labels mark the halves, the current speed reads out above the pointer, and
/// a tortoise and hare step by a tenth. The line is one adjustable element
/// for VoiceOver, with the labeled stops as custom actions.
@MainActor
struct PlaybackSpeedPopover: View {
    @ObservedObject var playback: PlaybackController
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var collectionOverride = false
    @State private var contentHeight: CGFloat = 0

    static let speedRange: ClosedRange<Double> = 0.5...3
    static let speedStep = 0.1
    private static let contentPadding: CGFloat = 16
    private static let sectionSpacing: CGFloat = 12
    private static let popoverWidth = SpeedDial.naturalWidth(for: speedRange, step: speedStep) + 2 * contentPadding

    private var rate: Double { playback.playbackRate }

    /// Accessibility sizes outgrow a popover, so the same controls get a
    /// full-width sheet that fits its content.
    var body: some View {
        if typeSize.isAccessibilitySize {
            ScrollView {
                controls
                    .frame(maxWidth: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .presentationCompactAdaptation(.sheet)
            .presentationDetents([.height(contentHeight), .large])
            .presentationDragIndicator(.visible)
        } else {
            controls
                .frame(width: Self.popoverWidth)
                .presentationCompactAdaptation(.popover)
        }
    }

    private var controls: some View {
        VStack(spacing: Self.sectionSpacing) {
            if let collection = playback.context?.artifact.collections.first {
                Toggle("Remember for this collection", isOn: $collectionOverride)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHint(collection)
                    .onChange(of: collectionOverride) { _, enabled in
                        if enabled { playback.setPlaybackSpeed(rate, forCollection: true) }
                        else { playback.useGlobalPlaybackSpeed() }
                    }
                Divider()
            }
            SpeedDial(rate: rate, range: Self.speedRange, step: Self.speedStep, set: set)
                .dynamicTypeSize(...SpeedDial.largestTextSize)
            Text("Playback speed")
                .font(.caption)
                .foregroundStyle(Color.funstonSecondaryText)
                .accessibilityHidden(true)
        }
        .padding(Self.contentPadding)
        .onAppear { collectionOverride = playback.hasCollectionSpeedOverride }
    }

    private func set(_ speed: Double) {
        let snapped = (speed / Self.speedStep).rounded() * Self.speedStep
        playback.setPlaybackSpeed(PlaybackSpeedPreference.clamped(snapped), forCollection: collectionOverride)
    }
}

/// A number line of tenth-step ticks with a label at every half. The current
/// speed is the tall pointer, read out above it; drag or tap along the line to
/// move it, or tap the tortoise and hare to step by a tenth.
private struct SpeedDial: View {
    let rate: Double
    let range: ClosedRange<Double>
    let step: Double
    let set: (Double) -> Void

    @ScaledMetric(relativeTo: .footnote) private var textRowHeight: CGFloat = 20
    @State private var readoutWidth: CGFloat = 0
    @State private var lineWidth: CGFloat = 0

    private static let labelInterval = 0.5
    private static let tickSpacing: CGFloat = 8
    private static let tickWidth: CGFloat = 2
    private static let tickHeight: CGFloat = 14
    private static let labeledTickHeight: CGFloat = 22
    private static let indicatorWidth: CGFloat = 4
    private static let indicatorHeight: CGFloat = 34
    private static let tickOpacity = 0.3
    private static let labeledTickOpacity = 0.55
    private static let minTouchTarget: CGFloat = 44
    /// The tortoise and hare stop growing here so the ticks between them keep room to drag.
    private static let largestGlyphSize = DynamicTypeSize.xxxLarge
    /// The readout and stop labels stop growing here. In the accessibility-size
    /// sheet each half stop gets 54 points; footnote at this size keeps a
    /// three-digit label under 41 points, so neighbours keep an 18-point gap.
    /// One size larger, the labels run together.
    static let largestTextSize = DynamicTypeSize.accessibility1

    /// Ticks at their natural spacing, plus the pointer's half-widths at the ends
    /// and a touch target for each nudge.
    static func naturalWidth(for range: ClosedRange<Double>, step: Double) -> CGFloat {
        CGFloat(tickCount(for: range, step: step) - 1) * tickSpacing + indicatorWidth + 2 * minTouchTarget
    }

    private static func tickCount(for range: ClosedRange<Double>, step: Double) -> Int {
        Int(((range.upperBound - range.lowerBound) / step).rounded()) + 1
    }

    private var tickCount: Int { Self.tickCount(for: range, step: step) }
    private var labeledStops: [Double] { Array(stride(from: range.lowerBound, through: range.upperBound, by: Self.labelInterval)) }
    private var readout: String { "\(rate.formatted())×" }

    var body: some View {
        HStack(spacing: 0) {
            nudge(symbol: "tortoise.fill", by: -step)
            line
            nudge(symbol: "hare.fill", by: step)
        }
        .sensoryFeedback(.selection, trigger: rate)
    }

    private var line: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                Text(readout)
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.tint)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { readoutWidth = $0 }
                    .position(x: readoutX(in: geometry.size.width), y: geometry.size.height / 2)
            }
            .frame(height: textRowHeight)
            GeometryReader { geometry in
                let width = geometry.size.width
                let midY = geometry.size.height / 2
                ForEach(0..<tickCount, id: \.self) { index in
                    let value = range.lowerBound + Double(index) * step
                    let labeled = isLabeled(value)
                    Capsule()
                        .fill(Color(uiColor: .label).opacity(labeled ? Self.labeledTickOpacity : Self.tickOpacity))
                        .frame(width: Self.tickWidth, height: labeled ? Self.labeledTickHeight : Self.tickHeight)
                        .position(x: x(for: value, in: width), y: midY)
                }
                Capsule()
                    .fill(Color(uiColor: .label))
                    .frame(width: Self.indicatorWidth, height: Self.indicatorHeight)
                    .position(x: x(for: rate, in: width), y: midY)
            }
            .frame(height: Self.minTouchTarget)
            GeometryReader { geometry in
                ForEach(labeledStops, id: \.self) { value in
                    Text(value == 1 ? "1×" : value.formatted())
                        .font(.footnote.weight(isCurrent(value) ? .semibold : .regular))
                        .monospacedDigit()
                        .foregroundStyle(isCurrent(value) ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.funstonSecondaryText))
                        .fixedSize()
                        .position(x: x(for: value, in: geometry.size.width), y: geometry.size.height / 2)
                }
            }
            .frame(height: textRowHeight)
        }
        .animation(.snappy, value: rate)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { drag in
            set(value(at: drag.location.x, in: lineWidth))
        })
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { lineWidth = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback speed")
        .accessibilityValue("\(rate.formatted()) times")
        .accessibilityIdentifier("player.speed.adjustable")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(rate + step)
            case .decrement: set(rate - step)
            @unknown default: break
            }
        }
        .accessibilityActions {
            ForEach(labeledStops, id: \.self) { value in
                Button("\(value.formatted()) times") { set(value) }
            }
        }
    }

    private func isLabeled(_ value: Double) -> Bool {
        abs(value / Self.labelInterval - (value / Self.labelInterval).rounded()) < step / 2
    }

    private func isCurrent(_ value: Double) -> Bool { abs(rate - value) < step / 2 }

    /// The pointer is centered half a pointer in from each end so the extremes aren't clipped.
    private func x(for value: Double, in width: CGFloat) -> CGFloat {
        let inset = Self.indicatorWidth / 2
        let fraction = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
        return inset + CGFloat(fraction) * (width - 2 * inset)
    }

    /// The readout follows the pointer but stays inside the line.
    private func readoutX(in width: CGFloat) -> CGFloat {
        min(max(x(for: rate, in: width), readoutWidth / 2), width - readoutWidth / 2)
    }

    private func value(at x: CGFloat, in width: CGFloat) -> Double {
        let inset = Self.indicatorWidth / 2
        let fraction = Double(min(max((x - inset) / max(width - 2 * inset, 1), 0), 1))
        return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }

    /// VoiceOver steps through the adjustable line instead, so the nudges are touch-only.
    private func nudge(symbol: String, by delta: Double) -> some View {
        let disabled = delta < 0 ? rate <= range.lowerBound : rate >= range.upperBound
        return Button { set(rate + delta) } label: {
            Image(systemName: symbol)
                .font(.body)
                .dynamicTypeSize(...Self.largestGlyphSize)
                .foregroundStyle(Color.funstonSecondaryText)
                .frame(minWidth: Self.minTouchTarget, minHeight: Self.minTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? Self.labeledTickOpacity : 1)
        .accessibilityHidden(true)
    }
}

@MainActor
struct PlaybackSpeedPreference {
    private let defaults: UserDefaults
    private static let globalKey = "playback.speed"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(3, max(0.5, (value * 100).rounded() / 100))
    }
    func rate(collection: String? = nil) -> Double {
        let key = collection.map { "playback.speed.collection." + $0 }
        let value = key.flatMap { defaults.object(forKey: $0) as? Double }
            ?? SettingsStore.playbackSpeed(defaults: defaults)
        return Self.clamped(value)
    }
    func set(_ value: Double, collection: String? = nil) {
        if let collection { defaults.set(Self.clamped(value), forKey: "playback.speed.collection." + collection) }
        else { SettingsStore.setPlaybackSpeed(value, defaults: defaults) }
    }
    func hasOverride(collection: String) -> Bool { defaults.object(forKey: "playback.speed.collection." + collection) != nil }
    func removeOverride(collection: String) { defaults.removeObject(forKey: "playback.speed.collection." + collection) }
}
