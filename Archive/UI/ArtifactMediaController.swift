import UIKit
import PDFKit
import AVKit
import Combine

/// Exclusively created and validated by one worker, then handed to the main
/// actor once. The worker never touches the document after returning it, and
/// no PDFView or delegate is attached before that handoff.
private final class PreparedPDF: @unchecked Sendable {
    let document: PDFDocument
    init(_ document: PDFDocument) { self.document = document }
}

@MainActor
enum ArtifactMediaPresentation {
    static func preferredFile(in detail: ArtifactDetail) -> ArchiveFile? {
        supportedFiles(in: detail).first
    }

    private static func supportedFiles(in detail: ArtifactDetail) -> [ArchiveFile] {
        guard detail.access == .available, detail.summary.mediaType == .movies || detail.summary.mediaType == .texts else { return [] }
        let candidates = detail.files.filter { file in
            guard !file.isPrivate else { return false }
            let suffix = (file.name as NSString).pathExtension.lowercased()
            return detail.summary.mediaType == .movies ? ["mp4", "m4v", "mov"].contains(suffix) : suffix == "pdf"
        }
        return candidates.sorted { lhs, rhs in
            // Stable display order only; multiple files always require selection.
            if lhs.size != rhs.size { return (lhs.size ?? .max) < (rhs.size ?? .max) }
            return lhs.name < rhs.name
        }
    }

    static func actionTitle(for detail: ArtifactDetail) -> String? {
        guard preferredFile(in: detail) != nil else { return nil }
        return detail.summary.mediaType == .movies ? "Watch Film" : "Read PDF"
    }

    static func isVideoFile(_ fileName: String) -> Bool {
        ["mp4", "m4v", "mov"].contains((fileName as NSString).pathExtension.lowercased())
    }

    static func watch(file: ArchiveFile, summary: ArtifactSummary, from controller: UIViewController,
                      environment: AppEnvironment, downloadedOnly: Bool = false) {
        guard !file.isPrivate, isVideoFile(file.name), controller.presentedViewController == nil else { return }
        let session = VideoPlaybackSession(summary: summary, file: file,
            source: downloadedOnly ? .downloadedOnly : .archive,
            store: environment.store, downloads: environment.downloads,
            acquireAudio: { try await environment.playback.acquireVideoPlayback() },
            releaseAudio: { environment.playback.releaseVideoPlayback($0) })
        let viewer = UINavigationController(rootViewController: ArtifactVideoController(session: session))
        viewer.modalPresentationStyle = .fullScreen
        controller.present(viewer, animated: true)
    }

    static func open(detail: ArtifactDetail, from controller: UIViewController, environment: AppEnvironment) {
        let files = supportedFiles(in: detail)
        guard let file = files.first else { return }
        if files.count > 1 {
            let picker = ArtifactMediaFilePicker(summary: detail.summary, files: files) { file, picker in
                open(file: file, summary: detail.summary, from: picker, environment: environment)
            }
            controller.navigationController?.pushViewController(picker, animated: true)
        } else { open(file: file, summary: detail.summary, from: controller, environment: environment) }
    }

    private static func open(file: ArchiveFile, summary: ArtifactSummary, from controller: UIViewController, environment: AppEnvironment) {
        if summary.mediaType == .movies {
            watch(file: file, summary: summary, from: controller, environment: environment)
        } else {
            controller.navigationController?.pushViewController(
                ArtifactPDFController(summary: summary, file: file, downloads: environment.downloads), animated: true)
        }
    }
}

@MainActor
private final class ArtifactMediaFilePicker: ArchiveListController {
    private let files: [ArchiveFile]
    private let openFile: (ArchiveFile, UIViewController) -> Void

    init(summary: ArtifactSummary, files: [ArchiveFile], openFile: @escaping (ArchiveFile, UIViewController) -> Void) {
        self.files = files; self.openFile = openFile
        super.init(title: summary.mediaType == .movies ? "Choose a Film File" : "Choose a PDF")
        var rows = [ArchiveRow(id: "explanation", title: summary.title,
                               subtitle: "This artifact has several files. Choose the version you want to open.", navigates: false)]
        rows += files.enumerated().map { index, file in
            ArchiveRow(id: "file:\(index)", title: (file.name as NSString).lastPathComponent,
                       subtitle: [file.format, file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }].compactMap { $0 }.joined(separator: " · "))
        }
        apply(rows)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func selected(_ id: String) {
        guard id.hasPrefix("file:"), let index = Int(id.dropFirst(5)), files.indices.contains(index) else { return }
        openFile(files[index], self)
    }
}

/// Documents use the same validated, durable transfers and file leases as audio.
/// Leaving the reader preserves the download; Cancel is an explicit transfer action.
@MainActor
private final class ArtifactPDFController: UIViewController, UISearchBarDelegate, @preconcurrency PDFDocumentDelegate {
    private let summary: ArtifactSummary
    private let file: ArchiveFile
    private let downloads: DownloadManager
    private let pdfView = PDFView()
    private let pageLabel = UILabel()
    private let previous = UIButton(type: .system)
    private let nextPageButton = UIButton(type: .system)
    private let search = UISearchController(searchResultsController: nil)
    private var subscriptions = Set<AnyCancellable>()
    private var lease: URL?
    private var startTask: Task<Void, Never>?
    private var documentTask: Task<Void, Never>?
    private var loadingPDF = false
    private var matches: [PDFSelection] = []
    private var matchIndex = 0
    private var currentRecord: DownloadRecord?
    private var restoringPage = false
    private var resumeKey: String { "pdf.page.\(DownloadManager.key(identifier: summary.identifier, fileName: file.name))" }

    init(summary: ArtifactSummary, file: ArchiveFile, downloads: DownloadManager) {
        self.summary = summary; self.file = file; self.downloads = downloads
        super.init(nibName: nil, bundle: nil)
        title = summary.title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        startTask?.cancel()
        documentTask?.cancel()
        if let lease {
            let downloads = downloads
            Task { @MainActor in downloads.releaseLocalURL(lease) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)

        pageLabel.font = .preferredFont(forTextStyle: .footnote)
        pageLabel.adjustsFontForContentSizeCategory = true
        pageLabel.textAlignment = .center
        pageLabel.numberOfLines = 0
        previous.setImage(UIImage(systemName: "chevron.up"), for: .normal)
        previous.accessibilityLabel = "Previous page"
        previous.isEnabled = false
        nextPageButton.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        nextPageButton.accessibilityLabel = "Next page"
        nextPageButton.isEnabled = false
        previous.addAction(UIAction { [weak self] _ in self?.pdfView.goToPreviousPage(nil) }, for: .touchUpInside)
        nextPageButton.addAction(UIAction { [weak self] _ in self?.pdfView.goToNextPage(nil) }, for: .touchUpInside)
        let controls = UIStackView(arrangedSubviews: [previous, pageLabel, nextPageButton])
        controls.axis = .horizontal; controls.spacing = 12; controls.alignment = .center
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -8),
            controls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            previous.widthAnchor.constraint(equalToConstant: 44), previous.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            nextPageButton.widthAnchor.constraint(equalToConstant: 44), nextPageButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Find in document"
        search.searchBar.delegate = self
        search.searchBar.isUserInteractionEnabled = false
        navigationItem.searchController = search
        definesPresentationContext = true
        NotificationCenter.default.publisher(for: .PDFViewPageChanged, object: pdfView)
            .sink { [weak self] _ in self?.updatePage() }.store(in: &subscriptions)
        let identifier = summary.identifier, fileName = file.name
        downloads.$records.map { records in
            records.first { $0.identifier == identifier && $0.fileName == fileName }
        }.removeDuplicates().sink { [weak self] record in
            // @Published emits before the stored array changes; acquire the local
            // lease after the download manager has committed its in-memory state.
            Task { @MainActor [weak self] in self?.receive(record) }
        }.store(in: &subscriptions)
        startDownload()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent {
            pdfView.document?.cancelFindString()
            documentTask?.cancel()
        }
    }

    private func startDownload() {
        showStatus("Preparing document", detail: "The PDF will be saved in Downloads for offline reading.")
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            await downloads.waitUntilReady()
            guard !Task.isCancelled else { return }
            await downloads.start(identifier: summary.identifier, artifactTitle: summary.title, file: file)
            receive(downloads.records.first { $0.identifier == summary.identifier && $0.fileName == file.name })
        }
    }

    private func receive(_ record: DownloadRecord?) {
        currentRecord = record
        guard pdfView.document == nil, let record else { return }
        switch record.state {
        case .completed:
            guard !loadingPDF, lease == nil, let url = downloads.acquireLocalURL(identifier: summary.identifier, fileName: file.name) else { return }
            prepareDocument(at: url)
        case .queued, .downloading:
            let received = ByteCountFormatter.string(fromByteCount: record.receivedBytes, countStyle: .file)
            let total = record.totalBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            showStatus("Downloading PDF", detail: total.map { "\(received) of \($0) · Saved for offline reading" } ?? "\(received) · Saved for offline reading")
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Cancel", primaryAction: UIAction { [weak self] _ in
                guard let self, let record = self.currentRecord else { return }
                Task { do { try await self.downloads.cancel(record) } catch { self.showStatus("Could not cancel", detail: error.localizedDescription, retry: true) } }
            })
        case .failed, .missing, .cancelled:
            navigationItem.rightBarButtonItem = nil
            showStatus(record.state == .cancelled ? "Download cancelled" : "Could not open document", detail: record.errorMessage ?? "Try downloading this PDF again.", retry: true)
        }
    }

    private func prepareDocument(at url: URL) {
        loadingPDF = true
        navigationItem.rightBarButtonItem = nil
        showStatus("Opening PDF", detail: "Preparing the saved document…")
        let worker = Task.detached(priority: .userInitiated) { () -> PreparedPDF? in
            guard !Task.isCancelled, let document = PDFDocument(url: url),
                  !document.isLocked, document.pageCount > 0, !Task.isCancelled else { return nil }
            return PreparedPDF(document)
        }
        let downloads = downloads
        documentTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            // The awaiting task owns this lease until parsing ends, including
            // after navigation cancels it. Deletion cannot race the worker.
            guard !Task.isCancelled, let self else {
                downloads.releaseLocalURL(url)
                return
            }
            loadingPDF = false
            guard let result else {
                downloads.releaseLocalURL(url)
                showStatus("This PDF cannot be opened", detail: "It may be locked or damaged. Open the artifact on Internet Archive for other formats.")
                return
            }
            lease = url
            let document = result.document
            let saved = UserDefaults.standard.integer(forKey: resumeKey)
            contentUnavailableConfiguration = nil
            restoringPage = true
            pdfView.document = document
            document.delegate = self
            if let page = document.page(at: min(max(0, saved), document.pageCount - 1)) { pdfView.go(to: page) }
            restoringPage = false
            search.searchBar.isUserInteractionEnabled = true
            installDocumentActions()
            updatePage()
        }
    }

    private func showStatus(_ title: String, detail: String, retry: Bool = false) {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "doc.richtext")
        configuration.text = title; configuration.secondaryText = detail
        if retry {
            configuration.button = .borderedProminent()
            configuration.button.title = "Try Again"
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.startDownload() }
        }
        contentUnavailableConfiguration = configuration
    }

    private func updatePage() {
        guard !restoringPage, let document = pdfView.document, let page = pdfView.currentPage else { return }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        pageLabel.text = "Page \(index + 1) of \(document.pageCount)"
        previous.isEnabled = pdfView.canGoToPreviousPage
        nextPageButton.isEnabled = pdfView.canGoToNextPage
        UserDefaults.standard.set(index, forKey: resumeKey)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        guard let term = searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty,
              let document = pdfView.document else { return }
        document.cancelFindString()
        matches = []; matchIndex = 0
        document.beginFindString(term, withOptions: .caseInsensitive)
        searchBar.resignFirstResponder()
    }

    func didMatchString(_ instance: PDFSelection) {
        guard matches.count < 500 else { return }
        matches.append(instance)
        if matches.count == 1 { showMatch() }
    }

    func documentDidEndDocumentFind(_ notification: Notification) {
        installDocumentActions()
        if matches.isEmpty {
            pageLabel.text = "No matches in searchable text"
            UIAccessibility.post(notification: .announcement, argument: "No matches in searchable text")
        } else { showMatch() }
    }

    private func showMatch() {
        guard matches.indices.contains(matchIndex) else { return }
        pdfView.setCurrentSelection(matches[matchIndex], animate: !UIAccessibility.isReduceMotionEnabled)
        pdfView.go(to: matches[matchIndex])
        pageLabel.text = "Match \(matchIndex + 1) of \(matches.count)\(matches.count == 500 ? "+" : "")"
    }

    private func installDocumentActions() {
        let share = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), primaryAction: UIAction { [weak self] _ in self?.share() })
        share.accessibilityLabel = "Share PDF"
        let goToPage = UIBarButtonItem(image: UIImage(systemName: "number.square"), primaryAction: UIAction { [weak self] _ in self?.choosePage() })
        goToPage.accessibilityLabel = "Go to page"
        var items = [share, goToPage]
        if matches.count > 1 {
            let nextMatch = UIBarButtonItem(image: UIImage(systemName: "text.magnifyingglass"), primaryAction: UIAction { [weak self] _ in
                guard let self, !self.matches.isEmpty else { return }
                self.matchIndex = (self.matchIndex + 1) % self.matches.count
                self.showMatch()
            })
            nextMatch.accessibilityLabel = "Next search match"
            items.append(nextMatch)
        }
        navigationItem.rightBarButtonItems = items
    }

    private func choosePage() {
        guard let document = pdfView.document else { return }
        let pageCount = document.pageCount
        let alert = UIAlertController(title: "Go to Page", message: "Enter a page from 1 to \(pageCount).", preferredStyle: .alert)
        alert.addTextField { field in
            field.keyboardType = .numberPad
            field.placeholder = "Page number"
            field.accessibilityLabel = "Page number"
            field.accessibilityHint = "1 to \(pageCount)"
        }
        let go = UIAlertAction(title: "Go", style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text, let number = Int(text),
                  (1...pageCount).contains(number), let page = document.page(at: number - 1) else { return }
            self?.pdfView.go(to: page)
        }
        go.isEnabled = false
        alert.textFields?.first?.addAction(UIAction { [weak alert] _ in
            let number = Int(alert?.textFields?.first?.text ?? "") ?? 0
            go.isEnabled = (1...pageCount).contains(number)
        }, for: .editingChanged)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(go)
        present(alert, animated: true)
    }

    private func share() {
        guard let lease else { return }
        let controller = UIActivityViewController(activityItems: [lease], applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(controller, animated: true)
    }
}
