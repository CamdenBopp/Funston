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
                            transport("Back 15 seconds", symbol: "gobackward.15") { playback.skip(by: -15) }
                            Spacer()
                            Button { playback.togglePlayback() } label: {
                                Image(systemName: presentation.showsPauseControl ? "pause.fill" : "play.fill")
                                    .font(.system(size: 36, weight: .semibold)).frame(width: 88, height: 88)
                            }.accessibilityLabel(presentation.showsPauseControl ? "Pause" : "Play")
                                .accessibilityValue(presentation.phase.spokenValue)
                                .accessibilityIdentifier("player.toggle")
                            Spacer()
                            transport("Forward 15 seconds", symbol: "goforward.15") { playback.skip(by: 15) }
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
        .sheet(isPresented: $showingSpeed) { PlaybackSpeedSheet(playback: playback) }
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
                    case .increment: playback.skip(by: 15)
                    case .decrement: playback.skip(by: -15)
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

@MainActor
struct PlaybackSpeedSheet: View {
    @ObservedObject var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @State private var collectionOverride = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        NavigationStack {
            Form {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: typeSize.isAccessibilitySize ? 1 : 2)) {
                    ForEach([1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                        Button("\(speed.formatted())×") { set(speed) }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("\(speed.formatted()) times")
                            .accessibilityAddTraits(playback.playbackRate == speed ? .isSelected : [])
                    }
                }
                HStack {
                    Button { set(playback.playbackRate - 0.1) } label: { Image(systemName: "minus") }
                        .disabled(playback.playbackRate <= 0.5)
                    Spacer()
                    Text("\(playback.playbackRate.formatted())×").monospacedDigit()
                    Spacer()
                    Button { set(playback.playbackRate + 0.1) } label: { Image(systemName: "plus") }
                        .disabled(playback.playbackRate >= 3)
                }.buttonStyle(.bordered)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Playback speed")
                    .accessibilityValue("\(playback.playbackRate.formatted()) times")
                    .accessibilityIdentifier("player.speed.adjustable")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: set(playback.playbackRate + 0.1)
                        case .decrement: set(playback.playbackRate - 0.1)
                        @unknown default: break
                        }
                    }
                if let collection = playback.context?.artifact.collections.first {
                    Toggle("Remember speed for this collection", isOn: $collectionOverride)
                        .accessibilityHint(collection)
                        .onChange(of: collectionOverride) { _, enabled in
                            if enabled { playback.setPlaybackSpeed(playback.playbackRate, forCollection: true) }
                            else { playback.useGlobalPlaybackSpeed() }
                        }
                }
            }.navigationTitle("Playback Speed").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.onAppear { collectionOverride = playback.hasCollectionSpeedOverride }
    }
    private func set(_ speed: Double) { playback.setPlaybackSpeed(speed, forCollection: collectionOverride) }
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
            ?? defaults.object(forKey: Self.globalKey) as? Double ?? 1
        return Self.clamped(value)
    }
    func set(_ value: Double, collection: String? = nil) {
        defaults.set(Self.clamped(value), forKey: collection.map { "playback.speed.collection." + $0 } ?? Self.globalKey)
    }
    func hasOverride(collection: String) -> Bool { defaults.object(forKey: "playback.speed.collection." + collection) != nil }
    func removeOverride(collection: String) { defaults.removeObject(forKey: "playback.speed.collection." + collection) }
}
