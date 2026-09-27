import UIKit
import SwiftUI
import Combine

@MainActor
final class ArtifactController: ArchiveListController {
    private let environment: AppEnvironment
    private let repository: CachingArchiveRepository
    private var summary: ArtifactSummary
    private var detail: ArtifactDetail?
    private var failure: String?
    private var isStale = false
    private var isRefreshing = false
    private var task: Task<Void, Never>?
    private let savedState: ArtifactSavedState
    private var undoSave: Bool?
    private var lastOverview: OverviewIdentity?
    private var descriptionExpanded = false
    private var playbackSubscription: AnyCancellable?
    private var playbackArtifactID: String?
    private var playbackPhase: PlaybackPhase = .idle
    private let openCollection: (ArchiveCollection) -> Void

    init(environment: AppEnvironment, summary: ArtifactSummary, repository: CachingArchiveRepository? = nil, openCollection: @escaping (ArchiveCollection) -> Void) {
        self.environment = environment; self.summary = summary; self.openCollection = openCollection
        self.repository = repository ?? environment.repository
        savedState = ArtifactSavedState(identifier: summary.identifier, isSaved: environment.isSaved(summary))
        super.init(title: summary.mediaType == .texts ? "Book" : summary.mediaType == .movies ? "Film" : summary.mediaType == .audio ? "Audio" : "Artifact")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { task?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), primaryAction: UIAction { [weak self] _ in self?.share() })
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Share artifact"
        savedState.observe(environment.$saved.eraseToAnyPublisher()) { [weak self] in self?.render() }
        playbackSubscription = environment.playback.$context.combineLatest(environment.playback.$phase)
            .sink { [weak self] context, phase in
                guard let self else { return }
                let affectsHeader = playbackArtifactID == summary.identifier || context?.artifact.identifier == summary.identifier
                playbackArtifactID = context?.artifact.identifier
                playbackPhase = phase
                if affectsHeader { refreshRow("overview") }
            }
        load()
    }

    private func load() {
        task?.cancel(); failure = nil; isRefreshing = true; render()
        let repository = repository
        let identifier = summary.identifier
        task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                for try await update in repository.detailUpdates(identifier: identifier) {
                    try Task.checkCancellation()
                    guard self != nil else { return }
                    self?.receive(update)
                }
                try Task.checkCancellation()
                self?.finishLoading()
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
                self?.finishLoading(error: archiveMessage(error))
            }
        }
    }

    private func receive(_ update: RepositoryUpdate<ArtifactDetail>) {
        detail = update.value
        summary = update.value.summary
        isStale = update.freshness == .stale
        isRefreshing = update.isRefreshing
        failure = update.refreshError
        render()
    }

    private func finishLoading(error: String? = nil) {
        isRefreshing = false
        if let error { failure = error }
        render()
    }

    private func render() {
        let overview = OverviewIdentity(summary: summary, access: detail?.access, file: detail?.tracks.first?.preferredFile,
                                        mediaFile: detail.flatMap { ArtifactMediaPresentation.preferredFile(in: $0) }, saved: savedState.isSaved)
        let overviewChanged = overview != lastOverview
        lastOverview = overview
        var rows = [ArchiveRow(id: "overview", title: summary.title, navigates: false)]
        if detail == nil, failure == nil { rows.append(ArchiveRow(id: "loading", title: "Loading artifact…", navigates: false)) }
        if let detail {
            if !detail.tracks.isEmpty {
                rows.append(ArchiveRow(id: "recordingsHeading", title: "Recordings", subtitle: detail.tracks.count.formatted(), navigates: false))
                rows += detail.tracks.prefix(5).enumerated().map { index, track in
                    ArchiveRow(id: "preview:\(index)", title: track.title, subtitle: track.duration.map(PlayerTimePresentation.clock), navigates: false)
                }
                if detail.tracks.count > 5 { rows.append(ArchiveRow(id: "tracks", title: "All \(detail.tracks.count.formatted()) recordings")) }
            }
            if let description = detail.description, description.unicodeScalars.contains(where: CharacterSet.letters.contains) {
                rows.append(ArchiveRow(id: "description", title: "About", subtitle: description, navigates: false))
            }
            let provenance = [("publisher", "Publisher"), ("venue", "Venue"), ("coverage", "Recorded in"), ("language", "Language")]
            for (key, label) in provenance {
                if let values = detail.metadata[key], !values.isEmpty {
                    rows.append(ArchiveRow(id: "provenance:" + key, title: label, subtitle: values.joined(separator: ", "), navigates: false))
                }
            }
            var seenCollections = Set<String>()
            for collection in detail.summary.collections where seenCollections.insert(collection).inserted {
                rows.append(ArchiveRow(id: "collection:" + collection, title: collectionDisplayName(collection), subtitle: "From this collection"))
            }
            rows.append(ArchiveRow(id: "files", title: "Files", subtitle: detail.files.count.formatted() + " files"))
            rows.append(ArchiveRow(id: "metadata", title: "Information", subtitle: summary.identifier))
        }
        if isStale { rows.append(ArchiveRow(id: "cacheStatus", title: "Showing saved information", subtitle: isRefreshing ? "Updating from Internet Archive…" : nil, navigates: false)) }
        if let failure { rows.append(ArchiveRow(id: "retry", title: "Try Again", subtitle: failure)) }
        rows.append(ArchiveRow(id: "web", title: "Open on Internet Archive"))
        apply(rows)
        if overviewChanged { refreshRow("overview") }
    }

    override func configure(_ cell: UICollectionViewListCell, row: ArchiveRow) {
        if row.id == "overview" {
            cell.isAccessibilityElement = false
            cell.accessories = []
            let playable = detail?.access == .available && detail?.tracks.isEmpty == false
            cell.contentConfiguration = UIHostingConfiguration {
                ArtifactOverview(summary: summary, playable: playable,
                                 restricted: detail?.access == .restricted,
                                 isSaved: savedState.isSaved,
                                 saveTitle: savedState.actionTitle,
                                 downloads: environment.downloads,
                                 file: detail?.tracks.first?.preferredFile,
                                 playTitle: currentPlaybackTitle,
                                 mediaActionTitle: detail.flatMap { ArtifactMediaPresentation.actionTitle(for: $0) },
                                 openMedia: { [weak self] in
                                     guard let self, let detail else { return }
                                     ArtifactMediaPresentation.open(detail: detail, from: self, environment: environment)
                                 },
                                 play: { [weak self] in self?.play() },
                                 save: { [weak self] in self?.toggleSaved() })
            }.margins(.all, 16)
        } else if row.id.hasPrefix("preview:"), let index = Int(row.id.dropFirst(8)), let detail {
            configureRecordingCell(cell, detail: detail, index: index, environment: environment) { [weak self] in
                guard let self else { return }
                navigationController?.pushViewController(TrackController(environment: environment, detail: detail, index: index), animated: true)
            }
        } else if row.id == "description" {
            cell.isAccessibilityElement = false; cell.accessories = []
            cell.contentConfiguration = UIHostingConfiguration {
                VStack(alignment: .leading, spacing: 10) {
                    Text("About").font(.headline).accessibilityAddTraits(.isHeader)
                    Text(row.subtitle ?? "").font(.body).foregroundStyle(Color.archiveSecondaryText).lineLimit(descriptionExpanded || (row.subtitle?.count ?? 0) <= 180 ? nil : 4)
                    if (row.subtitle?.count ?? 0) > 180 {
                        Button(descriptionExpanded ? "Show Less" : "Read More") { [weak self] in
                            self?.descriptionExpanded.toggle(); self?.refreshRow("description")
                        }.frame(minHeight: 44)
                    }
                }.padding(.vertical, 8)
            }.margins(.horizontal, 20)
        } else {
            super.configure(cell, row: row)
            if row.id == "recordingsHeading" { cell.accessibilityTraits.insert(.header) }
        }
    }

    override func selected(_ id: String) {
        if id.hasPrefix("collection:") {
            let identifier = String(id.dropFirst("collection:".count))
            openCollection(ArchiveCollection(identifier: identifier, title: collectionDisplayName(identifier), description: "")); return
        }
        switch id {
        case "retry": load()
        case "tracks":
            guard let detail else { return }
            navigationController?.pushViewController(TracksController(environment: environment, detail: detail), animated: true)
        case "files":
            guard let detail else { return }
            navigationController?.pushViewController(FilesController(environment: environment, detail: detail), animated: true)
        case "metadata":
            guard let detail else { return }
            let controller = ArchiveListController(title: "Information")
            controller.apply(detail.metadata.keys.sorted().map { ArchiveRow(id: $0, title: $0, subtitle: detail.metadata[$0]?.joined(separator: "\n"), navigates: false) })
            navigationController?.pushViewController(controller, animated: true)
        case "web": UIApplication.shared.open(ArchiveURLs.item(identifier: summary.identifier))
        default: break
        }
    }

    private func play() {
        guard let detail, detail.access == .available else { return }
        if environment.playback.context?.artifact.identifier == detail.summary.identifier {
            environment.playback.togglePlayback()
            return
        }
        environment.playback.load(artifact: detail.summary, tracks: detail.tracks, trackIndex: 0)
    }

    private var currentPlaybackTitle: String {
        guard playbackArtifactID == summary.identifier else { return "Play" }
        return playbackPhase == .playing || playbackPhase == .buffering ? "Pause" : "Resume"
    }

    private func toggleSaved() {
        let previous = savedState.isSaved
        Task { [weak self] in
            guard let self else { return }
            do {
                try await environment.setSaved(summary, saved: !previous)
                undoSave = previous
                navigationItem.leftItemsSupplementBackButton = true
                navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Undo", primaryAction: UIAction { [weak self] _ in self?.undoLibraryChange() })
            } catch { showError(error) }
        }
    }

    private func undoLibraryChange() {
        guard let previous = undoSave else { return }
        Task {
            do {
                try await environment.setSaved(summary, saved: previous)
                undoSave = nil; navigationItem.leftBarButtonItem = nil
            } catch { showError(error) }
        }
    }

    private func share() {
        let controller = UIActivityViewController(activityItems: [ArchiveURLs.item(identifier: summary.identifier)], applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(controller, animated: true)
    }

    private struct OverviewIdentity: Equatable {
        let summary: ArtifactSummary
        let access: ArtifactAccess?
        let file: ArchiveFile?
        let mediaFile: ArchiveFile?
        let saved: Bool
    }
}

/// Reads the emitted value because @Published sends before the publisher's stored property changes.
@MainActor
final class ArtifactSavedState {
    private let identifier: String
    private var subscription: AnyCancellable?
    private(set) var isSaved: Bool
    var actionTitle: String { isSaved ? "Remove from Library" : "Save to Library" }

    init(identifier: String, isSaved: Bool = false) {
        self.identifier = identifier
        self.isSaved = isSaved
    }

    func observe(_ values: AnyPublisher<[ArtifactSummary], Never>, changed: @escaping () -> Void) {
        subscription = values
            .map { [identifier] artifacts in artifacts.contains { $0.identifier == identifier } }
            .removeDuplicates()
            .sink { [weak self] saved in
                guard let self else { return }
                self.isSaved = saved
                changed()
            }
    }
}

struct ArtifactOverview: View {
    let summary: ArtifactSummary
    let playable: Bool
    let restricted: Bool
    let isSaved: Bool
    let saveTitle: String
    let downloads: DownloadManager
    let file: ArchiveFile?
    var playTitle = "Play"
    var mediaActionTitle: String? = nil
    var openMedia: () -> Void = {}
    let play: () -> Void
    let save: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ArtifactArtwork(identifier: summary.identifier, size: 270, mediaType: summary.mediaType, url: summary.artworkURL)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            VStack(alignment: .leading, spacing: 7) {
                Text(summary.mediaType.title.uppercased()).font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(Color.archiveSecondaryText)
                Text(summary.title).font(.title.weight(.semibold)).accessibilityAddTraits(.isHeader)
                let identity = (summary.creators.prefix(2) + [summary.date].compactMap { $0 }).joined(separator: " · ")
                if !identity.isEmpty { Text(identity).font(.subheadline).foregroundStyle(Color.archiveSecondaryText) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { actions }
                VStack(alignment: .leading, spacing: 12) { actions }
            }
            if restricted { Text("This item has access restrictions. Visit Internet Archive for available options.").font(.callout).foregroundStyle(Color.archiveSecondaryText) }
        }
    }

    @ViewBuilder private var actions: some View {
        if playable { Button(playTitle, systemImage: playTitle == "Pause" ? "pause.fill" : "play.fill", action: play).buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("artifact.play") }
        else if let mediaActionTitle { Button(mediaActionTitle, systemImage: summary.mediaType == .movies ? "play.fill" : "book", action: openMedia).buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier(summary.mediaType == .movies ? "artifact.watch" : "artifact.read") }
        Button(isSaved ? "Saved" : "Save", systemImage: isSaved ? "bookmark.fill" : "bookmark", action: save)
            .buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("artifact.save")
            .accessibilityLabel(saveTitle)
    }
}

struct ArtifactArtwork: View {
    let identifier: String
    var size: CGFloat = 180
    var mediaType: MediaType = .unknown
    var url: URL? = nil
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else {
                ZStack {
                    Rectangle().fill(Color(uiColor: .secondarySystemBackground))
                    Image(systemName: placeholder).font(.system(size: min(size * 0.24, 52), weight: .light)).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: "\((url ?? ArchiveURLs.thumbnail(identifier: identifier)).absoluteString):\(size)") {
            image = nil
            let thumbnail = ArchiveURLs.thumbnail(identifier: identifier)
            let preferred = url ?? thumbnail
            var result = try? await ArtworkPipeline.shared.image(url: preferred, pointSize: CGSize(width: size, height: size), scale: scale)
            if result == nil, preferred != thumbnail, !Task.isCancelled {
                result = try? await ArtworkPipeline.shared.image(url: thumbnail, pointSize: CGSize(width: size, height: size), scale: scale)
            }
            guard !Task.isCancelled else { return }
            image = result?.value
        }
    }
    private var placeholder: String {
        switch mediaType {
        case .audio: "waveform"
        case .movies: "film"
        case .texts: "book.closed"
        case .image: "photo"
        case .software: "desktopcomputer"
        default: "archivebox"
        }
    }
}

@MainActor
final class TracksController: ArchiveListController {
    private let environment: AppEnvironment
    private let detail: ArtifactDetail
    init(environment: AppEnvironment, detail: ArtifactDetail) {
        self.environment = environment; self.detail = detail
        super.init(title: "Recordings")
        apply(detail.tracks.enumerated().map { index, track in
            ArchiveRow(id: String(index), title: track.title, subtitle: track.duration.map(PlayerTimePresentation.clock), navigates: false)
        })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func configure(_ cell: UICollectionViewListCell, row: ArchiveRow) {
        guard let index = Int(row.id), detail.tracks.indices.contains(index) else { return }
        configureRecordingCell(cell, detail: detail, index: index, environment: environment) { [weak self] in
            guard let self else { return }
            navigationController?.pushViewController(TrackController(environment: environment, detail: detail, index: index), animated: true)
        }
    }
}

private func collectionDisplayName(_ identifier: String) -> String {
    if let collection = ArchiveCollection.curated.first(where: { $0.identifier == identifier }) { return collection.title }
    return identifier.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
}

@MainActor
private func configureRecordingCell(_ cell: UICollectionViewListCell, detail: ArtifactDetail, index: Int, environment: AppEnvironment, information: @escaping () -> Void) {
    cell.isAccessibilityElement = false; cell.accessories = []
    cell.contentConfiguration = UIHostingConfiguration {
        RecordingRow(track: detail.tracks[index], artifactID: detail.summary.identifier, playback: environment.playback, number: index + 1, available: detail.access == .available,
                     play: {
                         if environment.playback.context?.artifact.identifier == detail.summary.identifier,
                            environment.playback.context?.track.id == detail.tracks[index].id {
                             environment.playback.play()
                         } else { environment.playback.load(artifact: detail.summary, tracks: detail.tracks, trackIndex: index) }
                     },
                     download: {
                         if let file = detail.tracks[index].preferredFile { Task { await environment.downloads.start(identifier: detail.summary.identifier, artifactTitle: detail.summary.title, file: file) } }
                     }, information: information)
    }.margins(.horizontal, 20).margins(.vertical, 10)
}

private struct RecordingRow: View {
    let track: PlayableTrack
    let artifactID: String
    let playback: PlaybackController
    let number: Int
    let available: Bool
    let play: () -> Void
    let download: () -> Void
    let information: () -> Void
    @State private var current = false
    var body: some View {
        HStack(spacing: 12) {
            Button(action: play) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Group {
                        if current { Image(systemName: "speaker.wave.2.fill").font(.caption) }
                        else { Text(number.formatted()).font(.caption.monospacedDigit()).foregroundStyle(Color.archiveSecondaryText) }
                    }.frame(minWidth: 22).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.body).foregroundStyle(.primary).multilineTextAlignment(.leading)
                        if let duration = track.duration { Text(PlayerTimePresentation.clock(duration)).font(.caption.monospacedDigit()).foregroundStyle(Color.archiveSecondaryText) }
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!available)
                .accessibilityLabel(track.title)
                .accessibilityValue(([current ? "Current recording" : nil, track.duration.map(PlayerTimePresentation.spoken)].compactMap { $0 }).joined(separator: ". "))
                .accessibilityHint(available ? "Plays recording" : "Recording unavailable")
                .accessibilityIdentifier("recording.play.\(number - 1)")
                .accessibilityAction(named: "Recording information", information)
            Menu {
                if available { Button("Download recording", systemImage: "arrow.down.circle", action: download) }
                Button("Recording information", systemImage: "info.circle", action: information)
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .accessibilityLabel("More actions for \(track.title)")
        }
        .onReceive(playback.$context.map { $0?.artifact.identifier == artifactID && $0?.track.id == track.id }.removeDuplicates()) { current = $0 }
    }
}

@MainActor
final class TrackController: ArchiveListController {
    private let environment: AppEnvironment
    private let detail: ArtifactDetail
    private let index: Int
    init(environment: AppEnvironment, detail: ArtifactDetail, index: Int) {
        self.environment = environment; self.detail = detail; self.index = index
        super.init(title: "Recording")
        var rows = [ArchiveRow(id: "title", title: detail.tracks[index].title, navigates: false)]
        if detail.access == .available {
            rows += [ArchiveRow(id: "play", title: "Play", symbol: "play.fill"), ArchiveRow(id: "download", title: "Download Recording", symbol: "arrow.down.circle")]
        }
        rows += detail.tracks[index].candidates.enumerated().map { offset, file in
            ArchiveRow(id: "file:\(offset)", title: file.format ?? file.name, subtitle: file.name)
        }
        apply(rows)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func configure(_ cell: UICollectionViewListCell, row: ArchiveRow) {
        if row.id == "download", let file = detail.tracks[index].preferredFile {
            cell.isAccessibilityElement = false; cell.accessories = []
            cell.contentConfiguration = UIHostingConfiguration {
                DownloadButton(downloads: environment.downloads, artifact: detail.summary, file: file)
            }.margins(.all, 16)
        } else { super.configure(cell, row: row) }
    }
    override func selected(_ id: String) {
        if id == "play" { environment.playback.load(artifact: detail.summary, tracks: detail.tracks, trackIndex: index) }
        else if id == "download", let file = detail.tracks[index].preferredFile {
            Task { await environment.downloads.start(identifier: detail.summary.identifier, artifactTitle: detail.summary.title, file: file) }
        } else if id.hasPrefix("file:"), let offset = Int(id.dropFirst(5)) {
            navigationController?.pushViewController(FileController(environment: environment, summary: detail.summary, file: detail.tracks[index].candidates[offset], access: detail.access), animated: true)
        }
    }
}

@MainActor
final class FilesController: ArchiveListController {
    private let environment: AppEnvironment
    private let detail: ArtifactDetail
    init(environment: AppEnvironment, detail: ArtifactDetail) {
        self.environment = environment; self.detail = detail
        super.init(title: "Files")
        apply(detail.files.enumerated().map { index, file in
            ArchiveRow(id: String(index), title: file.name, subtitle: [file.source?.capitalized, file.format, file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }, file.isPrivate ? "Restricted" : nil].compactMap { $0 }.joined(separator: " · "))
        })
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func selected(_ id: String) {
        guard let index = Int(id), detail.files.indices.contains(index) else { return }
        navigationController?.pushViewController(FileController(environment: environment, summary: detail.summary, file: detail.files[index], access: detail.access), animated: true)
    }
}

@MainActor
final class FileController: ArchiveListController {
    private let environment: AppEnvironment
    private let summary: ArtifactSummary
    private let file: ArchiveFile
    init(environment: AppEnvironment, summary: ArtifactSummary, file: ArchiveFile, access: ArtifactAccess) {
        self.environment = environment; self.summary = summary; self.file = file
        super.init(title: "File")
        var rows = [ArchiveRow(id: "name", title: file.name, subtitle: file.format, navigates: false)]
        if let size = file.size { rows.append(ArchiveRow(id: "size", title: "Size", subtitle: ByteCountFormatter.string(fromByteCount: size, countStyle: .file), navigates: false)) }
        if let source = file.source { rows.append(ArchiveRow(id: "source", title: "Source", subtitle: source, navigates: false)) }
        if let original = file.original { rows.append(ArchiveRow(id: "original", title: "Derived from", subtitle: original, navigates: false)) }
        if !file.isPrivate && access == .available { rows += [ArchiveRow(id: "download", title: "Download File"), ArchiveRow(id: "open", title: "Open File"), ArchiveRow(id: "copy", title: "Copy File URL")] }
        else { rows.append(ArchiveRow(id: "restricted", title: "Restricted file", navigates: false)) }
        apply(rows)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func configure(_ cell: UICollectionViewListCell, row: ArchiveRow) {
        if row.id == "download" {
            cell.isAccessibilityElement = false; cell.accessories = []
            cell.contentConfiguration = UIHostingConfiguration {
                DownloadButton(downloads: environment.downloads, artifact: summary, file: file, noun: "File")
            }.margins(.all, 16)
        } else { super.configure(cell, row: row) }
    }
    override func selected(_ id: String) {
        switch id {
        case "download": Task { await environment.downloads.start(identifier: summary.identifier, artifactTitle: summary.title, file: file) }
        case "open": UIApplication.shared.open(ArchiveURLs.download(identifier: summary.identifier, fileName: file.name))
        case "copy": UIPasteboard.general.url = ArchiveURLs.download(identifier: summary.identifier, fileName: file.name)
        default: break
        }
    }
}
