import UIKit
import SwiftUI
import Combine
import XCTest
@testable import Funston

final class FunstonUIPresentationTests: XCTestCase {
    /// The Explore shelf's "Gunsmoke - Single Episodes" item carries this exact
    /// date string; VoiceOver used to read the whole timestamp aloud.
    func testDatesNeverExposeTimestamps() {
        let gunsmoke = ArtifactSummary(identifier: "gunsmoke", title: "Gunsmoke - Single Episodes",
                                       creators: ["Old Time Radio Researchers Group"], date: "2020-01-05T00:00:00Z", mediaType: .audio)
        XCTAssertEqual(gunsmoke.displayDate, "2020-01-05")
        XCTAssertEqual(gunsmoke.displayYear, "2020")
        XCTAssertEqual(gunsmoke.spokenSummary, "Gunsmoke - Single Episodes, Old Time Radio Researchers Group, 2020, Audio")
        XCTAssertFalse(FunstonRow.artifact(gunsmoke).subtitle?.contains("T00") ?? true)

        let circa = ArtifactSummary(identifier: "circa", title: "Circa", date: "c. 1950")
        XCTAssertEqual(circa.displayDate, "c. 1950")
        XCTAssertEqual(circa.displayYear, "1950")
        XCTAssertEqual(ArtifactSummary(identifier: "month", title: "Month", date: "1950-03").displayDate, "1950-03")
    }

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
        let controller = FunstonListController(title: "Fixture")
        controller.loadViewIfNeeded()
        controller.apply([
            FunstonRow(id: "collection:radio", title: "Radio"),
            FunstonRow(id: "collection:radio", title: "Duplicate"),
            FunstonRow(id: "files", title: "Files")
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

    func testSingleDownloadedFileIsPresentedAsAFileNotAWholeArtifact() throws {
        let record = DownloadRecord(
            key: "catalog/file",
            identifier: "whole-earth-catalog",
            fileName: "scans/Whole%20Earth%20Catalog_text.pdf",
            title: "Whole Earth Catalog",
            expectedBytes: 100,
            localPath: "/unused/catalog.pdf",
            state: .completed,
            receivedBytes: 100,
            totalBytes: 100,
            errorMessage: nil,
            updatedAt: .now
        )

        var projection = DownloadRowProjection()
        let row = try XCTUnwrap(projection.update([record]).rows.first)
        XCTAssertEqual(row.title, "Whole Earth Catalog_text.pdf")
        XCTAssertEqual(row.subtitle, "From Whole Earth Catalog\nFile available offline")
        XCTAssertNotEqual(row.title, record.title, "The artifact title must not imply that every file in it is downloaded")
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

    func testPositionValueSaysTimeLeftAtTheCurrentSpeed() {
        let elapsed = 4.0 * 60 + 12, duration = 28.0 * 60 + 57
        XCTAssertEqual(PlayerTimePresentation.spokenPosition(elapsed, duration: duration, rate: 1),
                       "4 minutes, 12 seconds of 28 minutes, 57 seconds, 25 minutes left")
        XCTAssertEqual(PlayerTimePresentation.spokenPosition(elapsed, duration: duration, rate: 2),
                       "4 minutes, 12 seconds of 28 minutes, 57 seconds, 12 minutes left")
        XCTAssertEqual(PlayerTimePresentation.spokenPosition(elapsed, duration: duration, rate: 0),
                       "4 minutes, 12 seconds of 28 minutes, 57 seconds, 25 minutes left",
                       "A paused or unset rate counts as normal speed.")
        XCTAssertTrue(PlayerTimePresentation.spokenPosition(duration - 10, duration: duration, rate: 1)
            .hasSuffix(", less than a minute left"))
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
        var controller: SearchController? = SearchController(repository: CachingArchiveRepository(store: store, transport: transport), collection: ArchiveCollection(identifier: "fixture", title: "Fixture"), open: { _ in })
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
        let response = try JSONSerialization.data(withJSONObject: ["response": ["numFound": page.total, "docs": page.items.map { ["identifier": $0.identifier, "title": $0.rawTitle] }]])
        try await store.storeCache(key: CachingArchiveRepository.searchCacheKey(request), kind: "search", response: response, snapshot: JSONEncoder().encode(page), maxAge: -1)
        let transport = UIPresentationGateTransport()
        let repository = CachingArchiveRepository(store: store, transport: transport)
        let controller = SearchController(repository: repository, collection: ArchiveCollection(identifier: "fixture", title: "Fixture"), open: { _ in })
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
        let response = try JSONSerialization.data(withJSONObject: ["response": ["numFound": page.total, "docs": page.items.map { ["identifier": $0.identifier, "title": $0.rawTitle] }]])
        try await store.storeCache(key: CachingArchiveRepository.searchCacheKey(request), kind: "search", response: response, snapshot: JSONEncoder().encode(page), maxAge: -1)
        let transport = UIPresentationGateTransport()
        let controller = SearchController(repository: CachingArchiveRepository(store: store, transport: transport), collection: ArchiveCollection(identifier: "fixture", title: "Fixture"), open: { _ in })
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

/// Exercise real compositional layouts, including unseen, longer titles.
@MainActor
final class ExploreScrollingTests: XCTestCase {
    func testEveryShelfKeepsItsHeightAndTilesVisibleThroughPartialSwipes() async throws {
        let mounted = try await MountedExplore(includeContinue: true)
        defer { mounted.close() }
        let collection = mounted.controller.collectionView!
        for _ in 0..<100 where collection.numberOfSections < ArchiveCollection.curated.count + 1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(collection.numberOfSections, ArchiveCollection.curated.count + 1)
        for section in 0..<collection.numberOfSections {
            collection.scrollToItem(at: IndexPath(item: 0, section: section), at: .top, animated: false)
            try await mounted.waitForItems(section: section)
            let first = IndexPath(item: 0, section: section)
            let before = try XCTUnwrap(collection.layoutAttributesForItem(at: first)).frame
            let followingHeading = section + 1 < collection.numberOfSections ? collection.layoutAttributesForSupplementaryElement(
                ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section + 1))?.frame : nil
            XCTAssertGreaterThan(before.height, 280, "Long titles on unseen pages must be measured before scrolling")
            for item in 1..<6 {
                let attributes = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: item, section: section)))
                XCTAssertEqual(attributes.frame.height, before.height, accuracy: 0.5,
                               "Unseen pages must use the shelf's final height")
            }
            let firstCell = try XCTUnwrap(collection.cellForItem(at: first))
            let scroller = try XCTUnwrap(ancestors(of: firstCell).compactMap { $0 as? UIScrollView }.first { $0 !== collection })
            for fraction in [0.15, 0.5, 1.0, 1.5, 2.0, 0.0] {
                scroller.setContentOffset(CGPoint(x: fraction * collection.bounds.width, y: 0), animated: false)
                collection.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertEqual(try XCTUnwrap(collection.layoutAttributesForItem(at: first)).frame.height, before.height, accuracy: 0.5)
                if let followingHeading {
                    XCTAssertEqual(try XCTUnwrap(collection.layoutAttributesForSupplementaryElement(
                        ofKind: UICollectionView.elementKindSectionHeader, at: IndexPath(item: 0, section: section + 1))).frame.minY,
                        followingHeading.minY, accuracy: 0.5, "A horizontal swipe must not move the following shelf")
                }
                let visible = collection.visibleCells.filter {
                    collection.indexPath(for: $0)?.section == section && scroller.convert($0.bounds, from: $0).intersects(scroller.bounds)
                }
                XCTAssertFalse(visible.isEmpty)
                for cell in visible {
                    XCTAssertEqual(cell.alpha, 1, "Partial tiles must stay visible throughout the swipe")
                }
            }
        }
    }

    func testShelfRemeasuresForWidthAndTextSizeAndAccessibilityRemainsVertical() async throws {
        let mounted = try await MountedExplore()
        defer { mounted.close() }
        let controller = mounted.controller
        let collection = controller.collectionView!
        try await mounted.waitForItems(section: 0)
        let index = IndexPath(item: 0, section: 0)
        let original = try XCTUnwrap(collection.layoutAttributesForItem(at: index)).frame
        controller.traitOverrides.preferredContentSizeCategory = .extraExtraExtraLarge
        try await Task.sleep(for: .milliseconds(80))
        collection.layoutIfNeeded()
        let larger = try XCTUnwrap(collection.layoutAttributesForItem(at: index)).frame
        let probe = ExploreArtifactCell(frame: .zero)
        probe.configure(artifact: ArtifactSummary(identifier: "test", title: String(repeating: "Long title ", count: 20), creators: ["Long author name and a second contributor"]), open: {})
        XCTAssertGreaterThan(probe.fittingHeight(width: 167, traits: UITraitCollection(preferredContentSizeCategory: .extraExtraExtraLarge)),
                             probe.fittingHeight(width: 167, traits: UITraitCollection(preferredContentSizeCategory: .large)))
        XCTAssertGreaterThan(larger.height, original.height)
        mounted.window.frame.size.width = 700
        controller.view.frame = mounted.window.bounds
        collection.collectionViewLayout.invalidateLayout()
        collection.layoutIfNeeded()
        let wider = try XCTUnwrap(collection.layoutAttributesForItem(at: index)).frame
        XCTAssertNotEqual(wider.width, larger.width)
        XCTAssertLessThanOrEqual(wider.height, larger.height)
        controller.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        try await Task.sleep(for: .milliseconds(80))
        collection.layoutIfNeeded()
        let second = try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 1, section: 0))).frame
        let first = try XCTUnwrap(collection.layoutAttributesForItem(at: index)).frame
        XCTAssertEqual(second.minX, first.minX, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(second.minY, first.maxY)
        XCTAssertGreaterThan(try XCTUnwrap(collection.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))).frame.height, original.height)
    }

    func testCoverIntrinsicSizeCannotChangeTileHeight() throws {
        let cell = ExploreArtifactCell(frame: .zero)
        cell.configure(artifact: ArtifactSummary(identifier: "fixture", title: "A title with several words", creators: ["An author"]), open: {})
        func height() -> CGFloat {
            cell.contentView.systemLayoutSizeFitting(CGSize(width: 175, height: 0),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        }
        let initial = height()
        let cover = try XCTUnwrap(descendants(of: cell).compactMap { $0 as? UIImageView }.first { $0.contentMode == .scaleAspectFit && $0.tintColor != .tertiaryLabel })
        for size in [CGSize(width: 800, height: 100), CGSize(width: 100, height: 800)] {
            cover.image = UIGraphicsImageRenderer(size: size).image { _ in UIColor.red.setFill(); UIRectFill(CGRect(origin: .zero, size: size)) }
            XCTAssertEqual(height(), initial, accuracy: 0.5)
        }
    }

    private func ancestors(of view: UIView) -> [UIView] {
        guard let parent = view.superview else { return [] }
        return [parent] + ancestors(of: parent)
    }
    private func descendants(of view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    @MainActor
    private final class MountedExplore {
        let directory: URL
        let window: UIWindow
        let controller: ExploreController
        let previousKeyWindow: UIWindow?

        init(includeContinue: Bool = false) async throws {
            directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let store = try SQLiteStore(url: XCTUnwrap(URL(string: "file::memory:")))
            if includeContinue {
                for index in (0..<6).reversed() {
                    let identifier = "scroll-fixture-continue-\(index)"
                    let response = try JSONSerialization.data(withJSONObject: [
                        "metadata": ["identifier": identifier, "title": index < 2 ? "Short" : String(repeating: "A long recording title ", count: 5), "mediatype": "audio"],
                        "files": [
                            ["name": "a.mp3", "format": "VBR MP3", "length": "1800", "title": index < 2 ? "Short track" : "A long episode name that wraps onto multiple lines"],
                            ["name": "b.mp3", "format": "VBR MP3", "length": "1800"]
                        ]
                    ])
                    try await store.storeCache(key: "metadata:\(identifier)", kind: "metadata", response: response, snapshot: nil, maxAge: 900)
                    try await store.setPlaybackPosition(identifier: identifier, fileName: "a.mp3", seconds: 60)
                }
            }
            for collection in ArchiveCollection.curated {
                let scope: MediaType = collection.identifier == "texts" ? .texts : collection.identifier == "prelinger" ? .movies : .audio
                let request = SearchRequest(scope: scope, pageSize: 6, collection: collection.identifier)
                let items = (0..<6).map { index in
                    ArtifactSummary(identifier: "scroll-fixture-\(collection.identifier)-\(index)",
                        title: index < 2 ? "Short" : String(repeating: "An unusually long title with many words ", count: 5),
                        creators: index < 2 ? [] : ["An author with a long name and a second contributor"], mediaType: scope)
                }
                let page = SearchPage(items: items, total: 6, page: 1, pageSize: 6)
                let response = try JSONSerialization.data(withJSONObject: ["response": ["numFound": 6, "docs": items.map {
                    ["identifier": $0.identifier, "title": $0.title, "creator": $0.creators, "mediatype": scope.rawValue] as [String: Any]
                }]])
                try await store.storeCache(key: CachingArchiveRepository.searchCacheKey(request), kind: "search",
                    response: response, snapshot: JSONEncoder().encode(page), maxAge: 900)
            }
            let environment = AppEnvironment(store: store, mediaDirectory: directory, downloadSession: .ephemeral)
            controller = ExploreController(environment: environment, openCollection: { _ in }, openArtifact: { _ in })
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
            previousKeyWindow = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.layoutIfNeeded()
            for section in ArchiveCollection.curated.indices {
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(controller.collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: section))).frame.height, 190,
                    "Loading cells need their full measured height")
            }
        }

        func waitForItems(section: Int) async throws {
            for _ in 0..<100 {
                controller.collectionView.layoutIfNeeded()
                if controller.collectionView.numberOfItems(inSection: section) == 6 { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Cached shelf did not load")
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
