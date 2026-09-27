import SwiftUI
import AVKit
import Combine

struct FullPlayer: View {
    let playback: PlaybackController
    let downloads: DownloadManager
    @StateObject private var presentation: PlayerPresentationState
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showingQueue = false

    init(playback: PlaybackController, downloads: DownloadManager) {
        self.playback = playback
        self.downloads = downloads
        _presentation = StateObject(wrappedValue: PlayerPresentationState(playback: playback))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                if let context = presentation.context {
                    VStack(alignment: .leading, spacing: 22) {
                        ArtifactArtwork(identifier: context.artifact.identifier,
                                        size: max(140, min(geometry.size.width - 64, geometry.size.height * (typeSize.isAccessibilitySize ? 0.24 : 0.38), 360)),
                                        mediaType: context.artifact.mediaType, url: context.artifact.artworkURL)
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(context.track.title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                            Text(context.artifact.title).font(.subheadline).foregroundStyle(Color.archiveSecondaryText)
                            if presentation.phase != .playing && presentation.phase != .paused {
                                Text(presentation.phase.spokenValue).font(.caption).foregroundStyle(Color.archiveSecondaryText).accessibilityIdentifier("player.state")
                            }
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
                                    .font(.system(size: 38, weight: .semibold)).frame(width: 80, height: 76)
                            }.accessibilityLabel(presentation.showsPauseControl ? "Pause" : "Play")
                                .accessibilityValue(presentation.phase.spokenValue)
                                .accessibilityIdentifier("player.toggle")
                            Spacer()
                            transport("Forward 15 seconds", symbol: "goforward.15") { playback.skip(by: 15) }
                        }.foregroundStyle(.primary).padding(.horizontal, 18)
                        if context.tracks.count > 1 {
                            HStack {
                                Button { playback.previousTrack() } label: { Image(systemName: "backward.end.fill").frame(width: 44, height: 44) }.accessibilityLabel("Previous recording")
                                Spacer()
                                Button { showingQueue = true } label: {
                                    Label("\(context.trackIndex + 1) of \(context.tracks.count)", systemImage: "list.bullet").font(.subheadline).frame(minHeight: 44)
                                }.accessibilityLabel("Recordings, \(context.trackIndex + 1) of \(context.tracks.count)")
                                Spacer()
                                Button { playback.nextTrack() } label: { Image(systemName: "forward.end.fill").frame(width: 44, height: 44) }.accessibilityLabel("Next recording").disabled(context.trackIndex + 1 >= context.tracks.count)
                            }.font(.callout)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack {
                                DownloadButton(downloads: downloads, artifact: context.artifact, file: context.file)
                                Spacer()
                                RoutePicker().frame(width: 44, height: 44).accessibilityLabel("Audio output")
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                DownloadButton(downloads: downloads, artifact: context.artifact, file: context.file)
                                RoutePicker().frame(width: 44, height: 44).accessibilityLabel("Audio output")
                            }
                        }
                    }.padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 24).frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $showingQueue) {
            NavigationStack {
                List {
                    if let context = presentation.context {
                        ForEach(context.tracks.indices, id: \.self) { index in
                            let track = context.tracks[index]
                            Button {
                                if index == context.trackIndex { playback.play() }
                                else { playback.load(artifact: context.artifact, tracks: context.tracks, trackIndex: index) }
                                showingQueue = false
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text((index + 1).formatted()).font(.caption.monospacedDigit()).foregroundStyle(Color.archiveSecondaryText)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(track.title).foregroundStyle(.primary)
                                        if let duration = track.duration { Text(PlayerTimePresentation.clock(duration)).font(.caption).foregroundStyle(Color.archiveSecondaryText) }
                                    }
                                    Spacer(minLength: 0)
                                    if index == context.trackIndex { Image(systemName: "speaker.wave.2.fill").accessibilityHidden(true) }
                                }.padding(.vertical, 4)
                            }.accessibilityValue(index == context.trackIndex ? "Current recording" : "")
                        }
                    }
                }.navigationTitle("Recordings").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingQueue = false } } }
            }
        }
    }

    private func transport(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.title).frame(minWidth: 56, minHeight: 56) }.accessibilityLabel(label)
    }
}

/// Only transport/context changes invalidate artwork and the queue. Progress stays in its own subtree.
@MainActor
private final class PlayerPresentationState: ObservableObject {
    @Published private(set) var context: PlaybackContext?
    @Published private(set) var phase: PlaybackPhase
    @Published private(set) var wantsToPlay: Bool
    var showsPauseControl: Bool { phase.showsPauseControl(wantsToPlay: wantsToPlay) }
    private var subscriptions = Set<AnyCancellable>()
    init(playback: PlaybackController) {
        context = playback.context; phase = playback.phase; wantsToPlay = playback.wantsToPlay
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
                .accessibilityValue("\(PlayerTimePresentation.spoken(playback.elapsed)) of \(PlayerTimePresentation.spoken(duration))")
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
                }.font(.caption.monospacedDigit()).foregroundStyle(Color.archiveSecondaryText).accessibilityHidden(true)
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
}

struct DownloadButton: View {
    let downloads: DownloadManager
    let artifact: ArtifactSummary
    let file: ArchiveFile
    var noun = "Recording"
    @State private var record: DownloadRecord?
    @State private var subscription: AnyCancellable?
    @State private var isVisible = false
    private var identity: DownloadButtonIdentity { DownloadButtonIdentity(identifier: artifact.identifier, fileName: file.name) }
    private var label: String {
        switch record?.state {
        case .completed: "Downloaded"
        case .downloading: "Downloading…"
        case .queued: "Download queued"
        case .failed, .missing, .cancelled: "Retry Download"
        case nil: "Download \(noun)"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(label, systemImage: record?.state == .completed ? "checkmark.circle" : "arrow.down.circle") {
                Task { await downloads.start(identifier: artifact.identifier, artifactTitle: artifact.title, file: file) }
            }
            .buttonStyle(.bordered).controlSize(.large)
            .disabled(record?.state == .completed || record?.state == .downloading || record?.state == .queued)
            if let message = record?.errorMessage { Text(message).font(.caption).foregroundStyle(Color.archiveSecondaryText) }
        }
        .onAppear { isVisible = true; bindRecord() }
        .onChange(of: identity) { _, _ in if isVisible { bindRecord() } }
        .onDisappear { isVisible = false; subscription = nil }
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
