import AVFoundation
import CarPlay
import XCTest
@testable import Funston

@MainActor
final class CarPlayTests: XCTestCase {
    func testSceneConfigurationUsesCarPlaySceneAndDelegate() {
        let configuration = AppDelegate.carPlayConfiguration()
        XCTAssertEqual(configuration.role, .carTemplateApplication)
        XCTAssertTrue(configuration.sceneClass === CPTemplateApplicationScene.self)
        XCTAssertTrue(configuration.delegateClass === CarPlaySceneDelegate.self)
        let delegate = CarPlaySceneDelegate()
        XCTAssertTrue(delegate.responds(to: NSSelectorFromString("templateApplicationScene:didConnectInterfaceController:")))
        XCTAssertTrue(delegate.responds(to: NSSelectorFromString("templateApplicationScene:didDisconnectInterfaceController:")))
    }

    func testLibraryOnlyOffersPublicSavedAudioAndReflectsRemoval() async throws {
        let environment = try makeEnvironment()
        let controller = CarPlayController(environment: environment)
        let audio = ArtifactSummary(identifier: "radio", title: "Radio", mediaType: .audio)
        try await environment.setSaved(audio, saved: true)
        try await environment.setSaved(ArtifactSummary(identifier: "book", title: "Book", mediaType: .texts), saved: true)
        try await environment.setSaved(ArtifactSummary(identifier: "film", title: "Film", mediaType: .movies), saved: true)
        try await environment.setSaved(ArtifactSummary(identifier: "private", title: "Private", mediaType: .audio, accessRestricted: true), saved: true)
        controller.renderLibrary()
        XCTAssertEqual(controller.library.sections.first?.items.compactMap { $0.text }, ["Radio"])
        try await environment.setSaved(audio, saved: false)
        controller.renderLibrary()
        XCTAssertTrue(controller.library.sections.isEmpty)
        XCTAssertEqual(controller.library.emptyViewTitleVariants, ["No saved audio"])
    }

    func testDownloadListExcludesVideoMissingFilesAndIncompleteTransfers() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "carplay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(url: try XCTUnwrap(URL(string: "file::memory:")))
        for (name, state) in [("radio.wav", DownloadState.completed), ("film.mp4", .completed),
                              ("missing.mp3", .completed), ("pending.mp3", .downloading)] {
            let key = DownloadManager.key(identifier: "fixture", fileName: name)
            let path = DownloadManager.localURL(key: key, fileName: name, directory: directory)
            if name != "missing.mp3", state == .completed { try Data(repeating: 0, count: 16).write(to: path) }
            try await store.upsertDownload(DownloadRecord(key: key, identifier: "fixture", fileName: name,
                title: "Fixture", expectedBytes: 16, localPath: path.path, state: state,
                receivedBytes: 16, totalBytes: 16, errorMessage: nil, updatedAt: .now))
        }
        let environment = AppEnvironment(store: store, mediaDirectory: directory, downloadSession: .ephemeral)
        await environment.downloads.waitUntilReady()
        let controller = CarPlayController(environment: environment)
        controller.renderDownloads()
        XCTAssertEqual(controller.downloads.sections.first?.items.compactMap { ($0 as? CPListItem)?.detailText }, ["radio"])
    }

    func testSelectingRecordingUsesSharedPlayerAndRetainsFullQueue() async throws {
        let environment = try makeEnvironment()
        let controller = CarPlayController(environment: environment)
        let artifact = ArtifactSummary(identifier: "carplay-audio", title: "Radio", mediaType: .audio)
        let tracks = [PlayableTrack(id: "first", title: "First", candidates: [ArchiveFile(name: "first.wav")]),
                      PlayableTrack(id: "second", title: "Second", candidates: [ArchiveFile(name: "second.wav")])]
        let items = controller.trackItems(artifact: artifact, tracks: tracks)
        XCTAssertNil(environment.playback.context, "Browsing must not start playback")
        let completion = expectation(description: "Selection completes")
        let second = try XCTUnwrap(items.last)
        let handler = try XCTUnwrap(second.handler)
        handler(second) { completion.fulfill() }
        await fulfillment(of: [completion], timeout: 2)
        XCTAssertEqual(environment.playback.context?.trackIndex, 1)
        XCTAssertEqual(environment.playback.context?.tracks, tracks)
        XCTAssertTrue(environment.playback.wantsToPlay)
        environment.playback.pause()
        controller.disconnect()
        XCTAssertNotNil(environment.playback.context, "Disconnect must preserve the shared player")
    }

    func testDisconnectCancelsPendingSelectionAndStillCompletesHandler() async throws {
        let environment = try makeEnvironment()
        let controller = CarPlayController(environment: environment)
        let artifact = ArtifactSummary(identifier: "cancel", title: "Cancel", mediaType: .audio)
        let item = try XCTUnwrap(controller.trackItems(artifact: artifact, tracks: [
            PlayableTrack(id: "file", title: "File", candidates: [ArchiveFile(name: "file.wav")])
        ]).first)
        let completion = expectation(description: "Cancelled selection completes")
        let handler = try XCTUnwrap(item.handler)
        handler(item) { completion.fulfill() }
        controller.disconnect()
        await fulfillment(of: [completion], timeout: 2)
        XCTAssertNil(environment.playback.context)
    }

    private func makeEnvironment() throws -> AppEnvironment {
        let store = try SQLiteStore(url: try XCTUnwrap(URL(string: "file::memory:")))
        return AppEnvironment(store: store, mediaDirectory: FileManager.default.temporaryDirectory,
                              downloadSession: .ephemeral)
    }
}
