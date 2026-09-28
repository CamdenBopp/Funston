import UIKit
import SwiftUI
import Combine
import XCTest
@testable import Archive

final class ArchiveUIPresentationTests: XCTestCase {
    func testTransportButtonMatchesActionWhilePreparing() {
        XCTAssertTrue(PlaybackPhase.preparing.showsPauseControl(wantsToPlay: true))
        XCTAssertFalse(PlaybackPhase.preparing.showsPauseControl(wantsToPlay: false))
        XCTAssertTrue(PlaybackPhase.buffering.showsPauseControl(wantsToPlay: true))
        XCTAssertTrue(PlaybackPhase.playing.showsPauseControl(wantsToPlay: true))
        for phase in [PlaybackPhase.paused, .ended, .idle, .failed("Unavailable")] {
            XCTAssertFalse(phase.showsPauseControl(wantsToPlay: false))
        }
    }

    @MainActor
    func testMediaPrimaryActionsNeverExposeRestrictedOrPrivateFiles() {
        let summary = ArtifactSummary(identifier: "book", title: "Book", mediaType: .texts)
        let publicPDF = ArchiveFile(name: "book.pdf", format: "Text PDF", size: 400)
        let privatePDF = ArchiveFile(name: "private.pdf", format: "Text PDF", size: 100, isPrivate: true)
        for access in [ArtifactAccess.restricted, .unresolved] {
            let detail = ArtifactDetail(summary: summary, files: [publicPDF], access: access)
            XCTAssertNil(ArtifactMediaPresentation.preferredFile(in: detail))
            XCTAssertNil(ArtifactMediaPresentation.actionTitle(for: detail))
        }
        XCTAssertNil(ArtifactMediaPresentation.actionTitle(for: ArtifactDetail(summary: summary, files: [privatePDF])))
        let detail = ArtifactDetail(summary: summary, files: [privatePDF, publicPDF])
        XCTAssertEqual(ArtifactMediaPresentation.preferredFile(in: detail), publicPDF)
        XCTAssertEqual(ArtifactMediaPresentation.actionTitle(for: detail), "Read PDF")
    }

    @MainActor
    func testMediaPrimaryActionPrefersNativeVideoAndSupportsMKVFallback() {
        let summary = ArtifactSummary(identifier: "film", title: "Film", mediaType: .movies)
        let unsupported = ArchiveFile(name: "source.avi", size: 100)
        let mkv = ArchiveFile(name: "source.mkv", size: 100)
        let mp4 = ArchiveFile(name: "film.MP4", size: 200)
        XCTAssertNil(ArtifactMediaPresentation.actionTitle(for: ArtifactDetail(summary: summary, files: [unsupported])))
        XCTAssertEqual(ArtifactMediaPresentation.preferredFile(in: ArtifactDetail(summary: summary, files: [mkv])), mkv)
        XCTAssertEqual(ArtifactMediaPresentation.actionTitle(for: ArtifactDetail(summary: summary, files: [mkv])), "Watch Film")
        let detail = ArtifactDetail(summary: summary, files: [unsupported, mkv, mp4])
        XCTAssertEqual(ArtifactMediaPresentation.preferredFile(in: detail), mp4)
        XCTAssertEqual(ArtifactMediaPresentation.actionTitle(for: detail), "Watch Film")
    }

    @MainActor
    func testAudioArtifactKeepsPlayAsPrimaryActionDespitePDFDerivative() {
        let summary = ArtifactSummary(identifier: "radio", title: "Radio show", mediaType: .audio)
        let detail = ArtifactDetail(summary: summary, files: [ArchiveFile(name: "notes.pdf")],
                                    tracks: [PlayableTrack(id: "track", title: "Episode", candidates: [ArchiveFile(name: "show.mp3")])])
        XCTAssertNil(ArtifactMediaPresentation.actionTitle(for: detail))
        XCTAssertNil(ArtifactMediaPresentation.preferredFile(in: detail))
    }

    @MainActor
    func testArtifactHeaderFitsNarrowWidthAndReflowsAtAccessibilitySize() async throws {
        let delegate = try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate)
        let environment = try await delegate.prepareEnvironment()
        let summary = ArtifactSummary(identifier: "header-layout", title: "A long archive title with a historical recording and publication date", creators: ["A creator with a long name"], mediaType: .audio)
        let header = ArtifactOverview(summary: summary, playable: true, restricted: false, isSaved: false,
                                      saveTitle: "Save to Library", downloads: environment.downloads, file: nil, play: {}, save: {})
        let ordinary = UIHostingController(rootView: header.environment(\.dynamicTypeSize, .large))
        let large = UIHostingController(rootView: header.environment(\.dynamicTypeSize, .accessibility3))
        let ordinarySize = ordinary.sizeThatFits(in: CGSize(width: 288, height: 10_000))
        let largeSize = large.sizeThatFits(in: CGSize(width: 288, height: 10_000))
        XCTAssertLessThanOrEqual(ordinarySize.width, 289)
        XCTAssertLessThanOrEqual(largeSize.width, 289)
        XCTAssertGreaterThan(largeSize.height, ordinarySize.height)
    }

    @MainActor
    func testDuplicateRowsCannotEnterTheDiffableSnapshot() {
        let controller = ArchiveListController(title: "Fixture")
        controller.loadViewIfNeeded()
        controller.apply([
            ArchiveRow(id: "collection:radio", title: "Radio"),
            ArchiveRow(id: "collection:radio", title: "Duplicate"),
            ArchiveRow(id: "files", title: "Files")
        ])
        XCTAssertEqual(controller.rows.map(\.id), ["collection:radio", "files"])
        XCTAssertEqual(controller.rows.first?.title, "Radio")
    }

    @MainActor
    func testDetailHistoriesRoundTripAcrossColumnsWithoutDuplication() {
        let exploreRoot = UIViewController()
        let collection = UIViewController()
        let searchRoot = UIViewController()
        let explore = DestinationNavigationHistory(navigation: UINavigationController(rootViewController: exploreRoot))
        let search = DestinationNavigationHistory(navigation: UINavigationController(rootViewController: searchRoot))
        explore.navigation.pushViewController(collection, animated: false)
        let radio = UIViewController()
        let tracks = UIViewController()
        let book = UIViewController()
        explore.replaceDetail(with: radio).pushViewController(tracks, animated: false)
        search.replaceDetail(with: book)

        for _ in 0..<3 {
            explore.collapseDetail()
            search.collapseDetail()
            XCTAssertEqual(explore.navigation.viewControllers.map(ObjectIdentifier.init), [exploreRoot, collection, radio, tracks].map(ObjectIdentifier.init))
            XCTAssertEqual(search.navigation.viewControllers.map(ObjectIdentifier.init), [searchRoot, book].map(ObjectIdentifier.init))
            explore.expandDetail()
            search.expandDetail()
            XCTAssertEqual(explore.navigation.viewControllers.map(ObjectIdentifier.init), [exploreRoot, collection].map(ObjectIdentifier.init))
            XCTAssertEqual(explore.detail?.viewControllers.map(ObjectIdentifier.init), [radio, tracks].map(ObjectIdentifier.init))
            XCTAssertTrue(search.detail?.topViewController === book)
        }
    }

    @MainActor
    func testBackInCompactWidthDiscardsOnlyThePoppedDetailHistory() {
        let root = UIViewController()
        let history = DestinationNavigationHistory(navigation: UINavigationController(rootViewController: root))
        let artifact = UIViewController()
        let file = UIViewController()
        history.replaceDetail(with: artifact).pushViewController(file, animated: false)
        history.collapseDetail()
        history.navigation.popViewController(animated: false)
        history.expandDetail()
        XCTAssertEqual(history.detail?.viewControllers.count, 1)
        XCTAssertTrue(history.detail?.topViewController === artifact)
        history.collapseDetail()
        history.navigation.popViewController(animated: false)
        history.expandDetail()
        XCTAssertNil(history.detail)
        XCTAssertTrue(history.navigation.topViewController === root)
    }

    @MainActor
    func testCompactArtifactGetsItsOwnColumnWhenExpanded() {
        let root = UIViewController()
        let artifact = UIViewController()
        let history = DestinationNavigationHistory(navigation: UINavigationController(rootViewController: root))
        history.pushCompactDetail(artifact, animated: false)
        history.navigation.additionalSafeAreaInsets.bottom = 96
        history.expandDetail(bottomInset: 96)
        XCTAssertTrue(history.navigation.topViewController === root)
        XCTAssertTrue(history.detail?.topViewController === artifact)
        XCTAssertEqual(history.detail?.additionalSafeAreaInsets.bottom, 96)
        history.collapseDetail()
        history.expandDetail(bottomInset: 96)
        XCTAssertEqual(history.detail?.additionalSafeAreaInsets.bottom, 96)
    }

    func testProgressFormatsOnlyChangedDownloadRows() {
        var records = (0..<1_000).map { index in
            DownloadRecord(key: "\(index)", identifier: "artifact-\(index)", fileName: "recording.mp3", title: "Recording \(index)", expectedBytes: 100, localPath: "/unused/\(index)", state: .downloading, receivedBytes: 0, totalBytes: 100, errorMessage: nil, updatedAt: .distantPast)
        }
        var projection = DownloadRowProjection()
        let initial = projection.update(records)
        XCTAssertTrue(initial.replacesContents)
        XCTAssertEqual(initial.rows.count, 1_000)
        records[42].receivedBytes = 50
        let progress = projection.update(records)
        XCTAssertFalse(progress.replacesContents)
        XCTAssertEqual(progress.rows.map(\.id), ["42"])
        XCTAssertTrue(projection.update(records).rows.isEmpty)
        records.remove(at: 42)
        XCTAssertTrue(projection.update(records).replacesContents)
    }

    @MainActor
    func testArtifactSaveLabelUsesPublishedValueBeforeStoredPropertyChanges() {
        let source = SavedArtifactsFixture()
        let artifact = ArtifactSummary(identifier: "saved", title: "Recording")
        let state = ArtifactSavedState(identifier: artifact.identifier)
        var labels: [String] = []
        var storedValues: [Bool] = []
        state.observe(source.$saved.eraseToAnyPublisher()) { [weak state, weak source] in
            labels.append(state?.actionTitle ?? "")
            storedValues.append(source?.saved.contains(artifact) ?? false)
        }
        source.saved = [artifact]
        XCTAssertTrue(state.isSaved)
        source.saved = []
        XCTAssertFalse(state.isSaved)
        XCTAssertEqual(labels, ["Save to Library", "Remove from Library", "Save to Library"])
        XCTAssertEqual(storedValues, [false, false, true], "The label must not read this old @Published backing property.")
    }

    func testPlayerTimePresentationRejectsOversizedAndNonfiniteValues() {
        for value in [Double.greatestFiniteMagnitude, Double(Int64.max), .infinity, .nan, -1] {
            XCTAssertEqual(PlayerTimePresentation.clock(value), "—")
            XCTAssertEqual(PlayerTimePresentation.spoken(value), "Time unavailable")
            XCTAssertEqual(PlayerTimePresentation.clampedPosition(value, duration: 60), 0)
        }
        XCTAssertEqual(PlayerTimePresentation.clock(125.75), "2:05")
        XCTAssertEqual(PlayerTimePresentation.clampedPosition(100, duration: 60), 60)
        XCTAssertEqual(PlayerTimePresentation.clampedPosition(30, duration: .greatestFiniteMagnitude), 0)
        XCTAssertFalse(PlayerTimePresentation.clock(MediaDuration.maximumSeconds).isEmpty)
        XCTAssertFalse(PlayerTimePresentation.spoken(MediaDuration.maximumSeconds).isEmpty)
    }

    @MainActor
    func testHeldSearchRequestDoesNotRetainItsController() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(url: directory.appending(path: "cache.sqlite3"))
        let transport = UIPresentationCancellableTransport()
        var controller: SearchController? = SearchController(repository: CachingArchiveRepository(store: store, transport: transport), collection: ArchiveCollection(identifier: "fixture", title: "Fixture", description: ""), open: { _ in })
        weak let reference = controller
        controller?.loadViewIfNeeded()
        await waitForRequest(transport)
        controller = nil
        await waitFor { reference == nil }
        XCTAssertNil(reference)
        await waitForCancellation(transport)
        let wasCancelled = await transport.cancelled
        XCTAssertTrue(wasCancelled)
        await transport.cancel()
    }

    @MainActor
    func testHeldArtifactRequestDoesNotRetainItsController() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(url: directory.appending(path: "cache.sqlite3"))
        let transport = UIPresentationCancellableTransport()
        let delegate = try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate)
        let environment = try await delegate.prepareEnvironment()
        var controller: ArtifactController? = ArtifactController(environment: environment, summary: ArtifactSummary(identifier: "held-artifact", title: "Held recording"), repository: CachingArchiveRepository(store: store, transport: transport), openCollection: { _ in })
        weak let reference = controller
        controller?.loadViewIfNeeded()
        await waitForRequest(transport)
        controller = nil
        await waitFor { reference == nil }
        XCTAssertNil(reference)
        await waitForCancellation(transport)
        let wasCancelled = await transport.cancelled
        XCTAssertTrue(wasCancelled)
        await transport.cancel()
    }

    @MainActor
    func testSearchShowsStaleRowsBeforeRefreshAndKeepsThemOnFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(url: directory.appending(path: "cache.sqlite3"))
        let request = SearchRequest(collection: "fixture")
        let page = SearchPage(items: [ArtifactSummary(identifier: "saved", title: "Saved recording")], total: 1, page: 1, pageSize: 40)
        try await store.storeCache(key: "search:\(request.cacheKey)", kind: "search", response: Data(), snapshot: JSONEncoder().encode(page), maxAge: -1)
        let transport = UIPresentationGateTransport()
        let repository = CachingArchiveRepository(store: store, transport: transport)
        let controller = SearchController(repository: repository, collection: ArchiveCollection(identifier: "fixture", title: "Fixture", description: ""), open: { _ in })
        controller.loadViewIfNeeded()
        await waitFor { controller.rows.contains { $0.id == "artifact:saved" } }
        XCTAssertTrue(controller.rows.contains { $0.id == "artifact:saved" })
        XCTAssertTrue(controller.rows.contains { $0.id == "__cacheStatus" && $0.subtitle != nil })
        await transport.fail()
        await waitFor { controller.rows.contains { $0.id == "__retry:1" } }
        XCTAssertTrue(controller.rows.contains { $0.id == "artifact:saved" })
        XCTAssertTrue(controller.rows.contains { $0.id == "__retry:1" })
        XCTAssertNil(controller.contentUnavailableConfiguration)
    }

    @MainActor
    func testCachedEmptySearchIsPresentedAsSavedResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(url: directory.appending(path: "cache.sqlite3"))
        let request = SearchRequest(collection: "fixture")
        let page = SearchPage(items: [], total: 0, page: 1, pageSize: 40)
        try await store.storeCache(key: "search:\(request.cacheKey)", kind: "search", response: Data(), snapshot: JSONEncoder().encode(page), maxAge: -1)
        let transport = UIPresentationGateTransport()
        let controller = SearchController(repository: CachingArchiveRepository(store: store, transport: transport), collection: ArchiveCollection(identifier: "fixture", title: "Fixture", description: ""), open: { _ in })
        controller.loadViewIfNeeded()
        await waitFor { (controller.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)?.text == "No matches in saved results" }
        XCTAssertEqual((controller.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)?.text, "No matches in saved results")
        await transport.fail()
        await waitFor { (controller.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)?.button.title == "Try Again" }
        XCTAssertEqual((controller.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)?.text, "No matches in saved results")
        XCTAssertEqual((controller.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)?.button.title, "Try Again")
    }

    @MainActor
    private func waitFor(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private func waitForRequest(_ transport: UIPresentationCancellableTransport) async {
        for _ in 0..<100 {
            if await transport.started { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The held request did not start.")
    }

    @MainActor
    private func waitForCancellation(_ transport: UIPresentationCancellableTransport) async {
        for _ in 0..<100 {
            if await transport.cancelled { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class SavedArtifactsFixture {
    @Published var saved: [ArtifactSummary] = []
}

private actor UIPresentationCancellableTransport: ArchiveTransport {
    private var pending: CheckedContinuation<ArchiveHTTPResponse, any Error>?
    private(set) var started = false
    private(set) var cancelled = false
    func send(_ request: URLRequest) async throws -> ArchiveHTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                started = true
                if cancelled { continuation.resume(throwing: CancellationError()) }
                else { pending = continuation }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }
    func cancel() {
        cancelled = true
        pending?.resume(throwing: CancellationError())
        pending = nil
    }
}

private actor UIPresentationGateTransport: ArchiveTransport {
    private var pending: CheckedContinuation<ArchiveHTTPResponse, any Error>?
    private var shouldFail = false
    func send(_ request: URLRequest) async throws -> ArchiveHTTPResponse {
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func fail() {
        shouldFail = true
        pending?.resume(throwing: URLError(.notConnectedToInternet))
        pending = nil
    }
}
