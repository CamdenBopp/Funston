import UIKit
import Combine
import OSLog
import ReadiumShared
import ReadiumStreamer
import ReadiumNavigator

/// Reads a born-digital EPUB with Readium's navigator. The book is downloaded
/// first (it stays in Downloads for offline reading), then opened from the local
/// file under a lease so removing the download can't pull it out from under us.
/// Text size follows Dynamic Type and colors follow Dark Mode; Readium switches to
/// continuous scrolling while VoiceOver runs, since pages break the screen reader.
@MainActor
final class EPUBReaderController: UIViewController, EPUBNavigatorDelegate {
    private static let logger = Logger(subsystem: "com.camden.Funston", category: "Books")
    /// Readium's font size is a multiple of the book's own; body text at the
    /// default Dynamic Type size is 17 pt.
    private static let bodyPointSize: CGFloat = 17
    private static let positionSaveDelay: Duration = .seconds(1)

    private let summary: ArtifactSummary
    private let file: ArchiveFile
    private let downloads: DownloadManager
    private let store: SQLiteStore
    private var subscriptions = Set<AnyCancellable>()
    private var lease: URL?
    private var opening: Task<Void, Never>?
    private var pendingSave: Task<Void, Never>?
    private var publication: Publication?
    private var navigator: EPUBNavigatorViewController?
    private var tableOfContents: [Link] = []
    private var lastLocator: Locator?
    private lazy var readerControls = ReaderControls(reader: self, pageView: view)

    init(summary: ArtifactSummary, file: ArchiveFile, downloads: DownloadManager, store: SQLiteStore) {
        self.summary = summary; self.file = file; self.downloads = downloads; self.store = store
        super.init(nibName: nil, bundle: nil)
        title = summary.title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The navigator once the book is open; for tests.
    var bookNavigator: EPUBNavigatorViewController? { navigator }
    var contents: [Link] { tableOfContents }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "book.reader"
        navigationItem.largeTitleDisplayMode = .never
        let identifier = summary.identifier, fileName = file.name
        downloads.$records.map { records in
            records.first { $0.identifier == identifier && $0.fileName == fileName }
        }.removeDuplicates().sink { [weak self] record in
            // @Published emits before the stored array changes.
            Task { @MainActor [weak self] in self?.receive(record) }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.saveNow() }.store(in: &subscriptions)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) { (reader: EPUBReaderController, _: UITraitCollection) in
            reader.navigator?.submitPreferences(reader.preferences)
        }
        showStatus("Preparing book", detail: "It will also be saved to Downloads.")
        Task { [weak self] in
            guard let self else { return }
            await downloads.waitUntilReady()
            if let local = downloads.acquireLocalURL(identifier: identifier, fileName: fileName) {
                open(local, leased: true)
            } else {
                await downloads.start(identifier: identifier, artifactTitle: summary.title, file: file)
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveNow()
        readerControls.restore()
    }

    override func accessibilityPerformMagicTap() -> Bool { readerControls.toggle(); return true }

    nonisolated func navigator(_ navigator: Navigator, didTapAt point: CGPoint) {
        MainActor.assumeIsolated {
            guard self.navigator?.currentSelection == nil else { return }
            readerControls.tapped()
        }
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        guard parent == nil else { return }
        opening?.cancel()
        saveNow()
        if let lease { downloads.releaseLocalURL(lease); self.lease = nil }
    }

    private func receive(_ record: DownloadRecord?) {
        guard navigator == nil, opening == nil, lease == nil, let record else { return }
        switch record.state {
        case .completed:
            guard let local = downloads.acquireLocalURL(identifier: summary.identifier, fileName: file.name) else { return }
            open(local, leased: true)
        case .queued, .downloading:
            let received = ByteCountFormatter.string(fromByteCount: record.receivedBytes, countStyle: .file)
            let total = record.totalBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            showStatus("Downloading book", detail: total.map { "\(received) of \($0)" } ?? received)
        case .failed, .missing, .cancelled:
            showStatus(record.state == .cancelled ? "Download cancelled" : "Could not open book",
                       detail: record.errorMessage ?? "Try downloading this book again.", retry: true)
        }
    }

    private func open(_ url: URL, leased: Bool) {
        guard navigator == nil, opening == nil else { if leased { downloads.releaseLocalURL(url) }; return }
        lease = url
        showStatus("Opening book")
        let identifier = summary.identifier, fileName = file.name, store = store
        opening = Task { [weak self] in
            let saved: Locator?
            do {
                saved = try await store.bookLocator(identifier: identifier, fileName: fileName).flatMap { try Locator(jsonString: $0) }
            } catch {
                Self.logger.error("Saved book position unreadable: \(error.localizedDescription, privacy: .public)")
                saved = nil
            }
            let result = await Self.openPublication(at: url)
            guard let self, !Task.isCancelled else { return }
            opening = nil
            switch result {
            case .success(let publication): present(publication, at: saved)
            case .failure(let message): showStatus("Could not open book", detail: message, retry: true)
            }
        }
    }

    private enum OpenResult { case success(Publication), failure(String) }

    private static func openPublication(at url: URL) async -> OpenResult {
        guard let fileURL = FileURL(url: url) else { return .failure("The downloaded file couldn't be found.") }
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let opener = PublicationOpener(parser: DefaultPublicationParser(
            httpClient: httpClient, assetRetriever: assetRetriever, pdfFactory: DefaultPDFDocumentFactory()))
        switch await assetRetriever.retrieve(url: fileURL) {
        case .failure(let error):
            logger.error("Book asset: \(String(describing: error), privacy: .public)")
            return .failure("The file isn't a book this app can read.")
        case .success(let asset):
            switch await opener.open(asset: asset, allowUserInteraction: false) {
            case .success(let publication): return .success(publication)
            case .failure(let error):
                logger.error("Book open: \(String(describing: error), privacy: .public)")
                return .failure("The book's file looks damaged. Try downloading it again.")
            }
        }
    }

    private func present(_ publication: Publication, at location: Locator?) {
        do {
            let navigator = try EPUBNavigatorViewController(
                publication: publication, initialLocation: location,
                config: EPUBNavigatorViewController.Configuration(preferences: preferences))
            navigator.delegate = self
            self.publication = publication
            self.navigator = navigator
            contentUnavailableConfiguration = nil
            addChild(navigator)
            navigator.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(navigator.view)
            NSLayoutConstraint.activate([
                navigator.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                navigator.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                navigator.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                navigator.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
            ])
            navigator.didMove(toParent: self)
            readerControls.page.adjust = { [weak navigator] amount in
                Task { if amount > 0 { _ = await navigator?.goForward() } else { _ = await navigator?.goBackward() } }
            }
            view.accessibilityElements = [readerControls.page, navigator.view!]
            // An EPUB's contents come from its own navigation document, already in the manifest.
            tableOfContents = publication.manifest.tableOfContents
            installContentsButton()
            UIAccessibility.post(notification: .screenChanged, argument: navigator.view)
        } catch {
            Self.logger.error("Navigator: \(String(describing: error), privacy: .public)")
            showStatus("Could not open book", detail: "It may be protected or damaged.")
        }
    }

    /// Dynamic Type sets the text size and the system appearance sets the colors.
    /// Publisher styles are off so those settings apply to every book. Text is
    /// aligned to the leading edge: justified lines open uneven gaps between
    /// words, which are harder to track with low vision.
    private var preferences: EPUBPreferences {
        let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: Self.bodyPointSize, compatibleWith: traitCollection)
        return EPUBPreferences(
            fontSize: Double(scaled / Self.bodyPointSize),
            publisherStyles: false,
            scroll: SettingsStore.shared.readingLayout == .continuous,
            textAlign: .start,
            theme: traitCollection.userInterfaceStyle == .dark ? .dark : .light)
    }

    private func installContentsButton() {
        guard !tableOfContents.isEmpty else { navigationItem.rightBarButtonItem = nil; return }
        let button = UIBarButtonItem(image: UIImage(systemName: "list.bullet"), primaryAction: UIAction { [weak self] _ in
            self?.showContents()
        })
        button.accessibilityLabel = "Contents"
        navigationItem.rightBarButtonItem = button
    }

    private func showContents() {
        let list = BookContentsController(links: tableOfContents) { [weak self] link in
            guard let self, let navigator else { return }
            dismiss(animated: true)
            Task { _ = await navigator.go(to: link) }
        }
        let sheet = UINavigationController(rootViewController: list)
        present(sheet, animated: true)
    }

    // MARK: - Position

    nonisolated func navigator(_ navigator: Navigator, locationDidChange locator: Locator) {
        MainActor.assumeIsolated { scheduleSave(locator) }
    }

    nonisolated func navigator(_ navigator: Navigator, presentError error: NavigatorError) {
        MainActor.assumeIsolated { Self.logger.error("Navigator error: \(String(describing: error), privacy: .public)") }
    }

    /// Scrolling reports many positions; write the last one after a short pause.
    private func scheduleSave(_ locator: Locator) {
        lastLocator = locator
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: Self.positionSaveDelay) } catch { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        pendingSave?.cancel(); pendingSave = nil
        guard let locator = lastLocator else { return }
        lastLocator = nil
        let identifier = summary.identifier, fileName = file.name, store = store
        Task {
            do {
                try await store.setBookLocator(try locator.jsonString(), identifier: identifier, fileName: fileName)
            } catch {
                Self.logger.error("Book position not saved: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Status

    private func showStatus(_ title: String, detail: String? = nil, retry: Bool = false) {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "book")
        configuration.text = title
        configuration.secondaryText = detail
        if retry {
            configuration.button = .borderedProminent()
            configuration.button.title = "Try Again"
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.retry() }
        }
        contentUnavailableConfiguration = configuration
    }

    private func retry() {
        if let lease { downloads.releaseLocalURL(lease); self.lease = nil }
        showStatus("Preparing book")
        Task { [weak self] in
            guard let self else { return }
            await downloads.start(identifier: summary.identifier, artifactTitle: summary.title, file: file)
        }
    }
}

/// The book's chapters as a list; nested sections are indented.
@MainActor
private final class BookContentsController: FunstonListController {
    private let entries: [(link: Link, depth: Int)]
    private let choose: (Link) -> Void
    private static let indentPerLevel: CGFloat = 16

    init(links: [Link], choose: @escaping (Link) -> Void) {
        func flatten(_ links: [Link], depth: Int) -> [(Link, Int)] {
            links.flatMap { [($0, depth)] + flatten($0.children, depth: depth + 1) }
        }
        entries = flatten(links, depth: 0)
        self.choose = choose
        super.init(title: "Contents")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        apply(entries.enumerated().map { index, entry in
            FunstonRow(id: "chapter:\(index)", title: entry.link.title ?? "Untitled section")
        })
    }

    override func configure(_ cell: UICollectionViewListCell, row: FunstonRow) {
        super.configure(cell, row: row)
        if let index = Int(row.id.dropFirst("chapter:".count)), entries.indices.contains(index) {
            cell.indentationLevel = entries[index].depth
            cell.indentationWidth = Self.indentPerLevel
        }
    }

    override func selected(_ id: String) {
        guard let index = Int(id.dropFirst("chapter:".count)), entries.indices.contains(index) else { return }
        choose(entries[index].link)
    }
}
