import UIKit
import Combine
import OSLog

/// Reads a born-digital EPUB with the native reader. The book is downloaded
/// first (it stays in Downloads for offline reading), then opened from the local
/// file under a lease so removing the download can't pull it out from under us.
/// Text size follows Dynamic Type and colors follow Dark Mode; the layout
/// setting picks pages or continuous scrolling.
@MainActor
final class EPUBReaderController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate, EPUBPageViewDelegate, EPUBPageStripDelegate, EPUBContinuousStripDelegate {
    private static let logger = Logger(subsystem: "com.camden.Funston", category: "Books")
    /// Body text at the default Dynamic Type size is 17 pt.
    static let bodyPointSize: CGFloat = 17
    private static let positionSaveDelay: Duration = .seconds(1)
    /// Edge taps turn pages: the larger of this and a fraction of the width (Spec 13.6).
    static let edgeZoneMinimum: CGFloat = 80
    static let edgeZoneFraction: CGFloat = 0.3
    /// Phones in landscape may use two columns (Spec 11.1).
    static let twoColumnLandscapeMinimumWidth: CGFloat = 600

    private let summary: ArtifactSummary
    private let file: ArchiveFile
    private let downloads: DownloadManager
    private let store: SQLiteStore
    private var subscriptions = Set<AnyCancellable>()
    private var lease: URL?
    private var opening: Task<Void, Never>?
    private var pendingSave: Task<Void, Never>?
    private var pendingLayout: Task<Void, Never>?
    private var lastLocator: EPUBLocator?
    private var session: EPUBReaderSession?
    private var pager: UIPageViewController?
    private var continuous: EPUBContinuousStripView?
    /// The chapter the continuous strip's window is centred on.
    private var continuousSpine: Int?
    /// Page by page under the per-paragraph model: the reading window's pages in one paging strip.
    private var strip: EPUBPageStripView?
    private var layoutMode: PDFReadingLayout = .pages
    private let container = UIView()
    private let banner = UILabel()
    private var noticeShown = false
    /// True while VoiceOver's own read-all is turning pages: nothing may move its focus (APL-33).
    private var voiceOverTurning = false
    /// True while the adjustable Reading page element turns a page: focus stays on it.
    private var adjusting = false
    private lazy var readerControls = ReaderControls(reader: self, pageView: view)

    init(summary: ArtifactSummary, file: ArchiveFile, downloads: DownloadManager, store: SQLiteStore) {
        self.summary = summary; self.file = file; self.downloads = downloads; self.store = store
        super.init(nibName: nil, bundle: nil)
        title = summary.title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The reading state once the book is open; for tests.
    var readerSession: EPUBReaderSession? { session }
    var contents: [EPUBContentsEntry] { session?.publication.navigation.contents ?? [] }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "book.reader"
        navigationItem.largeTitleDisplayMode = .never
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)
        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.font = .preferredFont(forTextStyle: .footnote)
        banner.adjustsFontForContentSizeCategory = true
        banner.textAlignment = .center
        banner.numberOfLines = 0
        banner.backgroundColor = .secondarySystemBackground
        banner.isHidden = true
        view.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        let identifier = summary.identifier, fileName = file.name
        downloads.$records.map { records in
            records.first { $0.identifier == identifier && $0.fileName == fileName }
        }.removeDuplicates().sink { [weak self] record in
            // @Published emits before the stored array changes.
            Task { @MainActor [weak self] in self?.receive(record) }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.saveNow() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in self?.session?.shed() }.store(in: &subscriptions)
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) { (reader: EPUBReaderController, _: UITraitCollection) in
            reader.applySettings()
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

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.applyGeometry() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let session, session.contentSize != contentSize { applyGeometry() }
    }

    override func accessibilityPerformMagicTap() -> Bool { readerControls.toggle(); return true }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        guard parent == nil else { return }
        opening?.cancel()
        pendingLayout?.cancel()
        saveNow()
        if let lease { downloads.releaseLocalURL(lease); self.lease = nil }
    }

    // MARK: - Opening

    private func receive(_ record: DownloadRecord?) {
        guard session == nil, opening == nil, lease == nil, let record else { return }
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
        guard session == nil, opening == nil else { if leased { downloads.releaseLocalURL(url) }; return }
        lease = url
        showStatus("Opening book")
        let identifier = summary.identifier, fileName = file.name, store = store
        opening = Task { [weak self] in
            var saved: String?
            do {
                saved = try await store.bookLocator(identifier: identifier, fileName: fileName)
            } catch {
                Self.logger.error("Saved book position unreadable: \(error.localizedDescription, privacy: .public)")
            }
            let result = await Task.detached(priority: .userInitiated) { () -> Result<EPUBPublication, EPUBOpenFailure> in
                do { return .success(try EPUBPublication.open(url: url)) }
                catch let failure as EPUBOpenFailure { return .failure(failure) }
                catch { return .failure(.damaged(error.localizedDescription)) }
            }.value
            guard let self, !Task.isCancelled else { return }
            opening = nil
            switch result {
            case .success(let publication): present(publication, stored: saved)
            case .failure(let failure):
                Self.logger.error("Book open: \(failure.message, privacy: .public)")
                showStatus("Could not open book", detail: failure.message, retry: failure != .protected)
            }
        }
    }

    private var contentSize: CGSize {
        let size = container.bounds.size
        return CGSize(width: max(1, size.width - 2 * EPUBPageView.margin), height: max(1, size.height - 2 * EPUBPageView.margin))
    }

    private var allowsTwoColumns: Bool { container.bounds.width >= Self.twoColumnLandscapeMinimumWidth }

    /// Dynamic Type sets the text size and the system appearance sets the colors.
    /// Publisher styles are off so those settings apply to every book. Text is
    /// aligned to the leading edge: justified lines open uneven gaps between
    /// words, which are harder to track with low vision.
    private var settings: EPUBReadingSettings {
        var settings = EPUBReadingSettings()
        settings.baseFontSize = UIFontMetrics(forTextStyle: .body).scaledValue(for: Self.bodyPointSize, compatibleWith: traitCollection)
        settings.theme = traitCollection.userInterfaceStyle == .dark ? .dark : .light
        settings.layout = SettingsStore.shared.readingLayout == .continuous ? .continuous : .pages
        settings.publisherStyles = false
        settings.alignment = .start
        return settings
    }

    private var mediaContext: EPUBMediaContext {
        EPUBMediaContext(isDark: traitCollection.userInterfaceStyle == .dark, isLandscape: view.bounds.width > view.bounds.height)
    }

    private func present(_ publication: EPUBPublication, stored: String?) {
        view.layoutIfNeeded()
        let session = EPUBReaderSession(publication: publication, settings: settings, contentSize: contentSize, allowsTwoColumns: allowsTwoColumns, mediaContext: mediaContext)
        self.session = session
        layoutMode = SettingsStore.shared.readingLayout
        contentUnavailableConfiguration = nil
        var notes: [String] = []
        if publication.isFixedLayout { notes.append("This book was made for fixed pages; its text is shown flowing.") }
        if publication.hasMediaOverlays { notes.append("This book has narration that is not played.") }
        banner.text = notes.joined(separator: " ")
        banner.isHidden = notes.isEmpty
        var approximate = false
        if let stored {
            let resolver = EPUBPositionResolver(publication: publication) { [weak session] in session?.chapter($0) }
            let restored = resolver.resolve(EPUBStoredPosition.parse(stored))
            approximate = restored.isApproximate
            if session.go(to: .restored(restored)) == nil { session.go(to: .target(publication.startTarget)) }
        } else {
            session.go(to: .target(publication.startTarget))
        }
        if session.placement == nil, let first = session.readableSpine.first { session.go(to: .spine(first)) }
        guard session.placement != nil else {
            showStatus("Could not open book", detail: "The book has no readable chapters.")
            return
        }
        installSurface()
        installButtons()
        readerControls.page.adjust = { [weak self] amount in
            guard let self else { return }
            // VoiceOver stays on the adjustable element and speaks its new value.
            adjusting = true
            defer { adjusting = false }
            if amount > 0 { goForward() } else { goBackward() }
        }
        view.accessibilityElements = [readerControls.page, container]
        report()
        if approximate, !noticeShown {
            noticeShown = true
            UIAccessibility.post(notification: .announcement, argument: "Approximate position")
        }
        UIAccessibility.post(notification: .screenChanged, argument: pageFocusElement)
    }

    // MARK: - Surfaces

    private func installSurface() {
        pager?.willMove(toParent: nil); pager?.view.removeFromSuperview(); pager?.removeFromParent(); pager = nil
        continuous?.removeFromSuperview(); continuous = nil
        strip?.removeFromSuperview(); strip = nil
        guard let session, let placement = session.placement else { return }
        if layoutMode != .continuous, EPUBAccessibilityModel.preferred == .blocks {
            let strip = EPUBPageStripView(frame: container.bounds)
            strip.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            strip.isRightToLeft = session.publication.package.pageProgression == .rightToLeft
            strip.stripDelegate = self
            container.addSubview(strip)
            strip.addGestureRecognizer(tapRecognizer())
            self.strip = strip
            loadStrip(showing: placement)
        } else if layoutMode == .continuous {
            let scroll = EPUBContinuousStripView(frame: container.bounds)
            scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            scroll.stripDelegate = self
            container.addSubview(scroll)
            continuous = scroll
            scroll.addGestureRecognizer(tapRecognizer())
            loadContinuous(offset: session.anchor?.renderedOffset ?? 0, spineIndex: placement.spineIndex)
        } else {
            let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal, options: nil)
            pager.dataSource = self
            pager.delegate = self
            addChild(pager)
            pager.view.frame = container.bounds
            pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(pager.view)
            pager.didMove(toParent: self)
            pager.setViewControllers([pageController(for: placement)], direction: .forward, animated: false)
            pager.view.addGestureRecognizer(tapRecognizer())
            self.pager = pager
        }
        prefetchNeighbour()
    }

    private func tapRecognizer() -> UITapGestureRecognizer {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        return tap
    }

    private func pageController(for placement: EPUBPlacement) -> EPUBPageController {
        let controller = EPUBPageController(placement: placement)
        show(placement, in: controller)
        return controller
    }

    private func show(_ placement: EPUBPlacement, in controller: EPUBPageController) {
        let chapter = session?.chapter(placement.spineIndex)
        let title = session?.contentsEntry(spineIndex: placement.spineIndex, offset: 0)?.label ?? chapter?.text.title ?? summary.title
        controller.update(to: placement)
        controller.pageView.delegate = self
        controller.pageView.isRightToLeft = session?.publication.package.pageProgression == .rightToLeft
        controller.pageView.show(session?.layout(placement.spineIndex), page: placement.pageIndex, spineIndex: placement.spineIndex, chapter: chapter?.text, title: title)
    }

    /// The element VoiceOver should land on for the shown page (Spec 14.3).
    private var pageFocusElement: Any? {
        if let strip { return strip.firstElementOnShownPage ?? strip }
        guard let pageView = currentPageView else { return continuous }
        return pageView.focusElement
    }

    // MARK: - EPUBPageViewDelegate

    func pageView(_ view: EPUBPageView, turnPage forward: Bool) -> Bool {
        guard let session else { return false }
        voiceOverTurning = true
        defer { voiceOverTurning = false }
        let moved = forward ? session.forward() : session.backward()
        guard moved else { return false }
        showPlacement(direction: forward ? .forward : .reverse, animated: false)
        return true
    }

    func pageViewPageDescription(_ view: EPUBPageView) -> String {
        guard let session, let placement = session.placement, let layout = session.layout(placement.spineIndex) else { return "" }
        return "Page \(placement.pageIndex + 1) of \(layout.pageCount)"
    }

    func pageView(_ view: EPUBPageView, activateLinkAt offset: Int) -> Bool {
        guard let session, let link = session.link(at: offset, spineIndex: view.spineIndex) else { return false }
        activate(link.target, isNoteReference: link.isNoteReference)
        return true
    }

    private var currentPageView: EPUBPageView? { (pager?.viewControllers?.first as? EPUBPageController)?.pageView }

    // MARK: - Continuous strip

    /// Loads the continuous strip's window (the chapter and its readable neighbours) with an offset at the top.
    private func loadContinuous(offset: Int, spineIndex: Int) {
        guard let session, let continuous else { return }
        var chapters: [EPUBContinuousStripView.Chapter] = []
        for spine in stripChapters(around: spineIndex) {
            guard let layout = session.layout(spine), let chapter = session.chapter(spine) else { continue }
            let title = session.contentsEntry(spineIndex: spine, offset: 0)?.label ?? chapter.text.title ?? summary.title
            chapters.append(EPUBContinuousStripView.Chapter(spineIndex: spine, layout: layout, text: chapter.text, title: title))
        }
        continuousSpine = spineIndex
        continuous.load(chapters, showing: offset, in: spineIndex)
    }

    func continuousStrip(_ strip: EPUBContinuousStripView, didSettleAt offset: Int, spineIndex: Int) {
        guard let session else { return }
        session.show(visibleOffset: offset, spineIndex: spineIndex)
        if spineIndex != continuousSpine {
            // Reading crossed into the next chapter: the window moves on; elements already present keep their objects.
                loadContinuous(offset: offset, spineIndex: spineIndex)
        }
        prefetchNeighbour()
        report()
    }

    func continuousStrip(_ strip: EPUBContinuousStripView, activateLinkAt offset: Int, spineIndex: Int) -> Bool {
        guard let session, let link = session.link(at: offset, spineIndex: spineIndex) else { return false }
        activate(link.target, isNoteReference: link.isNoteReference)
        return true
    }

    func continuousStrip(_ strip: EPUBContinuousStripView, describeOffset offset: Int, spineIndex: Int) -> String {
        guard let session, let locator = session.currentLocator() else { return "" }
        return "Location \(locator.location) of \(session.scale.totalLocations)"
    }

    // MARK: - Page strip

    /// The chapters the strip holds: the current one and its readable neighbours.
    private func stripChapters(around spineIndex: Int) -> [Int] {
        guard let session else { return [] }
        return [session.neighbour(of: spineIndex, forward: false), spineIndex, session.neighbour(of: spineIndex, forward: true)].compactMap { $0 }
    }

    /// Loads the strip's window around a placement. Pages and paragraph elements
    /// already in the strip keep their objects, so VoiceOver's place survives.
    private func loadStrip(showing placement: EPUBPlacement) {
        guard let session, let strip else { return }
        var entries: [EPUBPageStripView.Entry] = []
        for spine in stripChapters(around: placement.spineIndex) {
            guard let layout = session.layout(spine), let chapter = session.chapter(spine) else { continue }
            let title = session.contentsEntry(spineIndex: spine, offset: 0)?.label ?? chapter.text.title ?? summary.title
            for page in 0..<layout.pageCount {
                entries.append(EPUBPageStripView.Entry(placement: EPUBPlacement(spineIndex: spine, pageIndex: page), layout: layout, chapter: chapter.text, title: title))
            }
        }
        stripSpine = placement.spineIndex
        strip.load(entries, showing: placement)
    }

    /// The chapter the strip's window is centred on.
    private var stripSpine: Int?

    func strip(_ strip: EPUBPageStripView, didShow placement: EPUBPlacement) {
        guard let session else { return }
        session.show(placement)
        if placement.spineIndex != stripSpine { loadStrip(showing: placement) }
        prefetchNeighbour()
        report()
    }

    func strip(_ strip: EPUBPageStripView, activateLinkAt offset: Int, spineIndex: Int) -> Bool {
        guard let session, let link = session.link(at: offset, spineIndex: spineIndex) else { return false }
        activate(link.target, isNoteReference: link.isNoteReference)
        return true
    }

    func strip(_ strip: EPUBPageStripView, describe placement: EPUBPlacement) -> String {
        guard let layout = session?.layout(placement.spineIndex) else { return "" }
        return "Page \(placement.pageIndex + 1) of \(layout.pageCount)"
    }

    /// Re-shows the session's placement after a jump or a relayout.
    private func showPlacement(direction: UIPageViewController.NavigationDirection = .forward, animated: Bool = false) {
        guard let session, let placement = session.placement else { return }
        if let strip {
            let loaded = strip.entries.first { $0.placement == placement }
            if loaded == nil || loaded?.layout !== session.layout(placement.spineIndex) { loadStrip(showing: placement) } else { strip.show(placement, animated: animated) }
        } else if let continuous {
            let offset = session.anchor?.renderedOffset ?? 0
            let loaded = continuous.chapters.first { $0.spineIndex == placement.spineIndex }
            if loaded == nil || loaded?.layout !== session.layout(placement.spineIndex) {
                loadContinuous(offset: offset, spineIndex: placement.spineIndex)
            } else {
                continuous.scroll(toOffset: offset, in: placement.spineIndex, animated: animated)
            }
        } else if let pager {
            let shown = pager.viewControllers?.first as? EPUBPageController
            if shown?.placement != placement || shown?.pageView.layout !== session.layout(placement.spineIndex) {
                if UIAccessibility.isVoiceOverRunning, let shown {
                    // The page element keeps its identity: VoiceOver reads the new page from the same element (APL-29).
                    show(placement, in: shown)
                    pager.setViewControllers([shown], direction: direction, animated: false)
                } else {
                    pager.setViewControllers([pageController(for: placement)], direction: direction, animated: animated && !UIAccessibility.isReduceMotionEnabled)
                }
            }
        }
        prefetchNeighbour()
        report()
    }

    private func prefetchNeighbour() {
        guard let session else { return }
        pendingLayout?.cancel()
        if let neighbour = session.neighbourToPrefetch() {
            _ = session.layout(neighbour, extent: .firstPage)
            pendingLayout = Task { [weak session] in await session?.completeLayout(neighbour) }
        } else if let current = session.placement?.spineIndex, session.cache.session(spineIndex: current, key: session.layoutKey)?.isPartial == true {
            pendingLayout = Task { [weak self, weak session] in
                await session?.completeLayout(current)
                guard let self, !Task.isCancelled else { return }
                showPlacement()
            }
        }
    }

    // MARK: - Settings and geometry

    private func applySettings() {
        guard let session else { return }
        let mode = SettingsStore.shared.readingLayout
        session.update(settings: settings, mediaContext: mediaContext)
        if mode != layoutMode { layoutMode = mode; installSurface() } else { showPlacement() }
        UIAccessibility.post(notification: .layoutChanged, argument: pageFocusElement)
    }

    private func applyGeometry() {
        guard let session else { return }
        view.layoutIfNeeded()
        session.update(contentSize: contentSize, allowsTwoColumns: allowsTwoColumns, mediaContext: mediaContext)
        showPlacement()
    }

    // MARK: - Navigation

    func goForward() {
        guard let session else { return }
        if let strip {
            if strip.turn(forward: true, animated: true) { announceTurn(chapterChanged: false) }
            return
        }
        if let continuous {
            continuous.page(forward: true)
            return
        }
        let before = session.placement?.spineIndex
        guard session.forward() else { return }
        showPlacement(direction: .forward, animated: true)
        announceTurn(chapterChanged: before != session.placement?.spineIndex)
    }

    /// After a manual turn: layoutChanged with the page element, screenChanged after a chapter change (Spec 14.3).
    private func announceTurn(chapterChanged: Bool) {
        guard !voiceOverTurning, !adjusting else { return }
        EPUBAccessibilityLog.shared.record("post \(chapterChanged ? "screenChanged" : "layoutChanged") after manual turn")
        UIAccessibility.post(notification: chapterChanged ? .screenChanged : .layoutChanged, argument: pageFocusElement)
    }

    func goBackward() {
        guard let session else { return }
        if let strip {
            if strip.turn(forward: false, animated: true) { announceTurn(chapterChanged: false) }
            return
        }
        if let continuous {
            continuous.page(forward: false)
            return
        }
        let before = session.placement?.spineIndex
        guard session.backward() else { return }
        showPlacement(direction: .reverse, animated: true)
        announceTurn(chapterChanged: before != session.placement?.spineIndex)
    }

    func go(to target: EPUBGoTarget, recordingDeparture: Bool) {
        guard let session, session.go(to: target, recordingDeparture: recordingDeparture) != nil else { return }
        showPlacement(direction: .forward, animated: false)
        UIAccessibility.post(notification: .screenChanged, argument: pageFocusElement)
    }

    // MARK: - Input

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let session else { return }
        let point = recognizer.location(in: container)
        if let strip, let hit = strip.characterIndex(at: recognizer.location(in: strip)), let link = session.link(at: hit.offset, spineIndex: hit.placement.spineIndex) {
            activate(link.target, isNoteReference: link.isNoteReference)
            return
        }
        if let continuous, let hit = continuous.characterIndex(at: recognizer.location(in: continuous)), let link = session.link(at: hit.offset, spineIndex: hit.spineIndex) {
            activate(link.target, isNoteReference: link.isNoteReference)
            return
        }
        if let pageView = currentPageView, let offset = pageView.characterIndex(at: recognizer.location(in: pageView)), let spineIndex = session.placement?.spineIndex,
           let link = session.link(at: offset, spineIndex: spineIndex) {
            activate(link.target, isNoteReference: link.isNoteReference)
            return
        }
        if continuous == nil {
            let zone = max(Self.edgeZoneMinimum, container.bounds.width * Self.edgeZoneFraction)
            let rightToLeft = session.publication.package.pageProgression == .rightToLeft
            if point.x < zone { rightToLeft ? goForward() : goBackward(); return }
            if point.x > container.bounds.width - zone { rightToLeft ? goBackward() : goForward(); return }
        }
        readerControls.tapped()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(keyForward)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(keyBackward)),
            UIKeyCommand(input: " ", modifierFlags: [], action: #selector(keyForward)),
            UIKeyCommand(input: UIKeyCommand.inputPageDown, modifierFlags: [], action: #selector(keyForward)),
            UIKeyCommand(input: UIKeyCommand.inputPageUp, modifierFlags: [], action: #selector(keyBackward))
        ].map { $0.wantsPriorityOverSystemBehavior = true; return $0 }
    }
    override var canBecomeFirstResponder: Bool { true }

    @objc private func keyForward() {
        guard session?.publication.package.pageProgression != .rightToLeft else { goBackward(); return }
        goForward()
    }
    @objc private func keyBackward() {
        guard session?.publication.package.pageProgression != .rightToLeft else { goForward(); return }
        goBackward()
    }

    // MARK: - Links and notes

    private func activate(_ target: EPUBLinkTarget, isNoteReference: Bool) {
        guard let session else { return }
        switch target {
        case .internalLink(let path, let fragment, let spineIndex):
            if isNoteReference, let note = session.noteBody(for: target) {
                presentNote(note)
            } else if let spineIndex, session.readableSpine.contains(spineIndex) {
                go(to: .target(EPUBTarget(spineIndex: spineIndex, fragment: fragment)), recordingDeparture: true)
            } else {
                session.diagnostics.record(.position, "link.outsideSpine", path: path, spineIndex: spineIndex, "A link to a resource outside the reading order was ignored.")
            }
        case .external(let url):
            let alert = UIAlertController(title: "Open link?", message: url.absoluteString, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Open", style: .default) { _ in UIApplication.shared.open(url) })
            present(alert, animated: true)
        case .refused:
            break
        }
    }

    private func presentNote(_ note: EPUBNoteBody) {
        let controller = EPUBNoteController(note: note) { [weak self] in self?.dismiss(animated: true) }
        let sheet = UINavigationController(rootViewController: controller)
        if let presentation = sheet.sheetPresentationController { presentation.detents = [.medium(), .large()] }
        present(sheet, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    // MARK: - Pager

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        neighbourController(of: viewController, forward: session?.publication.package.pageProgression == .rightToLeft)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        neighbourController(of: viewController, forward: session?.publication.package.pageProgression != .rightToLeft)
    }

    private func neighbourController(of viewController: UIViewController, forward: Bool) -> UIViewController? {
        guard let session, let current = (viewController as? EPUBPageController)?.placement, let next = session.neighbourPlacement(of: current, forward: forward) else { return nil }
        return pageController(for: next)
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let shown = (pageViewController.viewControllers?.first as? EPUBPageController)?.placement, let session else { return }
        let before = session.placement?.spineIndex
        session.show(shown)
        prefetchNeighbour()
        report()
        announceTurn(chapterChanged: before != shown.spineIndex)
    }

    // MARK: - Contents and landmarks

    private func installButtons() {
        guard let session else { return }
        var items: [UIBarButtonItem] = []
        if !session.publication.navigation.contents.isEmpty {
            let button = UIBarButtonItem(image: UIImage(systemName: "list.bullet"), primaryAction: UIAction { [weak self] _ in self?.showContents() })
            button.accessibilityLabel = "Contents"
            items.append(button)
        }
        var actions: [UIMenuElement] = []
        let start = session.publication.startTarget
        actions.append(UIAction(title: "Start reading") { [weak self] _ in self?.go(to: .target(start), recordingDeparture: true) })
        if let cover = session.publication.navigation.landmarks.first(where: { $0.semanticTerms.contains(EPUBSemantics.structure + "cover") })?.target {
            actions.append(UIAction(title: "Cover") { [weak self] _ in self?.go(to: .target(cover), recordingDeparture: true) })
        }
        if let notes = session.publication.navigation.landmarks.first(where: { !$0.semanticTerms.isDisjoint(with: EPUBSemantics.notesSectionTerms) })?.target {
            actions.append(UIAction(title: "Notes") { [weak self] _ in self?.go(to: .target(notes), recordingDeparture: true) })
        }
        actions.append(UIAction(title: "Go to Location…") { [weak self] _ in self?.askForLocation() })
        actions.append(UIAction(title: "Back") { [weak self] _ in
            guard let self, session.goBack() != nil else { return }
            showPlacement()
        })
        let menu = UIBarButtonItem(image: UIImage(systemName: "arrow.turn.down.right"), menu: UIMenu(children: actions))
        menu.accessibilityLabel = "Go to"
        items.append(menu)
        navigationItem.rightBarButtonItems = items
    }

    private func showContents() {
        guard let session else { return }
        let list = BookContentsController(entries: session.publication.navigation.contents) { [weak self] target in
            guard let self else { return }
            dismiss(animated: true)
            go(to: .target(target), recordingDeparture: true)
        }
        let sheet = UINavigationController(rootViewController: list)
        present(sheet, animated: true)
    }

    private func askForLocation() {
        guard let session else { return }
        let total = session.scale.totalLocations
        let alert = UIAlertController(title: "Go to Location", message: "1 to \(total)", preferredStyle: .alert)
        alert.addTextField { $0.keyboardType = .numberPad; $0.placeholder = "Location" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Go", style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text, let location = Int(text), location >= 1, location <= total else { return }
            self?.go(to: .location(location), recordingDeparture: true)
        })
        present(alert, animated: true)
    }

    // MARK: - Position

    /// The current-location report: the page element's value and the save (Spec 12.4).
    private func report() {
        guard let session, let relocation = session.relocationIfChanged() else { return }
        let chapter = relocation.contentsEntry?.label ?? relocation.locator.title ?? "Chapter \(relocation.locator.spineIndex + 1)"
        readerControls.positionValue = continuous == nil
            ? "\(chapter), page \(relocation.pageIndex + 1) of \(relocation.pageCount)"
            : "\(chapter), location \(relocation.location) of \(relocation.totalLocations)"
        scheduleSave(relocation.locator)
    }

    /// Scrolling reports many positions; write the last one after a short pause.
    private func scheduleSave(_ locator: EPUBLocator) {
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

/// One page of the pager. Under VoiceOver the same controller shows page
/// after page, so the page element VoiceOver holds never changes identity.
@MainActor
final class EPUBPageController: UIViewController {
    private(set) var placement: EPUBPlacement
    let pageView = EPUBPageView()

    init(placement: EPUBPlacement) {
        self.placement = placement
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() { view = pageView }

    func update(to placement: EPUBPlacement) { self.placement = placement }
}

/// A note's blocks in a sheet: the text first, "Return to text" last (Spec 13.4).
@MainActor
final class EPUBNoteController: UIViewController {
    private let note: EPUBNoteBody
    private let dismissAction: () -> Void

    init(note: EPUBNoteBody, dismiss: @escaping () -> Void) {
        self.note = note
        dismissAction = dismiss
        super.init(nibName: nil, bundle: nil)
        title = "Note"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let text = UITextView()
        text.translatesAutoresizingMaskIntoConstraints = false
        text.isEditable = false
        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.text = note.text
        text.accessibilityLabel = note.text
        let button = UIButton(configuration: .borderedProminent(), primaryAction: UIAction(title: "Return to text") { [weak self] _ in self?.dismissAction() })
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(text)
        view.addSubview(button)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: view.readableContentGuide.leadingAnchor),
            text.trailingAnchor.constraint(equalTo: view.readableContentGuide.trailingAnchor),
            text.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            button.topAnchor.constraint(equalTo: text.bottomAnchor, constant: EPUBPageView.margin),
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -EPUBPageView.margin)
        ])
        view.accessibilityElements = [text, button]
    }
}

/// The book's chapters as a list; nested sections are indented and announce their level.
@MainActor
final class BookContentsController: FunstonListController {
    private let entries: [(entry: EPUBContentsEntry, depth: Int)]
    private let choose: (EPUBTarget) -> Void
    private static let indentPerLevel: CGFloat = 16

    init(entries: [EPUBContentsEntry], choose: @escaping (EPUBTarget) -> Void) {
        self.entries = entries.flatMap { $0.flattened() }
        self.choose = choose
        super.init(title: "Contents")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        apply(entries.enumerated().map { index, item in
            var row = FunstonRow(id: "chapter:\(index)", title: item.entry.label.isEmpty ? "Untitled section" : item.entry.label)
            row.accessibilityValue = "Level \(item.depth + 1)"
            row.navigates = item.entry.target != nil
            return row
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
        guard let index = Int(id.dropFirst("chapter:".count)), entries.indices.contains(index), let target = entries[index].entry.target else { return }
        choose(target)
    }
}
