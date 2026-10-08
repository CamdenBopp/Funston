import SwiftUI
import Combine

struct RecordingProgress: Equatable, Sendable {
    var seconds: Double = 0
    var isPlayed = false
}

enum RecordingListeningState: Equatable {
    case unplayed, partlyPlayed(Double), played

    static func state(progress: RecordingProgress, duration: Double?) -> Self {
        if progress.isPlayed { return .played }
        guard let seconds = MediaDuration.validated(progress.seconds), seconds >= ResumePolicy.minimumResumeSeconds else { return .unplayed }
        if let duration = MediaDuration.validated(duration), ResumePolicy.isFinished(seconds, duration: duration) { return .played }
        return .partlyPlayed(seconds)
    }

    func text(duration: Double?) -> String? {
        switch self {
        case .unplayed: nil
        case .played: "Played"
        case .partlyPlayed(let seconds):
            if let duration = MediaDuration.validated(duration) {
                "\(max(1, Int((max(0, duration - seconds) / 60).rounded()))) min left"
            } else { "Partly played" }
        }
    }

    static func label(track: PlayableTrack, number: Int, count: Int, current: Bool, progress: RecordingProgress) -> String {
        var sentences = ["Recording \(number) of \(count).", "\(track.title)."]
        if current { sentences.append("Current recording.") }
        switch state(progress: progress, duration: track.duration) {
        case .unplayed: sentences.append("Not played.")
        case .played: sentences.append("Played.")
        case .partlyPlayed(let seconds):
            sentences.append("Partly played.")
            if let duration = track.duration { sentences.append("\(PlayerTimePresentation.spokenRemaining(max(0, duration - seconds))).") }
        }
        if let duration = track.duration { sentences.append("Length: \(PlayerTimePresentation.spoken(duration)).") }
        return sentences.joined(separator: " ")
    }
}

/// The parts of live playback that can change a recording row's presentation.
struct RecordingPlaybackPresentation: Equatable {
    let fileName: String?
    let preparing: Bool
    let listeningText: String?

    init(context: PlaybackContext?, phase: PlaybackPhase, elapsed: Double, identifier: String) {
        guard let context, context.artifact.identifier == identifier else {
            fileName = nil; preparing = false; listeningText = nil
            return
        }
        fileName = context.file.name
        preparing = phase == .preparing
        let progress = RecordingProgress(seconds: elapsed, isPlayed: phase == .ended)
        listeningText = preparing ? nil : RecordingListeningState.state(progress: progress, duration: context.track.duration).text(duration: context.track.duration)
    }
}

@MainActor
final class RecordingProgressState: ObservableObject {
    @Published private(set) var progress: [String: RecordingProgress] = [:]
    private let playback: PlaybackController
    private let identifier: String
    private var subscriptions = Set<AnyCancellable>()
    private var task: Task<Void, Never>?

    init(playback: PlaybackController, identifier: String) {
        self.playback = playback; self.identifier = identifier
        let changes = playback.$context.map { $0?.track.id }.removeDuplicates().map { _ in () }
        let settled = playback.$phase.removeDuplicates().filter { $0 == .paused || $0 == .ended }.map { _ in () }
        changes.merge(with: settled).receive(on: RunLoop.main).sink { [weak self] in self?.refresh() }.store(in: &subscriptions)
        // Rows show a listening state and rounded minutes, not the player clock.
        // Ignore timer ticks that leave that presentation unchanged.
        playback.$context.combineLatest(playback.$phase, playback.$elapsed)
            .map { context, phase, elapsed in
                RecordingPlaybackPresentation(context: context, phase: phase, elapsed: elapsed, identifier: identifier)
            }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        refresh()
    }
    deinit { task?.cancel() }

    func isCurrent(_ track: PlayableTrack) -> Bool {
        guard let context = playback.context, context.artifact.identifier == identifier else { return false }
        return track.candidates.contains { $0.name == context.file.name }
    }

    func value(for track: PlayableTrack) -> RecordingProgress {
        let values = track.candidates.compactMap { progress[$0.name] }
        var value = RecordingProgress(seconds: values.map(\.seconds).max() ?? 0, isPlayed: values.contains { $0.isPlayed })
        if let context = playback.context, context.artifact.identifier == identifier,
           track.candidates.contains(where: { $0.name == context.file.name }), playback.phase != .preparing {
            value.seconds = playback.elapsed
            if playback.phase == .ended { value.isPlayed = true }
        }
        return value
    }
    func setPlayed(_ track: PlayableTrack, played: Bool) {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await playback.setRecordingPlayed(identifier: identifier, track: track, played: played)
                progress = try await playback.savedRecordingProgress(identifier: identifier)
            } catch { return }
        }
    }
    private func refresh() {
        task?.cancel()
        let playback = playback, identifier = identifier
        task = Task { [weak self] in
            guard let values = try? await playback.savedRecordingProgress(identifier: identifier), !Task.isCancelled else { return }
            self?.progress = values
        }
    }
}

struct RecordingQueueView: View {
    @ObservedObject var playback: PlaybackController
    @StateObject private var progress: RecordingProgressState
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var isSearching = false
    @State private var jump = 0
    @State private var visibleRows = Set<Int>()
    @ScaledMetric(relativeTo: .caption) private var numberWidth = 32

    init(playback: PlaybackController, identifier: String) {
        self.playback = playback
        _progress = StateObject(wrappedValue: RecordingProgressState(playback: playback, identifier: identifier))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if let context = playback.context {
                        ForEach(context.tracks.indices.filter { matches(context.tracks[$0], number: $0 + 1) }, id: \.self) { index in
                            let track = context.tracks[index]
                            let current = index == context.trackIndex
                            let saved = progress.value(for: track)
                            let played = RecordingListeningState.state(progress: saved, duration: track.duration) == .played
                            Button {
                                if current { playback.play() }
                                else { playback.load(artifact: context.artifact, tracks: context.tracks, trackIndex: index) }
                                dismiss()
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text((index + 1).formatted()).font(.caption.monospacedDigit())
                                        .foregroundStyle(Color.funstonSecondaryText).frame(width: numberWidth, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(track.title).font(.body).foregroundStyle(played ? Color.funstonSecondaryText : current ? Color.accentColor : .primary)
                                        HStack(spacing: 8) {
                                            if case .unplayed = RecordingListeningState.state(progress: saved, duration: track.duration), let duration = track.duration { Text(PlayerTimePresentation.clock(duration)) }
                                            if let state = RecordingListeningState.state(progress: saved, duration: track.duration).text(duration: track.duration) { Text(state) }
                                        }.font(.caption).foregroundStyle(Color.funstonSecondaryText)
                                    }
                                    Spacer(minLength: 0)
                                    if current { Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor) }
                                    if played { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.funstonSecondaryText) }
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityLabel(RecordingListeningState.label(track: track, number: index + 1, count: context.tracks.count, current: current, progress: saved))
                                .accessibilityHint(current ? "Resumes this recording." : "Plays this recording.")
                                .accessibilityIdentifier("queue.recording.\(index)")
                                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                                .accessibilityAction(named: played ? "Mark as Unplayed" : "Mark as Played") { progress.setPlayed(track, played: !played) }
                                .swipeActions { Button(played ? "Mark as Unplayed" : "Mark as Played") { progress.setPlayed(track, played: !played) } }
                                .onAppear { visibleRows.insert(index) }
                                .onDisappear { visibleRows.remove(index) }
                                .id(index)
                        }
                    }
                }.listStyle(.plain)
                    .searchable(text: $search, isPresented: $isSearching, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a recording")
                    .searchPresentationToolbarBehavior(.avoidHidingContent)
                    .overlay {
                        if let context = playback.context, !search.isEmpty,
                           !context.tracks.indices.contains(where: { matches(context.tracks[$0], number: $0 + 1) }) {
                            ContentUnavailableView.search(text: search)
                        }
                    }
                    .navigationTitle("Recordings").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { search = ""; isSearching = false; jump += 1 } label: { Label("Current", systemImage: "scope") }
                                .accessibilityLabel("Jump to now playing").accessibilityIdentifier("queue.current")
                                .disabled(playback.context.map { visibleRows.contains($0.trackIndex) } ?? true)
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }.accessibilityIdentifier("queue.done")
                        }
                    }
                    .onChange(of: jump) { _, _ in
                        if let index = playback.context?.trackIndex { withAnimation { proxy.scrollTo(index, anchor: .center) } }
                    }
                    .task {
                        await Task.yield()
                        if let index = playback.context?.trackIndex { proxy.scrollTo(index, anchor: .center) }
                    }
            }
        }
    }
    private func matches(_ track: PlayableTrack, number: Int) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || "\(number) \(track.title)".localizedStandardContains(query)
    }
}
