import CarPlay
import Combine
import UIKit

/// System audio templates backed by the same queue, downloads and bookmarks as iPhone.
@MainActor
final class CarPlayController: NSObject, CPTabBarTemplateDelegate, CPNowPlayingTemplateObserver {
    let environment: AppEnvironment
    private var interfaceController: CPInterfaceController?
    let listen = CPListTemplate(title: "Listen", sections: [])
    let library = CPListTemplate(title: "Library", sections: [])
    let downloads = CPListTemplate(title: "Downloads", sections: [])
    let explore = CPListTemplate(title: "Explore", sections: [])
    private var subscriptions = Set<AnyCancellable>()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var recentTask: Task<Void, Never>?
    private var recent: [ContinueListeningItem] = []
    private var queue: CPListTemplate?

    init(environment: AppEnvironment, interfaceController: CPInterfaceController? = nil) {
        self.environment = environment
        self.interfaceController = interfaceController
        super.init()
    }

    func connect() {
        let templates = [listen, library, downloads, explore]
        let symbols = ["play.circle", "books.vertical", "arrow.down.circle", "safari"]
        for (template, symbol) in zip(templates, symbols) {
            template.tabTitle = template.title
            template.tabImage = UIImage(systemName: symbol)
        }
        let tabs = CPTabBarTemplate(templates: Array(templates.prefix(CPTabBarTemplate.maximumTabCount)))
        tabs.delegate = self
        interfaceController?.setRootTemplate(tabs, animated: false, completion: nil)
        CPNowPlayingTemplate.shared.add(self)
        environment.$saved.combineLatest(environment.$libraryError).sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.interfaceController != nil else { return }
                self.renderLibrary()
            }
        }.store(in: &subscriptions)
        environment.downloads.$records.combineLatest(environment.downloads.$loadError).sink { [weak self] _ in
            // @Published emits before assignment; render after the new value is installed.
            Task { @MainActor [weak self] in
                guard let self, self.interfaceController != nil else { return }
                self.renderDownloads()
            }
        }.store(in: &subscriptions)
        environment.playback.$context.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.interfaceController != nil else { return }
                self.renderPlayback()
            }
        }.store(in: &subscriptions)
        environment.playback.$phase.removeDuplicates().sink { [weak self] phase in
            Task { @MainActor [weak self] in
                guard let self, self.interfaceController != nil else { return }
                self.renderPlayback()
                if case .failed(let message) = phase { self.showError(message) }
            }
        }.store(in: &subscriptions)
        renderLibrary()
        renderDownloads()
        renderPlayback()
        renderExplore()
    }

    func disconnect() {
        recentTask?.cancel()
        recentTask = nil
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        subscriptions.removeAll()
        CPNowPlayingTemplate.shared.remove(self)
        interfaceController = nil
        queue = nil
        // Disconnecting the display leaves background audio playing.
    }

    func savePlaybackPosition() { environment.playback.appDidEnterBackground() }

    func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        if selectedTemplate === listen { refreshRecentListening() }
        if selectedTemplate === downloads {
            run { [weak self] in
                await self?.environment.downloads.refreshAvailability()
                self?.renderDownloads()
            }
        }
        if selectedTemplate === library { run { [weak self] in await self?.environment.reloadLibrary() } }
    }

    func refreshRecentListening() {
        recentTask?.cancel()
        let environment = environment
        recentTask = Task { [weak self] in
            do {
                let bookmarks = try await environment.store.recentPlaybackPositions(limit: ContinueListening.bookmarkLimit)
                let items = await ContinueListening.items(bookmarks: bookmarks,
                    detail: { try await environment.repository.detail(identifier: $0) },
                    download: { await environment.downloads.completedRecord(identifier: $0, fileName: $1) })
                try Task.checkCancellation()
                self?.recent = items
                self?.renderPlayback()
            } catch is CancellationError { return }
            catch { self?.showError(error.localizedDescription) }
        }
    }

    func renderLibrary() {
        if let error = environment.libraryError {
            let retry = actionItem("Try Again", detail: error) { [weak self] in
                await self?.environment.reloadLibrary()
                self?.renderLibrary()
            }
            update(library, items: [retry], empty: "Library unavailable", detail: nil)
            return
        }
        let items = environment.saved.filter { $0.mediaType == .audio && !$0.isAccessRestricted }
        update(library, items: items.prefix(CPListTemplate.maximumItemCount).map(artifactItem),
               empty: "No saved audio", detail: "Save radio or music in Funston on your iPhone.")
    }

    func renderDownloads() {
        if let error = environment.downloads.loadError {
            let retry = actionItem("Try Again", detail: error) { [weak self] in
                await self?.environment.downloads.reloadAfterFailure()
                self?.renderDownloads()
            }
            update(downloads, items: [retry], empty: "Downloads unavailable", detail: nil)
            return
        }
        let records = environment.downloads.records.filter {
            $0.state == .completed && PlaybackController.playsDownloadedAudio(fileName: $0.fileName) &&
            environment.downloads.completedLocalURL(identifier: $0.identifier, fileName: $0.fileName) != nil
        }
        let items = records.prefix(CPListTemplate.maximumItemCount).map { record in
            actionItem(record.title, detail: ArchiveMediaTitle.readable(record.fileName)) { [weak self] in
                guard let self else { return }
                try self.requireAudioPlayback()
                guard let current = await self.environment.downloads.completedRecord(identifier: record.identifier, fileName: record.fileName) else {
                    throw CarPlayError.missingDownload
                }
                try Task.checkCancellation()
                self.environment.playback.playDownloaded(current)
                self.showNowPlaying()
            }
        }
        update(downloads, items: items, empty: "No downloaded audio", detail: "Download recordings on your iPhone to listen offline.")
    }

    func renderPlayback() {
        var items: [CPListItem] = []
        let playback = environment.playback
        if let context = playback.context, playback.acceptsAudioCommands {
            let item = actionItem(context.track.title, detail: context.artifact.title) { [weak self] in
                guard let self else { return }
                try self.requireAudioPlayback()
                self.environment.playback.play()
                self.showNowPlaying()
            }
            item.isPlaying = playback.phase == .playing
            items.append(item)
        }
        items += recent.filter { !$0.summary.isAccessRestricted }.map { saved in
            let item = actionItem(saved.summary.title, detail: saved.trackTitle ?? saved.progressDescription) { [weak self] in
                guard let self else { return }
                try self.requireAudioPlayback()
                if let download = saved.download {
                    self.environment.playback.playDownloaded(download)
                } else {
                    self.environment.playback.load(artifact: saved.summary, tracks: saved.tracks,
                        trackIndex: saved.trackIndex, preferredFileName: saved.fileName)
                }
                self.showNowPlaying()
            }
            item.playbackProgress = CGFloat(saved.fractionPlayed ?? 0)
            return item
        }
        update(listen, items: Array(items.prefix(CPListTemplate.maximumItemCount)),
               empty: "Start listening", detail: "Choose audio from Library, Downloads or Explore.")
        CPNowPlayingTemplate.shared.isUpNextButtonEnabled = playback.acceptsAudioCommands && (playback.context?.tracks.count ?? 0) > 1
        CPNowPlayingTemplate.shared.upNextTitle = "Recordings"
        if let queue { renderQueue(queue) }
    }

    private func renderExplore() {
        let collections = ArchiveCollection.curated.filter { ["oldtimeradio", "etree"].contains($0.identifier) }
        let items = collections.map { collection in
            let item = actionItem(collection.title, detail: "Popular audio") { [weak self] in
                guard let self else { return }
                let template = CPListTemplate(title: collection.title, sections: [])
                self.update(template, items: [], empty: "Loading audio…", detail: nil)
                self.interfaceController?.pushTemplate(template, animated: true, completion: nil)
                await self.loadCollection(collection, into: template)
            }
            item.accessoryType = .disclosureIndicator
            return item
        }
        update(explore, items: items, empty: "No collections", detail: nil)
    }

    private func loadCollection(_ collection: ArchiveCollection, into template: CPListTemplate) async {
        do {
            let page = try await environment.repository.search(SearchRequest(scope: .audio, pageSize: 40, collection: collection.identifier))
            try Task.checkCancellation()
            let items = page.items.filter { $0.mediaType == .audio && !$0.isAccessRestricted }
            update(template, items: items.prefix(CPListTemplate.maximumItemCount).map(artifactItem),
                   empty: "No audio found", detail: nil)
        } catch {
            guard !Task.isCancelled else { return }
            let retry = actionItem("Try Again", detail: (error as? ArchiveError)?.userMessage ?? error.localizedDescription) { [weak self, weak template] in
                guard let template else { return }
                await self?.loadCollection(collection, into: template)
            }
            update(template, items: [retry], empty: "Audio unavailable", detail: nil)
        }
    }

    private func artifactItem(_ artifact: ArtifactSummary) -> CPListItem {
        let item = actionItem(artifact.title, detail: artifact.creatorDescription) { [weak self] in
            guard let self else { return }
            let detail = try await self.environment.repository.detail(identifier: artifact.identifier)
            try Task.checkCancellation()
            guard detail.access == .available, !detail.summary.isAccessRestricted, !detail.tracks.isEmpty else {
                throw CarPlayError.noAudio
            }
            let template = CPListTemplate(title: detail.summary.title, sections: [])
            self.update(template, items: self.trackItems(artifact: detail.summary, tracks: detail.tracks), empty: "No audio", detail: nil)
            self.interfaceController?.pushTemplate(template, animated: true, completion: nil)
        }
        item.accessoryType = .disclosureIndicator
        return item
    }

    func trackItems(artifact: ArtifactSummary, tracks: [PlayableTrack]) -> [CPListItem] {
        tracks.prefix(CPListTemplate.maximumItemCount).enumerated().map { index, track in
            let item = actionItem(track.title, detail: nil) { [weak self] in
                guard let self else { return }
                try self.requireAudioPlayback()
                self.environment.playback.load(artifact: artifact, tracks: tracks, trackIndex: index)
                self.showNowPlaying()
            }
            let context = environment.playback.context
            item.isPlaying = context?.artifact.identifier == artifact.identifier && context?.trackIndex == index && environment.playback.phase == .playing
            return item
        }
    }

    nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let template = CPListTemplate(title: "Recordings", sections: [])
            self.queue = template
            self.renderQueue(template)
            self.interfaceController?.pushTemplate(template, animated: true, completion: nil)
        }
    }

    private func renderQueue(_ template: CPListTemplate) {
        let context = environment.playback.context
        let items = context.map { trackItems(artifact: $0.artifact, tracks: $0.tracks) } ?? []
        update(template, items: items, empty: "No recordings", detail: nil)
    }

    private func showNowPlaying() {
        guard let interfaceController, environment.playback.context != nil,
              interfaceController.topTemplate !== CPNowPlayingTemplate.shared else { return }
        // Reuse the existing instance when returning from its recordings list.
        if interfaceController.templates.contains(where: { $0 === CPNowPlayingTemplate.shared }) {
            interfaceController.pop(to: CPNowPlayingTemplate.shared, animated: true, completion: nil)
        } else {
            interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }
    }

    private func requireAudioPlayback() throws {
        guard environment.playback.acceptsAudioCommands else { throw CarPlayError.videoActive }
    }

    private func update(_ template: CPListTemplate, items: [CPListItem], empty: String, detail: String?) {
        template.emptyViewTitleVariants = [empty]
        template.emptyViewSubtitleVariants = detail.map { [$0] } ?? []
        template.updateSections(items.isEmpty ? [] : [CPListSection(items: items)])
    }

    private func actionItem(_ title: String, detail: String?, action: @escaping @MainActor () async throws -> Void) -> CPListItem {
        let item = CPListItem(text: title, detailText: detail)
        item.handler = { [weak self] _, completion in
            guard let self else { completion(); return }
            self.run {
                defer { completion() }
                do { try Task.checkCancellation(); try await action() }
                catch is CancellationError { return }
                catch { if !Task.isCancelled { self.showError((error as? ArchiveError)?.userMessage ?? error.localizedDescription) } }
            }
        }
        return item
    }

    private func run(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        tasks[id] = Task { [weak self] in
            await operation()
            self?.tasks[id] = nil
        }
    }

    private func showError(_ message: String) {
        guard let interfaceController, interfaceController.presentedTemplate == nil else { return }
        let dismiss = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.interfaceController?.dismissTemplate(animated: true, completion: nil)
        }
        interfaceController.presentTemplate(CPAlertTemplate(titleVariants: [message], actions: [dismiss]), animated: true, completion: nil)
    }
}

private enum CarPlayError: LocalizedError {
    case noAudio, missingDownload, videoActive
    var errorDescription: String? {
        switch self {
        case .noAudio: "This item has no available audio recordings."
        case .missingDownload: "This recording is no longer downloaded. Download it again on your iPhone."
        case .videoActive: "Close video playback on your iPhone before starting audio."
        }
    }
}
