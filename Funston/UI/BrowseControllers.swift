import UIKit
import Combine
import QuickLook

@MainActor
final class SearchController: FunstonListController, UISearchResultsUpdating, UISearchBarDelegate {
    private let repository: CachingArchiveRepository
    private let collection: ArchiveCollection?
    private let open: (ArtifactSummary) -> Void
    private let search = UISearchController(searchResultsController: nil)
    private var scope: MediaType = .all
    private var items: [ArtifactSummary] = []
    private var pages: [Int: SearchPage] = [:]
    private var page: SearchPage? { pages[pages.keys.max() ?? 1] }
    private var task: Task<Void, Never>?
    private var generation = 0
    private var loading = false
    private var refreshing = false
    private var failures: [Int: String] = [:]
    private var stalePages = Set<Int>()
    private var firstFailure: (page: Int, message: String)? {
        guard let page = failures.keys.min(), let message = failures[page] else { return nil }
        return (page, message)
    }
    private var requestKey: String?

    convenience init(environment: AppEnvironment, collection: ArchiveCollection? = nil, open: @escaping (ArtifactSummary) -> Void) {
        self.init(repository: environment.repository, collection: collection, open: open)
    }

    init(repository: CachingArchiveRepository, collection: ArchiveCollection? = nil, open: @escaping (ArtifactSummary) -> Void) {
        self.repository = repository; self.collection = collection; self.open = open
        super.init(title: collection?.title ?? "Search")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { task?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        search.searchBar.delegate = self
        search.searchBar.placeholder = collection == nil ? "Search the Internet Archive" : "Search this collection"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        updateFilter()
        if collection != nil { submit(debounce: false) }
        else { showMessage("Search the Internet Archive") }
    }

    func updateSearchResults(for searchController: UISearchController) { submit(debounce: true) }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { submit(debounce: false, force: true) }

    private func updateFilter() {
        let actions = [MediaType.all, .audio, .movies, .texts, .image, .software, .collection].map { type in
            UIAction(title: type.title, state: scope == type ? .on : .off) { [weak self] _ in
                self?.scope = type; self?.updateFilter(); self?.submit(debounce: false)
            }
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: scope.title, menu: UIMenu(title: "Media type", children: actions))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Media type, \(scope.title)"
    }

    private func submit(debounce: Bool, force: Bool = false) {
        let text = search.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let request = SearchRequest(text: text, scope: scope, collection: collection?.identifier)
        let sameRequest = request.cacheKey == requestKey
        guard force || !sameRequest else { return }
        requestKey = request.cacheKey
        generation += 1
        task?.cancel()
        if !sameRequest { items = []; pages = [:]; failures = [:]; stalePages = []; apply([]) }
        failures.removeValue(forKey: 1)
        loading = false
        refreshing = false
        guard collection != nil || !text.isEmpty else {
            showMessage("Search the Internet Archive")
            return
        }
        fetch(request, debounce: debounce)
    }

    private func nextPage() {
        guard !loading, let page, page.hasMore else { return }
        let request = SearchRequest(text: search.searchBar.text ?? "", scope: scope, page: page.page + 1, collection: collection?.identifier)
        fetch(request)
    }

    private func retryPage(_ page: Int) {
        guard !loading else { return }
        fetch(SearchRequest(text: search.searchBar.text ?? "", scope: scope, page: page, collection: collection?.identifier))
    }

    private func fetch(_ request: SearchRequest, debounce: Bool = false) {
        loading = true
        failures.removeValue(forKey: request.page)
        render()
        let currentGeneration = generation
        let repository = repository
        task = Task { [weak self] in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(300)) }
                try Task.checkCancellation()
                for try await update in repository.searchUpdates(request) {
                    try Task.checkCancellation()
                    guard self?.generation == currentGeneration else { return }
                    self?.receive(update, pageNumber: request.page)
                }
                try Task.checkCancellation()
                guard self?.generation == currentGeneration else { return }
                self?.finishLoading()
            } catch is CancellationError {} catch {
                guard let self, self.generation == currentGeneration, !Task.isCancelled else { return }
                self.loading = false; self.refreshing = false; self.failures[request.page] = archiveMessage(error); self.render()
            }
        }
    }

    private func receive(_ update: RepositoryUpdate<SearchPage>, pageNumber: Int) {
        pages[pageNumber] = update.value
        if update.freshness == .stale { stalePages.insert(pageNumber) }
        else { stalePages.remove(pageNumber) }
        failures[pageNumber] = update.refreshError
        refreshing = update.isRefreshing
        items = Self.unique(pages.keys.sorted().flatMap { pages[$0]?.items ?? [] })
        render()
    }

    private func finishLoading() {
        loading = false; refreshing = false; render()
    }

    private static func unique(_ items: [ArtifactSummary]) -> [ArtifactSummary] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.identifier).inserted }
    }

    private func render() {
        clearMessage()
        if items.isEmpty {
            if pages.isEmpty, loading { showLoading() }
            else if pages.isEmpty, let failure = firstFailure {
                showMessage("Could not load results", detail: failure.message, retry: { [weak self] in self?.retryPage(failure.page) })
            } else if let failure = firstFailure {
                showMessage(stalePages.isEmpty ? "No results" : "No matches in saved results", detail: failure.message, retry: { [weak self] in self?.retryPage(failure.page) })
            } else {
                showMessage(stalePages.isEmpty ? "No results" : "No matches in saved results", detail: loading ? "Updating from Internet Archive…" : "Try different words or another media type.")
            }
        }
        var rows = items.map { FunstonRow.artifact($0, prefix: "artifact:") }
        if !items.isEmpty, !stalePages.isEmpty {
            rows.append(FunstonRow(id: "__cacheStatus", title: "Showing saved results", subtitle: refreshing ? "Updating from Internet Archive…" : nil, navigates: false))
        }
        if !items.isEmpty, let failure = firstFailure {
            rows.append(FunstonRow(id: "__retry:\(failure.page)", title: "Try Again", subtitle: failure.message))
        }
        if page?.hasMore == true {
            rows.append(FunstonRow(id: "__pagination", title: loading ? "Loading…" : "Load More", navigates: !loading))
        }
        apply(rows)
    }

    override func selected(_ id: String) {
        if id == "__pagination" { nextPage() }
        else if id.hasPrefix("__retry:"), let page = Int(id.dropFirst("__retry:".count)) { retryPage(page) }
        else if id.hasPrefix("artifact:"), let artifact = items.first(where: { $0.identifier == String(id.dropFirst("artifact:".count)) }) { open(artifact) }
    }
}

@MainActor
final class LibraryController: FunstonListController {
    private let environment: AppEnvironment
    private let open: (ArtifactSummary) -> Void
    private var subscriptions = Set<AnyCancellable>()
    init(environment: AppEnvironment, open: @escaping (ArtifactSummary) -> Void) {
        self.environment = environment; self.open = open
        super.init(title: "Library")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        environment.$saved.combineLatest(environment.$libraryError).sink { [weak self] saved, error in
            guard let self else { return }
            self.clearMessage()
            var rows = saved.map { FunstonRow.artifact($0, prefix: "saved:") }
            if let error, !saved.isEmpty { rows.append(FunstonRow(id: "__libraryRetry", title: "Try Again", subtitle: "Library could not be updated. " + error)) }
            self.apply(rows)
            if let error, saved.isEmpty { self.showMessage("Library could not be loaded", detail: error, retry: { [weak self] in Task { await self?.environment.reloadLibrary() } }) }
            else if saved.isEmpty { self.showMessage("Nothing saved yet", detail: "Tap Save on any item to keep it here.") }
        }.store(in: &subscriptions)
    }
    override func selected(_ id: String) {
        if id == "__libraryRetry" { Task { await environment.reloadLibrary() }; return }
        guard id.hasPrefix("saved:") else { return }
        if let artifact = environment.saved.first(where: { $0.identifier == String(id.dropFirst(6)) }) { open(artifact) }
    }
    override func configure(_ cell: UICollectionViewListCell, row: FunstonRow) {
        super.configure(cell, row: row)
        if row.id == "__libraryRetry" { cell.accessories = [] }
    }
}

@MainActor
final class DownloadsController: FunstonListController {
    private let environment: AppEnvironment
    private let open: (ArtifactSummary) -> Void
    private var subscription: AnyCancellable?
    private var records: [DownloadRecord] = []
    private var projection = DownloadRowProjection()
    init(environment: AppEnvironment, open: @escaping (ArtifactSummary) -> Void) {
        self.environment = environment; self.open = open
        super.init(title: "Downloads")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subscription = environment.downloads.$records.sink { [weak self] records in
            guard let self else { return }
            self.records = records
            self.clearMessage()
            let update = self.projection.update(records)
            if update.replacesContents { self.apply(update.rows) }
            else { self.updateRows(update.rows) }
            if records.isEmpty { self.showMessage("No downloads", detail: "Downloaded files play and open without a connection.") }
        }
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        subscription = nil
    }
    override func selected(_ id: String) {
        guard let record = records.first(where: { $0.key == id }) else { return }
        let controller = DownloadDetailController(environment: environment, record: record, open: open)
        navigationController?.pushViewController(controller, animated: true)
    }
}

/// Formats only records whose content changed. Structural edits alone rebuild row identities.
struct DownloadRowProjection {
    struct Update {
        let replacesContents: Bool
        let rows: [FunstonRow]
    }
    private var orderedKeys: [String] = []
    private var recordsByKey: [String: DownloadRecord] = [:]

    mutating func update(_ records: [DownloadRecord]) -> Update {
        var seen = Set<String>()
        let uniqueRecords = records.filter { seen.insert($0.key).inserted }
        let keys = uniqueRecords.map(\.key)
        let structuralChange = keys != orderedKeys
        let changed = structuralChange ? uniqueRecords : uniqueRecords.filter { recordsByKey[$0.key] != $0 }
        orderedKeys = keys
        if structuralChange { recordsByKey = Dictionary(uniqueKeysWithValues: uniqueRecords.map { ($0.key, $0) }) }
        else { for record in changed { recordsByKey[record.key] = record } }
        return Update(replacesContents: structuralChange, rows: changed.map(Self.row))
    }

    private static func row(_ record: DownloadRecord) -> FunstonRow {
        var state = record.state == .completed ? "File available offline" : record.state.rawValue.capitalized
        if record.state == .downloading, let total = record.totalBytes, total > 0 {
            state += ", " + Double(record.receivedBytes).divided(by: Double(total)).formatted(.percent.precision(.fractionLength(0)))
        }
        return FunstonRow(
            id: record.key,
            title: DownloadPresentation.fileName(record.fileName),
            subtitle: ["From \(record.title)", state, record.errorMessage].compactMap { $0 }.joined(separator: "\n")
        )
    }
}

enum DownloadPresentation {
    static func fileName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.removingPercentEncoding ?? name
    }
}

private extension Double {
    func divided(by value: Double) -> Double { min(1, max(0, self / value)) }
}

@MainActor
final class DownloadDetailController: FunstonListController, QLPreviewControllerDataSource, @preconcurrency QLPreviewControllerDelegate {
    private let environment: AppEnvironment
    private let key: String
    private var record: DownloadRecord
    private let open: (ArtifactSummary) -> Void
    private var subscription: AnyCancellable?
    private var previewURL: URL?
    private var mutation: DownloadMutation?
    private var failedMutation: DownloadMutation?
    private var mutationError: String?
    init(environment: AppEnvironment, record: DownloadRecord, open: @escaping (ArtifactSummary) -> Void) {
        self.environment = environment; self.record = record; key = record.key; self.open = open
        super.init(title: "Download")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        subscription = environment.downloads.$records.sink { [weak self] records in
            guard let self, let record = records.first(where: { $0.key == self.key }) else { return }
            self.record = record; self.render()
        }
        render()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        subscription = nil
    }
    private func render() {
        var rows = [FunstonRow(id: "identity", title: DownloadPresentation.fileName(record.fileName), subtitle: "From \(record.title)", navigates: false),
                    FunstonRow(id: "state", title: record.state == .completed ? "File available offline" : record.state.rawValue.capitalized, subtitle: record.errorMessage, navigates: false),
                    FunstonRow(id: "artifact", title: "Open Item")]
        if let mutation {
            rows.append(FunstonRow(id: "mutation", title: mutation == .remove ? "Removing download…" : "Cancelling download…", navigates: false))
        } else { switch record.state {
        case .queued, .downloading: rows.append(FunstonRow(id: "cancel", title: "Cancel Download"))
        case .failed, .cancelled, .missing: rows.append(FunstonRow(id: "retry", title: "Retry Download"))
        case .completed:
            if ArtifactMediaPresentation.isVideoFile(record.fileName) {
                rows.append(FunstonRow(id: "watchOffline", title: "Watch Downloaded Film", symbol: "play.fill"))
            }
            if ["mp3", "m4a", "aac", "wav", "aiff", "aif"].contains((record.fileName as NSString).pathExtension.lowercased()) {
                rows.append(FunstonRow(id: "playOffline", title: "Play Downloaded Recording", symbol: "play.fill"))
            }
            rows.append(FunstonRow(id: "openLocal", title: (record.fileName as NSString).pathExtension.lowercased() == "pdf" ? "Read Downloaded PDF" : "Open Downloaded File"))
            rows.append(FunstonRow(id: "remove", title: "Remove Download"))
        } }
        if let mutationError, let failedMutation {
            rows.append(FunstonRow(id: "retryMutation", title: failedMutation == .remove ? "Retry Removing Download" : "Retry Cancelling Download", subtitle: mutationError))
        }
        apply(rows)
    }
    override func selected(_ id: String) {
        switch id {
        case "watchOffline":
            ArtifactMediaPresentation.watch(file: ArchiveFile(name: record.fileName, size: record.expectedBytes),
                summary: ArtifactSummary(identifier: record.identifier, title: record.title, mediaType: .movies),
                from: self, environment: environment, downloadedOnly: true)
        case "playOffline": environment.playback.playDownloaded(record)
        case "openLocal": openLocalFile()
        case "artifact": open(ArtifactSummary(identifier: record.identifier, title: record.title))
        case "cancel": performMutation(.cancel)
        case "retryMutation": if let failedMutation { performMutation(failedMutation) }
        case "retry": Task { await environment.downloads.retry(record, file: ArchiveFile(name: record.fileName, size: record.expectedBytes)) }
        case "remove":
            let alert = UIAlertController(title: "Remove downloaded file?", message: "Your library and saved progress will be kept.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Remove Download", style: .destructive) { [weak self] _ in
                self?.performMutation(.remove)
            })
            present(alert, animated: true)
        default: break
        }
    }

    private func performMutation(_ operation: DownloadMutation) {
        guard mutation == nil else { return }
        mutation = operation
        failedMutation = nil
        mutationError = nil
        render()
        let downloads = environment.downloads
        let record = record
        let deferRemoval = environment.playback.currentFileIsLocal(record)
        Task { [weak self] in
            do {
                switch operation {
                case .cancel: try await downloads.cancel(record)
                case .remove: try await downloads.remove(record, deferPhysicalRemoval: deferRemoval)
                }
                self?.mutation = nil
                if operation == .remove { self?.navigationController?.popViewController(animated: true) }
                else { self?.render() }
            } catch {
                self?.mutation = nil
                self?.failedMutation = operation
                self?.mutationError = error.localizedDescription
                self?.render()
            }
        }
    }

    private enum DownloadMutation { case cancel, remove }

    private func openLocalFile() {
        if (record.fileName as NSString).pathExtension.lowercased() == "pdf" {
            let summary = ArtifactSummary(identifier: record.identifier, title: record.title, mediaType: .texts)
            ArtifactMediaPresentation.open(detail: ArtifactDetail(summary: summary, files: [ArchiveFile(name: record.fileName, size: record.expectedBytes)]), from: self, environment: environment)
            return
        }
        guard let url = environment.downloads.acquireLocalURL(identifier: record.identifier, fileName: record.fileName) else {
            showError(NSError(domain: "Funston", code: 1, userInfo: [NSLocalizedDescriptionKey: "This file is no longer on your device. Download it again."]))
            return
        }
        if QLPreviewController.canPreview(url as NSURL) {
            previewURL = url
            let preview = QLPreviewController()
            preview.dataSource = self
            preview.delegate = self
            present(preview, animated: true)
        } else {
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            let downloads = environment.downloads
            share.completionWithItemsHandler = { _, _, _, _ in downloads.releaseLocalURL(url) }
            share.popoverPresentationController?.sourceView = view
            share.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            present(share, animated: true)
        }
    }

    func previewControllerDidDismiss(_ controller: QLPreviewController) {
        if let previewURL { environment.downloads.releaseLocalURL(previewURL) }
        previewURL = nil
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewURL == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        // QLPreviewController requests an item only after numberOfPreviewItems returns one.
        previewURL! as NSURL
    }
}
