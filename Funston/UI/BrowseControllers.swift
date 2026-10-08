import UIKit
import Combine
import QuickLook

@MainActor
final class SearchController: FunstonListController, UISearchResultsUpdating, UISearchBarDelegate {
    private let repository: CachingArchiveRepository
    private let settings: SettingsStore
    private var lastAppliedHideUnsupportedMedia: Bool
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
        self.init(repository: environment.repository, collection: collection, settings: environment.settings, open: open)
    }

    init(repository: CachingArchiveRepository, collection: ArchiveCollection? = nil, settings: SettingsStore = .shared, open: @escaping (ArtifactSummary) -> Void) {
        self.repository = repository; self.collection = collection; self.open = open
        self.settings = settings
        lastAppliedHideUnsupportedMedia = settings.hideUnsupportedMedia
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard lastAppliedHideUnsupportedMedia != settings.hideUnsupportedMedia else { return }
        lastAppliedHideUnsupportedMedia = settings.hideUnsupportedMedia
        // Retain the query and scope, but discard pages loaded under the old filter.
        requestKey = nil
        submit(debounce: false, force: true)
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

enum LibraryFilter: Int, CaseIterable { case all, saved, downloads }

struct LibraryItem {
    let artifact: ArtifactSummary
    let isSaved: Bool
    let downloads: [DownloadRecord]

    var downloadSummary: String? {
        guard !downloads.isEmpty else { return nil }
        return [DownloadState.completed, .downloading, .queued, .failed, .cancelled, .missing].compactMap { state in
            let count = downloads.filter { $0.state == state }.count
            return count == 0 ? nil : "\(count) \(state == .completed ? "downloaded" : state.rawValue)"
        }.joined(separator: ", ")
    }
    var accessibilityProgress: String? {
        let active = downloads.filter { $0.state == .downloading }
        guard !active.isEmpty else { return nil }
        return active.map { record in
            guard let total = record.totalBytes, total > 0 else { return "Downloading \(DownloadPresentation.fileName(record.fileName))" }
            return "\(DownloadPresentation.fileName(record.fileName)), " + Double(record.receivedBytes).divided(by: Double(total)).formatted(.percent.precision(.fractionLength(0)))
        }.joined(separator: ". ")
    }
    static func project(saved: [ArtifactSummary], downloads: [DownloadRecord], filter: LibraryFilter) -> [LibraryItem] {
        let grouped = Dictionary(grouping: downloads, by: \.identifier)
        let savedIDs = Set(saved.map(\.identifier))
        var artifacts = saved
        var seen = savedIDs
        for record in downloads where seen.insert(record.identifier).inserted {
            artifacts.append(ArtifactSummary(identifier: record.identifier, title: record.title))
        }
        return artifacts.compactMap { artifact in
            let records = grouped[artifact.identifier] ?? []
            if filter == .saved && !savedIDs.contains(artifact.identifier) { return nil }
            if filter == .downloads && records.isEmpty { return nil }
            return LibraryItem(artifact: artifact, isSaved: savedIDs.contains(artifact.identifier), downloads: records)
        }
    }
}

@MainActor
private final class LibraryFilterHeader: UICollectionReusableView {
    let segments = UISegmentedControl(items: ["All", "Saved", "Downloads"])
    override init(frame: CGRect) {
        super.init(frame: frame)
        segments.accessibilityIdentifier = "libraryFilter"
        segments.translatesAutoresizingMaskIntoConstraints = false
        addSubview(segments)
        NSLayoutConstraint.activate([
            segments.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            segments.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            segments.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            segments.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            segments.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class LibraryController: FunstonListController {
    private let environment: AppEnvironment
    private let open: (ArtifactSummary) -> Void
    private var subscriptions = Set<AnyCancellable>()
    private var filterRevision = 0
    private(set) var filter = LibraryFilter.all
    private var items: [LibraryItem] = []
    init(environment: AppEnvironment, open: @escaping (ArtifactSummary) -> Void) {
        self.environment = environment; self.open = open
        super.init(title: "Library")
        installFilter()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "gearshape"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            SettingsPresentation.present(from: self, environment: self.environment)
        })
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Settings"
        environment.$saved.combineLatest(environment.$libraryError, environment.downloads.$records, environment.downloads.$loadError)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in self?.render() }.store(in: &subscriptions)
    }
    private func installFilter() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.headerMode = .none
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, items.indices.contains(indexPath.item) else { return nil }
            return swipeActions(for: rows[indexPath.item])
        }
        collectionView.collectionViewLayout = UICollectionViewCompositionalLayout { _, layoutEnvironment in
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: layoutEnvironment)
            section.boundarySupplementaryItems = [NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(60)),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)]
            return section
        }
        collectionView.register(LibraryFilterHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: "filter")
        setSupplementaryViewProvider { [weak self] collection, kind, index in
            let header = collection.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "filter", for: index) as! LibraryFilterHeader
            guard let self else { return header }
            header.segments.selectedSegmentIndex = filter.rawValue
            header.segments.removeTarget(nil, action: nil, for: .valueChanged)
            header.segments.addTarget(self, action: #selector(changeFilter(_:)), for: .valueChanged)
            return header
        }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Decide once on reopening, after reconciliation; never change a filter under the user's focus.
        let revision = filterRevision
        Task { [weak self] in
            guard let self else { return }
            await environment.downloads.waitUntilReady()
            if revision == filterRevision && filter == .downloads && environment.downloads.loadError == nil && environment.downloads.records.isEmpty {
                filter = .all
                for header in collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader) {
                    (header as? LibraryFilterHeader)?.segments.selectedSegmentIndex = filter.rawValue
                }
            }
            render()
        }
    }
    @objc private func changeFilter(_ sender: UISegmentedControl) {
        filterRevision += 1
        filter = LibraryFilter(rawValue: sender.selectedSegmentIndex) ?? .all
        render()
    }
    private func render() {
        items = LibraryItem.project(saved: environment.saved, downloads: environment.downloads.records, filter: filter)
        clearMessage()
        var rows = items.map { item in
            var row = FunstonRow.artifact(item.artifact, prefix: "library:")
            row.accessibilityValue = item.accessibilityProgress
            row.subtitle = [row.subtitle, item.downloadSummary].compactMap { $0 }.joined(separator: "\n")
            return row
        }
        let error = environment.libraryError ?? environment.downloads.loadError
        if let error { rows.append(FunstonRow(id: "__libraryRetry", title: "Try Again", subtitle: error)) }
        apply(rows)
        if items.isEmpty && error == nil {
            showMessage(filter == .downloads ? "No downloads" : "Nothing saved yet", detail: filter == .downloads ? "Download files from an item to keep them available offline." : "Save or download an item to keep it here.")
        }
    }
    override func selected(_ id: String) {
        if id == "__libraryRetry" { Task { await environment.reloadLibrary(); await environment.downloads.reloadAfterFailure() }; return }
        guard let item = items.first(where: { "library:" + $0.artifact.identifier == id }) else { return }
        if item.downloads.isEmpty { open(item.artifact) }
        else { navigationController?.pushViewController(LibraryItemDownloadsController(environment: environment, artifact: item.artifact, open: open), animated: true) }
    }
    override func configure(_ cell: UICollectionViewListCell, row: FunstonRow) {
        super.configure(cell, row: row)
        guard let item = items.first(where: { "library:" + $0.artifact.identifier == row.id }) else { return }
        cell.accessibilityValue = item.accessibilityProgress
        cell.accessibilityCustomActions = actions(for: item).map { title in
            UIAccessibilityCustomAction(name: title) { [weak self] _ in self?.perform(title, item: item); return true }
        }
    }
    private func actions(for item: LibraryItem) -> [String] {
        var actions = [item.isSaved ? "Remove from Library" : "Save to Library"]
        if !item.downloads.isEmpty { actions += ["Delete Downloads", "Remove from Library and Delete Downloads"] }
        return actions
    }
    override func swipeActions(for row: FunstonRow) -> UISwipeActionsConfiguration? {
        guard let item = items.first(where: { "library:" + $0.artifact.identifier == row.id }) else { return nil }
        let configuration = UISwipeActionsConfiguration(actions: actions(for: item).map { title in
            UIContextualAction(style: title == "Save to Library" ? .normal : .destructive, title: title) { [weak self] _, _, done in self?.perform(title, item: item); done(true) }
        })
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
    private func perform(_ action: String, item: LibraryItem) {
        let change = { [weak self] in
            guard let self else { return }
            Task {
                do {
                    if action.contains("Delete Downloads") {
                        for record in item.downloads { try await environment.downloads.remove(record) }
                    }
                    if action != "Delete Downloads" { try await environment.setSaved(item.artifact, saved: action == "Save to Library") }
                } catch { showError(error) }
            }
        }
        if action.contains("Delete Downloads"), item.downloads.contains(where: { $0.state == .completed }) {
            let alert = UIAlertController(title: action + "?", message: "Active transfers will also be cancelled. Saved reading and listening positions will be kept.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: action, style: .destructive) { _ in change() })
            present(alert, animated: true)
        } else { change() }
    }
}

@MainActor
final class LibraryItemDownloadsController: FunstonListController {
    private let environment: AppEnvironment
    private let artifact: ArtifactSummary
    private let open: (ArtifactSummary) -> Void
    private var subscription: AnyCancellable?
    private var records: [DownloadRecord] = []
    private var projection = DownloadRowProjection()
    init(environment: AppEnvironment, artifact: ArtifactSummary, open: @escaping (ArtifactSummary) -> Void) {
        self.environment = environment; self.artifact = artifact; self.open = open
        super.init(title: artifact.title)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        subscription = environment.downloads.$records.sink { [weak self] records in
            guard let self else { return }
            self.records = records.filter { $0.identifier == artifact.identifier }
            let update = projection.update(self.records)
            if update.replacesContents { apply([FunstonRow(id: "openItem", title: "Open Item")] + update.rows) }
            else { updateRows(update.rows) }
        }
    }
    override func selected(_ id: String) {
        if id == "openItem" { open(artifact); return }
        guard let record = records.first(where: { $0.key == id }) else { return }
        navigationController?.pushViewController(DownloadDetailController(environment: environment, record: record, open: open), animated: true)
    }
    override func configure(_ cell: UICollectionViewListCell, row: FunstonRow) {
        super.configure(cell, row: row)
        guard let record = records.first(where: { $0.key == row.id }) else { return }
        cell.accessibilityValue = LibraryItem(artifact: artifact, isSaved: false, downloads: [record]).accessibilityProgress
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
        subscription = environment.downloads.$records.combineLatest(environment.downloads.$loadError).sink { [weak self] records, loadError in
            guard let self else { return }
            self.records = records
            self.clearMessage()
            let update = self.projection.update(records)
            if update.replacesContents { self.apply(update.rows) }
            else { self.updateRows(update.rows) }
            if let loadError, records.isEmpty {
                self.showMessage("Could not load downloads", detail: loadError, retry: { [weak self] in
                    Task { await self?.environment.downloads.reloadAfterFailure() }
                })
            } else if records.isEmpty {
                self.showMessage("No downloads", detail: "Downloaded files play and open without a connection.")
            }
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
        let state = record.state == .completed ? "File available offline" : record.state.rawValue.capitalized
        return FunstonRow(
            id: record.key,
            title: DownloadPresentation.fileName(record.fileName),
            subtitle: ["From \(MetadataFormatter.title(record.title))", state, record.errorMessage].compactMap { $0 }.joined(separator: "\n"),
            accessibilityValue: LibraryItem(artifact: ArtifactSummary(identifier: record.identifier, title: record.title), isSaved: false, downloads: [record]).accessibilityProgress
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
        var rows = [FunstonRow(id: "identity", title: DownloadPresentation.fileName(record.fileName), subtitle: "From \(MetadataFormatter.title(record.title))", navigates: false),
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
            let fileExtension = (record.fileName as NSString).pathExtension.lowercased()
            rows.append(FunstonRow(id: "openLocal", title: fileExtension == "pdf" ? "Read Downloaded PDF"
                                   : fileExtension == "epub" ? "Read Downloaded Book" : "Open Downloaded File"))
            rows.append(FunstonRow(id: "remove", title: "Remove Download"))
        }
        if record.state != .completed { rows.append(FunstonRow(id: "remove", title: "Remove Download")) }
        }
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
            Task { [weak self] in
                guard let self else { return }
                let lastDownload = environment.downloads.records.filter { $0.identifier == record.identifier }.count == 1
                let reason = try? await environment.store.librarySaveReason(identifier: record.identifier)
                let alert = UIAlertController(title: "Remove downloaded file?", message: "Saved reading and listening positions will be kept.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                alert.addAction(UIAlertAction(title: "Remove Download", style: .destructive) { [weak self] _ in self?.performMutation(.remove) })
                if lastDownload && reason == .viaDownload {
                    alert.addAction(UIAlertAction(title: "Remove Download and Library Item", style: .destructive) { [weak self] _ in self?.performMutation(.remove, removeMembership: true) })
                }
                present(alert, animated: true)
            }
        default: break
        }
    }

    private func performMutation(_ operation: DownloadMutation, removeMembership: Bool = false) {
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
                if removeMembership {
                    try await self?.environment.setSaved(ArtifactSummary(identifier: record.identifier, title: record.title), saved: false)
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
        if (record.fileName as NSString).pathExtension.lowercased() == "epub" {
            let summary = ArtifactSummary(identifier: record.identifier, title: record.title, mediaType: .texts)
            navigationController?.pushViewController(EPUBReaderController(
                summary: summary, file: ArchiveFile(name: record.fileName, size: record.expectedBytes),
                downloads: environment.downloads, store: environment.store), animated: true)
            return
        }
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
