import UIKit
import PDFKit
import AVKit
import Combine

/// Exclusively created and validated by one worker, then handed to the main
/// actor once. The worker never touches the document after returning it, and
/// no PDFView or delegate is attached before that handoff.
private final class PreparedPDF: @unchecked Sendable {
    let document: PDFDocument
    init(_ document: PDFDocument) {
        self.document = document
    }
}

@MainActor
enum ArtifactMediaPresentation {
    static func preferredFile(in detail: ArtifactDetail) -> ArchiveFile? {
        book(in: detail) ?? supportedFiles(in: detail).first
    }

    /// A born-digital EPUB that came with the item, such as Project Gutenberg's.
    /// Internet Archive's own EPUBs of scanned books are generated from its OCR
    /// (derived from `_abbyy.gz`); those books stay in the PDF reader, where
    /// pages are recognized on this device instead.
    static func bookFile(in files: [ArchiveFile]) -> ArchiveFile? {
        files.filter { file in
            !file.isPrivate && (file.name as NSString).pathExtension.lowercased() == "epub"
                && file.source?.lowercased() != "derivative"
        }.sorted { lhs, rhs in
            // Gutenberg offers the book with and without illustrations.
            let lhsImages = lhs.name.lowercased().contains("-images"), rhsImages = rhs.name.lowercased().contains("-images")
            if lhsImages != rhsImages { return lhsImages }
            if lhs.size != rhs.size { return (lhs.size ?? 0) > (rhs.size ?? 0) }
            return lhs.name < rhs.name
        }.first
    }

    private static func book(in detail: ArtifactDetail) -> ArchiveFile? {
        guard detail.access == .available, !detail.summary.isAccessRestricted, detail.summary.mediaType == .texts else { return nil }
        return bookFile(in: detail.files)
    }

    private static func supportedFiles(in detail: ArtifactDetail) -> [ArchiveFile] {
        guard detail.access == .available, !detail.summary.isAccessRestricted, detail.summary.mediaType == .movies || detail.summary.mediaType == .texts else { return [] }
        let candidates = detail.files.filter { file in
            guard !file.isPrivate else { return false }
            let suffix = (file.name as NSString).pathExtension.lowercased()
            return detail.summary.mediaType == .movies ? ["mp4", "m4v", "mov", "mkv"].contains(suffix) : suffix == "pdf"
        }
        return candidates.sorted { lhs, rhs in
            // Stable display order only; multiple files always require selection.
            let lhsOriginal = (lhs.name as NSString).pathExtension.lowercased() == "mkv"
            let rhsOriginal = (rhs.name as NSString).pathExtension.lowercased() == "mkv"
            if lhsOriginal != rhsOriginal { return !lhsOriginal }
            if lhs.size != rhs.size { return (lhs.size ?? .max) < (rhs.size ?? .max) }
            return lhs.name < rhs.name
        }
    }

    static func actionTitle(for detail: ArtifactDetail) -> String? {
        if book(in: detail) != nil { return "Read Book" }
        guard preferredFile(in: detail) != nil else { return nil }
        return detail.summary.mediaType == .movies ? "Watch Film" : "Read PDF"
    }

    static func isVideoFile(_ fileName: String) -> Bool {
        ["mp4", "m4v", "mov", "mkv"].contains((fileName as NSString).pathExtension.lowercased())
    }

    static func watch(file: ArchiveFile, summary: ArtifactSummary, from controller: UIViewController,
                      environment: AppEnvironment, downloadedOnly: Bool = false) {
        guard !summary.isAccessRestricted, !file.isPrivate, isVideoFile(file.name), controller.presentedViewController == nil else { return }
        if (file.name as NSString).pathExtension.lowercased() == "mkv" {
            let viewer = UINavigationController(rootViewController: ArtifactOriginalVideoController(
                summary: summary, file: file, environment: environment, downloadedOnly: downloadedOnly))
            viewer.modalPresentationStyle = .fullScreen
            controller.present(viewer, animated: true)
            return
        }
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
        if let book = book(in: detail) {
            controller.navigationController?.pushViewController(
                EPUBReaderController(summary: detail.summary, file: book, downloads: environment.downloads, store: environment.store),
                animated: true)
            return
        }
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
                ArtifactPDFController(summary: summary, file: file, downloads: environment.downloads, store: environment.store), animated: true)
        }
    }
}

@MainActor
private final class ArtifactMediaFilePicker: FunstonListController {
    private let files: [ArchiveFile]
    private let openFile: (ArchiveFile, UIViewController) -> Void

    init(summary: ArtifactSummary, files: [ArchiveFile], openFile: @escaping (ArchiveFile, UIViewController) -> Void) {
        self.files = files; self.openFile = openFile
        super.init(title: summary.mediaType == .movies ? "Choose a Film" : "Choose a PDF")
        var rows = [FunstonRow(id: "explanation", title: summary.title,
                               subtitle: "This item has more than one version.", navigates: false)]
        rows += files.enumerated().map { index, file in
            FunstonRow(id: "file:\(index)", title: (file.name as NSString).lastPathComponent,
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
private final class ArtifactPDFController: UIViewController {
    private let summary: ArtifactSummary
    private let file: ArchiveFile
    private let downloads: DownloadManager
    private let textRecognizer: PDFPageTextRecognizer
    private let textEngineRegistry: PDFPageTextEngineRegistry
    private let textEnginePreference: PDFTextEnginePreference
    private let pdfView = PDFLineAccessibleView()
    private let pageLabel = AdjustablePageLabel()
    private let previous = UIButton(type: .system)
    private let nextPageButton = UIButton(type: .system)
    private var subscriptions = Set<AnyCancellable>()
    private var lease: URL?
    private var startTask: Task<Void, Never>?
    private var documentTask: Task<Void, Never>?
    private var textPrefetchTask: Task<Void, Never>?
    private var removalTask: Task<Void, Never>?
    private var loadingPDF = false
    private var currentRecord: DownloadRecord?
    private var restoringPage = false
    private var closed = false
    private var displayedPage: Int?
    private var displayedTextEngineID = PDFTextEngineID.automatic
    private var readingLayout = PDFReadingLayout.saved
    private lazy var progress = PDFReadingProgress(key: resumeKey)
    private var resumeKey: String { "pdf.page.\(DownloadManager.key(identifier: summary.identifier, fileName: file.name))" }

    init(summary: ArtifactSummary, file: ArchiveFile, downloads: DownloadManager, store: SQLiteStore) {
        self.summary = summary; self.file = file; self.downloads = downloads
        textEnginePreference = PDFTextEnginePreference(bookKey: DownloadManager.key(identifier: summary.identifier, fileName: file.name))
        let textEngineRegistry = PDFPageTextEngineRegistry.builtIn
        self.textEngineRegistry = textEngineRegistry
        textRecognizer = PDFPageTextRecognizer(store: store, registry: textEngineRegistry)
        super.init(nibName: nil, bundle: nil)
        title = summary.title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        startTask?.cancel()
        documentTask?.cancel()
        textPrefetchTask?.cancel()
        removalTask?.cancel()
        if let lease {
            let downloads = downloads
            Task { @MainActor in downloads.releaseLocalURL(lease) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        pdfView.autoScales = true
        readingLayout.apply(to: pdfView)
        pdfView.pageShadowsEnabled = false
        pdfView.isFindInteractionEnabled = true
        pdfView.accessibilityIdentifier = "reader.document"
        pdfView.isAccessibilityElement = false
        pdfView.visiblePagesDidChange = { [weak self] in self?.prefetchTextForVoiceOver() }
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)

        pageLabel.font = .preferredFont(forTextStyle: .footnote)
        pageLabel.adjustsFontForContentSizeCategory = true
        pageLabel.textAlignment = .center
        pageLabel.isAccessibilityElement = true
        pageLabel.accessibilityTraits = .adjustable
        pageLabel.numberOfLines = 0
        pageLabel.adjustPage = { [weak self] amount in
            guard let self, let document = pdfView.document, let current = pdfView.currentPage,
                  let page = document.page(at: document.index(for: current) + amount) else { return }
            pdfView.go(to: page)
        }
        previous.setImage(UIImage(systemName: readingLayout.previousSymbol), for: .normal)
        previous.accessibilityLabel = "Previous page"
        previous.isEnabled = false
        nextPageButton.setImage(UIImage(systemName: readingLayout.nextSymbol), for: .normal)
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
        definesPresentationContext = true
        NotificationCenter.default.publisher(for: .PDFViewPageChanged, object: pdfView)
            .sink { [weak self] _ in self?.updatePage() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.progress.flush() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIAccessibility.voiceOverStatusDidChangeNotification)
            .sink { [weak self] _ in self?.prefetchTextForVoiceOver() }.store(in: &subscriptions)
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

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if pdfView.document != nil {
            if displayedTextEngineID != textEnginePreference.selectedID {
                pdfView.clearRecognizedLines()
                displayedTextEngineID = textEnginePreference.selectedID
            }
            installDocumentActions()
            prefetchTextForVoiceOver()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        progress.flush()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        // An interactive Back gesture can be cancelled. Only abandon work once
        // UIKit has actually removed this controller from the navigation stack.
        removalTask?.cancel()
        guard parent == nil else { return }
        // The adaptive iPad layout reparents its existing detail stack. Give
        // that synchronous transfer time to finish before considering a removal.
        removalTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.parent == nil else { return }
            closed = true
            progress.flush()
            pdfView.findInteraction.dismissFindNavigator()
            pdfView.document?.cancelFindString()
            startTask?.cancel()
            documentTask?.cancel()
            textPrefetchTask?.cancel()
        }
    }

    private func startDownload() {
        showStatus("Preparing PDF", detail: "It will also be saved to Downloads.")
        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            await downloads.waitUntilReady()
            guard !Task.isCancelled else { return }
            await downloads.start(identifier: summary.identifier, artifactTitle: summary.title, file: file)
            guard !Task.isCancelled, !closed else { return }
            receive(downloads.records.first { $0.identifier == summary.identifier && $0.fileName == file.name })
        }
    }

    private func receive(_ record: DownloadRecord?) {
        currentRecord = record
        guard !closed, pdfView.document == nil, let record else { return }
        switch record.state {
        case .completed:
            guard !loadingPDF, lease == nil, let url = downloads.acquireLocalURL(identifier: summary.identifier, fileName: file.name) else { return }
            prepareDocument(at: url)
        case .queued, .downloading:
            let received = ByteCountFormatter.string(fromByteCount: record.receivedBytes, countStyle: .file)
            let total = record.totalBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            showStatus("Downloading PDF", detail: total.map { "\(received) of \($0)" } ?? received)
            navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Cancel", primaryAction: UIAction { [weak self] _ in
                guard let self, let record = self.currentRecord else { return }
                Task { do { try await self.downloads.cancel(record) } catch { self.showStatus("Could not cancel", detail: error.localizedDescription, retry: true) } }
            })
        case .failed, .missing, .cancelled:
            navigationItem.rightBarButtonItem = nil
            showStatus(record.state == .cancelled ? "Download cancelled" : "Could not open PDF", detail: record.errorMessage ?? "Try downloading this PDF again.", retry: true)
        }
    }

    private func prepareDocument(at url: URL) {
        loadingPDF = true
        navigationItem.rightBarButtonItem = nil
        showStatus("Opening PDF")
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
            guard !Task.isCancelled, let self, !self.closed else {
                downloads.releaseLocalURL(url)
                return
            }
            loadingPDF = false
            guard let result else {
                downloads.releaseLocalURL(url)
                showStatus("This PDF cannot be opened", detail: "It may be locked or damaged. Open the item on Internet Archive for other formats.")
                return
            }
            lease = url
            let document = result.document
            let saved = UserDefaults.standard.integer(forKey: resumeKey)
            contentUnavailableConfiguration = nil
            restoringPage = true
            pdfView.clearRecognizedLines()
            pdfView.document = document
            if let page = document.page(at: min(max(0, saved), document.pageCount - 1)) { pdfView.go(to: page) }
            restoringPage = false
            installDocumentActions()
            updatePage()
        }
    }

    private func showStatus(_ title: String, detail: String? = nil, retry: Bool = false) {
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
        guard index != NSNotFound, index != displayedPage else { return }
        displayedPage = index
        pageLabel.text = "Page \(index + 1) of \(document.pageCount)"
        previous.isEnabled = pdfView.canGoToPreviousPage
        nextPageButton.isEnabled = pdfView.canGoToNextPage
        progress.record(page: index)
        prefetchTextForVoiceOver()
    }

    private func installDocumentActions() {
        let find = UIBarButtonItem(image: UIImage(systemName: "magnifyingglass"), primaryAction: UIAction { [weak self] _ in
            self?.pdfView.findInteraction.presentFindNavigator(showingReplace: false)
        })
        find.accessibilityLabel = "Find in document"
        let readText = UIBarButtonItem(image: UIImage(systemName: "text.viewfinder"), primaryAction: UIAction { [weak self] _ in
            self?.readRecognizedText()
        })
        readText.accessibilityLabel = "Page text"
        let layouts = PDFReadingLayout.allCases.map { layout in
            UIAction(title: layout.title, state: layout == readingLayout ? .on : .off) { [weak self] _ in
                self?.changeLayout(to: layout)
            }
        }
        let engineOptions = textEnginePreference.options(ocrEngines: textEngineRegistry.descriptors)
        let selectedEngineID = textEnginePreference.selectedID
        let engines = engineOptions.map { engine in
            UIAction(
                title: engine.title,
                subtitle: engine.subtitle,
                attributes: engine.isAvailable ? [] : [.disabled],
                state: engine.id == selectedEngineID ? .on : .off
            ) { [weak self] _ in
                self?.changeTextEngine(to: engine.id)
            }
        }
        let page = UIAction(title: "Go to Page", image: UIImage(systemName: "number.square")) { [weak self] _ in self?.choosePage() }
        let share = UIAction(title: "Share PDF", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.share() }
        let menu = UIMenu(children: [
            page,
            share,
            UIMenu(title: "Text Recognition", image: UIImage(systemName: "text.viewfinder"), children: engines),
            UIMenu(title: "Reading Layout", options: .displayInline, children: layouts)
        ])
        let options = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: menu)
        options.accessibilityLabel = "Reading options"
        options.accessibilityValue = "\(readingLayout.title), \(textEnginePreference.title(ocrEngines: textEngineRegistry.descriptors))"
        navigationItem.rightBarButtonItems = [options, find, readText]
    }

    private func pageTextRequest(index: Int) -> PDFPageTextRequest? {
        guard let document = pdfView.document, let page = document.page(at: index),
              let source = PDFPageRenderSource(page: page) else { return nil }
        return PDFPageTextRequest(
            page: source,
            documentKey: DownloadManager.key(identifier: summary.identifier, fileName: file.name),
            pageIndex: index,
            expectedBytes: file.size,
            preferLocalRecognition: PDFPageTextPolicy.prefersLocalRecognition(for: file),
            selectedEngineID: textEnginePreference.selectedID
        )
    }

    private func prefetchTextForVoiceOver() {
        textPrefetchTask?.cancel()
        guard !restoringPage, UIAccessibility.isVoiceOverRunning, let document = pdfView.document,
              let index = displayedPage, let current = pageTextRequest(index: index) else { return }
        let selectedEngineID = current.selectedEngineID
        displayedTextEngineID = selectedEngineID
        var indices = Set(pdfView.visiblePages.map { document.index(for: $0) })
        indices.insert(index)
        let requests = indices.sorted { abs($0 - index) < abs($1 - index) }.compactMap { pageTextRequest(index: $0)?.forPageImage }
        let recognizer = textRecognizer
        textPrefetchTask = Task { [weak self] in
            await withTaskGroup(of: (PDFPageTextRequest, PDFPageTextResult).self) { group in
                // Live Text keeps its separate transcript prefetch. Its words are
                // never aligned to Automatic's boxes or used for image-view labels.
                if selectedEngineID == PDFTextEngineID.appleLiveText {
                    group.addTask { (current, await recognizer.text(for: current)) }
                }
                for request in requests { group.addTask { (request, await recognizer.text(for: request)) } }
                for await (request, result) in group {
                    guard !Task.isCancelled, let self, !self.closed,
                          self.textEnginePreference.selectedID == selectedEngineID,
                          request.selectedEngineID != PDFTextEngineID.appleLiveText,
                          let page = self.pdfView.document?.page(at: request.pageIndex) else { continue }
                    self.pdfView.install(result, source: request.page, page: page, index: request.pageIndex)
                }
            }
        }
    }

    private func readRecognizedText() {
        guard let document = pdfView.document, let currentPage = pdfView.currentPage else { return }
        let index = document.index(for: currentPage)
        guard index != NSNotFound else { return }
        let reader = PDFTextReaderController(
            document: document,
            initialPage: index,
            documentKey: DownloadManager.key(identifier: summary.identifier, fileName: file.name),
            expectedBytes: file.size,
            preferLocalRecognition: PDFPageTextPolicy.prefersLocalRecognition(for: file),
            textEngineDescriptors: textEngineRegistry.descriptors,
            recognizer: textRecognizer
        ) { [weak self, weak document] index in
            guard let self, let page = document?.page(at: index) else { return }
            self.pdfView.go(to: page)
        }
        navigationController?.pushViewController(reader, animated: true)
    }

    private func changeTextEngine(to engineID: String) {
        guard engineID != textEnginePreference.selectedID else { return }
        textEnginePreference.select(engineID)
        displayedTextEngineID = engineID
        pdfView.clearRecognizedLines()
        textPrefetchTask?.cancel()
        installDocumentActions()
        prefetchTextForVoiceOver()
    }

    private func changeLayout(to layout: PDFReadingLayout) {
        guard layout != readingLayout else { return }
        restoringPage = true
        layout.apply(to: pdfView)
        readingLayout = layout
        layout.save()
        previous.setImage(UIImage(systemName: layout.previousSymbol), for: .normal)
        nextPageButton.setImage(UIImage(systemName: layout.nextSymbol), for: .normal)
        restoringPage = false
        displayedPage = nil
        updatePage()
        installDocumentActions()
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
        controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
        present(controller, animated: true)
    }
}

@MainActor
private final class PDFTextReaderController: UIViewController {
    private let document: PDFDocument
    private let documentKey: String
    private let expectedBytes: Int64?
    private let preferLocalRecognition: Bool
    private let textEngineDescriptors: [PDFTextEngineDescriptor]
    private let textEnginePreference: PDFTextEnginePreference
    private let recognizer: PDFPageTextRecognizer
    private let showPage: (Int) -> Void
    private let textView = UITextView()
    private let pageLabel = AdjustablePageLabel()
    private let previous = UIButton(type: .system)
    private let nextPage = UIButton(type: .system)
    private var pageIndex: Int
    private var recognitionTask: Task<Void, Never>?

    init(document: PDFDocument, initialPage: Int, documentKey: String, expectedBytes: Int64?,
         preferLocalRecognition: Bool, textEngineDescriptors: [PDFTextEngineDescriptor],
         recognizer: PDFPageTextRecognizer,
         showPage: @escaping (Int) -> Void) {
        self.document = document
        self.pageIndex = initialPage
        self.documentKey = documentKey
        textEnginePreference = PDFTextEnginePreference(bookKey: documentKey)
        self.expectedBytes = expectedBytes
        self.preferLocalRecognition = preferLocalRecognition
        self.textEngineDescriptors = textEngineDescriptors
        self.recognizer = recognizer
        self.showPage = showPage
        super.init(nibName: nil, bundle: nil)
        title = "Page Text"
        pageLabel.adjustPage = { [weak self] amount in self?.move(by: amount) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { recognitionTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .systemBackground
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        textView.accessibilityIdentifier = "reader.recognizedText"
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        pageLabel.font = .preferredFont(forTextStyle: .footnote)
        pageLabel.adjustsFontForContentSizeCategory = true
        pageLabel.textAlignment = .center
        pageLabel.isAccessibilityElement = true
        pageLabel.accessibilityTraits = .adjustable
        previous.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
        previous.accessibilityLabel = "Previous page text"
        nextPage.setImage(UIImage(systemName: "chevron.forward"), for: .normal)
        nextPage.accessibilityLabel = "Next page text"
        previous.addAction(UIAction { [weak self] _ in self?.move(by: -1) }, for: .touchUpInside)
        nextPage.addAction(UIAction { [weak self] _ in self?.move(by: 1) }, for: .touchUpInside)
        let controls = UIStackView(arrangedSubviews: [previous, pageLabel, nextPage])
        controls.axis = .horizontal
        controls.spacing = 12
        controls.alignment = .center
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -8),
            controls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            previous.widthAnchor.constraint(equalToConstant: 44),
            previous.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            nextPage.widthAnchor.constraint(equalToConstant: 44),
            nextPage.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        installTextEngineMenu()
        loadPage()
    }

    private func installTextEngineMenu() {
        let selectedEngineID = textEnginePreference.selectedID
        let actions = textEnginePreference.options(ocrEngines: textEngineDescriptors).map { engine in
            UIAction(
                title: engine.title,
                subtitle: engine.subtitle,
                attributes: engine.isAvailable ? [] : [.disabled],
                state: engine.id == selectedEngineID ? .on : .off
            ) { [weak self] _ in
                guard let self, engine.id != textEnginePreference.selectedID else { return }
                textEnginePreference.select(engine.id)
                installTextEngineMenu()
                loadPage()
            }
        }
        let item = UIBarButtonItem(title: "Text Engine", menu: UIMenu(title: "Text Recognition", image: UIImage(systemName: "text.viewfinder"), children: actions))
        item.accessibilityLabel = "Text engine"
        item.accessibilityValue = textEnginePreference.title(ocrEngines: textEngineDescriptors)
        navigationItem.rightBarButtonItem = item
    }

    private func move(by amount: Int) {
        let destination = pageIndex + amount
        guard (0..<document.pageCount).contains(destination) else { return }
        pageIndex = destination
        showPage(destination)
        loadPage()
    }

    private func loadPage() {
        recognitionTask?.cancel()
        pageLabel.text = "Page \(pageIndex + 1) of \(document.pageCount)"
        previous.isEnabled = pageIndex > 0
        nextPage.isEnabled = pageIndex + 1 < document.pageCount
        textView.text = ""
        textView.accessibilityLabel = "Recognized text, page \(pageIndex + 1)"
        var loading = UIContentUnavailableConfiguration.loading()
        loading.text = "Recognizing page \(pageIndex + 1)"
        loading.secondaryText = "Using \(textEnginePreference.title(ocrEngines: textEngineDescriptors))."
        contentUnavailableConfiguration = loading

        guard let page = document.page(at: pageIndex), let source = PDFPageRenderSource(page: page) else {
            showNoText()
            return
        }
        let request = PDFPageTextRequest(
            page: source,
            documentKey: documentKey,
            pageIndex: pageIndex,
            expectedBytes: expectedBytes,
            preferLocalRecognition: preferLocalRecognition,
            selectedEngineID: textEnginePreference.selectedID
        )
        recognitionTask = Task { [weak self, recognizer] in
            let result = await recognizer.text(for: request)
            guard !Task.isCancelled, let self else { return }
            if result.text.isEmpty {
                showNoText()
            } else {
                contentUnavailableConfiguration = nil
                textView.text = result.text
                if let engineID = result.engineID {
                    textView.accessibilityHint = textEnginePreference.options(ocrEngines: textEngineDescriptors)
                        .first { $0.id == engineID }.map { "Read by \($0.title)" }
                }
                textView.setContentOffset(.zero, animated: false)
                UIAccessibility.post(notification: .screenChanged, argument: textView)
            }
        }
    }

    private func showNoText() {
        var unavailable = UIContentUnavailableConfiguration.empty()
        unavailable.image = UIImage(systemName: "text.magnifyingglass")
        unavailable.text = "No text found on page \(pageIndex + 1)"
        unavailable.secondaryText = "This page may be a picture or blank."
        contentUnavailableConfiguration = unavailable
        UIAccessibility.post(notification: .screenChanged, argument: view)
    }
}

@MainActor
final class AdjustablePageLabel: UILabel {
    var adjustPage: ((Int) -> Void)?
    override func accessibilityIncrement() { adjustPage?(1) }
    override func accessibilityDecrement() { adjustPage?(-1) }
}
