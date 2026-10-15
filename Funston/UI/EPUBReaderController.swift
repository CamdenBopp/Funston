import UIKit
import Combine
import OSLog

/// Reads a born-digital EPUB with the native reader. The book is downloaded
/// first (it stays in Downloads for offline reading), then opened from the local
/// file under a lease so removing the download can't pull it out from under us.
/// Text size follows Dynamic Type and colors follow Dark Mode; the layout
/// setting picks pages or continuous scrolling.
@MainActor
final class EPUBReaderController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate, EPUBPageViewDelegate {
    private static let logger = Logger(subsystem: "com.camden.Funston", category: "Books")
    /// Body text at the default Dynamic Type size is 17 pt.
    static let bodyPointSize: CGFloat = 17
    private static let positionSaveDelay: Duration = .seconds(1)
    /// One report after scrolling stops (Spec 12.4).
    private static let settleReportDelay: Duration = .milliseconds(300)
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
    private var pendingReport: Task<Void, Never>?
    private var pendingLayout: Task<Void, Never>?
    private var lastLocator: EPUBLocator?
    private var session: EPUBReaderSession?
    private var pager: UIPageViewController?
    private var continuous: EPUBContinuousView?
    private var layoutMode: PDFReadingLayout = .pages
    private let container = UIView()
    private let banner = UILabel()
    private var noticeShown = false
    /// True while VoiceOver's own read-all is turning pages: nothing may move its focus (APL-33).
    private var voiceOverTurning = false
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
        guard let session, let placement = session.placement else { return }
        if layoutMode == .continuous {
            let scroll = EPUBContinuousView(frame: container.bounds)
            scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            scroll.crossingRequested = { [weak self] direction in self?.crossChapter(direction) }
            scroll.settled = { [weak self] in self?.continuousSettled() }
            container.addSubview(scroll)
            continuous = scroll
            scroll.pageDelegate = self
            scroll.show(session.layout(placement.spineIndex), spineIndex: placement.spineIndex, chapter: session.chapter(placement.spineIndex)?.text, title: session.chapter(placement.spineIndex)?.text.title ?? summary.title, atOffset: session.anchor?.renderedOffset)
            scroll.addGestureRecognizer(tapRecognizer())
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

    func pageView(_ view: EPUBPageView, linkAt offset: Int) -> (label: String, isNote: Bool)? {
        guard let session, let link = session.link(at: offset, spineIndex: view.spineIndex), let chapter = session.chapter(view.spineIndex) else { return nil }
        return (chapter.text.text(in: link.range.range), link.isNoteReference)
    }

    func surface(_ view: EPUBContinuousView, activateLinkAt offset: Int) -> Bool {
        guard let session, let link = session.link(at: offset, spineIndex: view.spineIndex) else { return false }
        activate(link.target, isNoteReference: link.isNoteReference)
        return true
    }

    private var currentPageView: EPUBPageView? { (pager?.viewControllers?.first as? EPUBPageController)?.pageView }

    /// Re-shows the session's placement after a jump or a relayout.
    private func showPlacement(direction: UIPageViewController.NavigationDirection = .forward, animated: Bool = false) {
        guard let session, let placement = session.placement else { return }
        if let continuous {
            if continuous.spineIndex != placement.spineIndex || continuous.layout !== session.layout(placement.spineIndex) {
                continuous.show(session.layout(placement.spineIndex), spineIndex: placement.spineIndex, chapter: session.chapter(placement.spineIndex)?.text, title: session.chapter(placement.spineIndex)?.text.title ?? summary.title, atOffset: session.anchor?.renderedOffset)
            } else if let offset = session.anchor?.renderedOffset {
                continuous.scroll(toOffset: offset, animated: animated)
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
        if let continuous {
            if continuous.page(forward: true, animated: !UIAccessibility.isReduceMotionEnabled) { scheduleSettleReport() } else { crossChapter(1) }
            return
        }
        let before = session.placement?.spineIndex
        guard session.forward() else { return }
        showPlacement(direction: .forward, animated: true)
        announceTurn(chapterChanged: before != session.placement?.spineIndex)
    }

    /// After a manual turn: layoutChanged with the page element, screenChanged after a chapter change (Spec 14.3).
    private func announceTurn(chapterChanged: Bool) {
        guard !voiceOverTurning else { return }
        EPUBAccessibilityLog.shared.record("post \(chapterChanged ? "screenChanged" : "layoutChanged") after manual turn")
        UIAccessibility.post(notification: chapterChanged ? .screenChanged : .layoutChanged, argument: pageFocusElement)
    }

    func goBackward() {
        guard let session else { return }
        if let continuous {
            if continuous.page(forward: false, animated: !UIAccessibility.isReduceMotionEnabled) { scheduleSettleReport() } else { crossChapter(-1) }
            return
        }
        let before = session.placement?.spineIndex
        guard session.backward() else { return }
        showPlacement(direction: .reverse, animated: true)
        announceTurn(chapterChanged: before != session.placement?.spineIndex)
    }

    /// Continuous mode: the neighbouring chapter at its top (or bottom).
    private func crossChapter(_ direction: Int) {
        EPUBAccessibilityLog.shared.record("continuous crossChapter direction=\(direction) from spine=\(session?.placement?.spineIndex ?? -1)")
        guard let session, let current = session.placement?.spineIndex, let neighbour = session.neighbour(of: current, forward: direction > 0), let layout = session.layout(neighbour) else { return }
        let offset = direction > 0 ? 0 : (layout.table.pages.last?.firstOffset ?? 0)
        session.show(visibleOffset: offset, spineIndex: neighbour)
        continuous?.show(layout, spineIndex: neighbour, chapter: session.chapter(neighbour)?.text, title: session.chapter(neighbour)?.text.title ?? summary.title, atOffset: offset)
        prefetchNeighbour()
        report()
        UIAccessibility.post(notification: .screenChanged, argument: container)
    }

    private func continuousSettled() {
        guard let continuous, let session, let offset = continuous.firstVisibleOffset else { return }
        EPUBAccessibilityLog.shared.record("continuous settled spine=\(continuous.spineIndex) offset=\(offset) contentOffset=\(continuous.contentOffset.y)")
        session.show(visibleOffset: offset, spineIndex: continuous.spineIndex)
        scheduleSettleReport()
    }

    private func scheduleSettleReport() {
        pendingReport?.cancel()
        pendingReport = Task { [weak self] in
            do { try await Task.sleep(for: Self.settleReportDelay) } catch { return }
            guard let self else { return }
            if let continuous, let offset = continuous.firstVisibleOffset { session?.show(visibleOffset: offset, spineIndex: continuous.spineIndex) }
            report()
        }
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
        if let offset = (continuous.map { $0.characterIndex(at: recognizer.location(in: $0)) } ?? currentPageView.map { $0.characterIndex(at: recognizer.location(in: $0)) }) ?? nil,
           let spineIndex = continuous?.spineIndex ?? session.placement?.spineIndex, let link = session.link(at: offset, spineIndex: spineIndex) {
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
