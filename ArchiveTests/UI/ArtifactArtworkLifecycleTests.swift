import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Archive

@MainActor
final class ArtifactArtworkLifecycleTests: XCTestCase {
    func testMountedImmediateCacheHitRemainsVisibleWithoutRestartingLoad() async throws {
        let loader = Loader()
        loader.immediate = coloredImage(.red)
        let started = expectation(description: "Initial cache hit")
        loader.onRequest = { _ in started.fulfill() }
        let mounted = try MountedArtwork(loader: loader)
        defer { mounted.close(); loader.cancelPending() }
        await fulfillment(of: [started], timeout: 3)
        try await assertStableCover(mounted, red: true)
        XCTAssertEqual(loader.requests.count, 1, "Displaying the result must not restart its task")
    }

    func testMountedAsynchronousSuccessRemainsVisibleWithoutRestartingLoad() async throws {
        let loader = Loader()
        let started = expectation(description: "Initial asynchronous load")
        loader.onRequest = { _ in started.fulfill() }
        let mounted = try MountedArtwork(loader: loader)
        defer { mounted.close(); loader.cancelPending() }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertFalse(try mounted.hasCover(red: true))
        loader.complete(identifier: "first", image: coloredImage(.red))
        try await assertStableCover(mounted, red: true)
        XCTAssertEqual(loader.requests.count, 1)
    }

    func testChangedIdentityClearsCoverAndIgnoresCancelledLateResult() async throws {
        let loader = Loader()
        let first = expectation(description: "First load")
        loader.onRequest = { _ in first.fulfill() }
        let mounted = try MountedArtwork(loader: loader)
        defer { mounted.close(); loader.cancelPending() }
        await fulfillment(of: [first], timeout: 3)
        loader.complete(identifier: "first", image: coloredImage(.red))
        try await assertStableCover(mounted, red: true)

        let second = expectation(description: "Second load")
        loader.onRequest = { _ in second.fulfill() }
        mounted.state.identifier = "second"
        await fulfillment(of: [second], timeout: 3)
        try await settle()
        XCTAssertFalse(try mounted.hasCover(red: true), "The previous artifact must disappear while its replacement loads")

        let third = expectation(description: "Third load")
        loader.onRequest = { _ in third.fulfill() }
        mounted.state.identifier = "third"
        await fulfillment(of: [third], timeout: 3)
        loader.complete(identifier: "third", image: coloredImage(.blue))
        try await assertStableCover(mounted, red: false)
        // Deliberately ignore cancellation inside the injected loader: the view
        // must still reject this older completion rather than show stale art.
        loader.complete(identifier: "second", image: coloredImage(.red))
        try await assertStableCover(mounted, red: false)
        XCTAssertEqual(loader.requests.map(\.lastPathComponent), ["first", "second", "third"])
    }

    func testSameIdentityResizeKeepsCoverDuringReloadAndFailure() async throws {
        let loader = Loader()
        let first = expectation(description: "First size")
        loader.onRequest = { _ in first.fulfill() }
        let mounted = try MountedArtwork(loader: loader)
        defer { mounted.close(); loader.cancelPending() }
        await fulfillment(of: [first], timeout: 3)
        loader.complete(identifier: "first", image: coloredImage(.red))
        try await assertStableCover(mounted, red: true)

        let resized = expectation(description: "Second size")
        loader.onRequest = { _ in resized.fulfill() }
        mounted.state.size = 160
        await fulfillment(of: [resized], timeout: 3)
        try await assertStableCover(mounted, red: true)
        loader.cancelPending()
        try await assertStableCover(mounted, red: true)
        XCTAssertEqual(loader.requests.count, 2)
    }

    private func coloredImage(_ color: UIColor) -> SendableImage {
        SendableImage(UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        })
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    private func assertStableCover(_ mounted: MountedArtwork, red: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        // Fixed render turns, not a benchmark or production polling loop. Check
        // multiple frames so a success-then-placeholder cycle cannot pass once.
        for _ in 0..<4 {
            try await settle()
            XCTAssertTrue(try mounted.hasCover(red: red), "Successful cover must remain rendered", file: file, line: line)
        }
    }

    @MainActor
    private final class Loader {
        var immediate: SendableImage?
        var requests: [URL] = []
        var onRequest: ((URL) -> Void)?
        private var pending: [(URL, CheckedContinuation<SendableImage, any Error>)] = []

        func load(_ url: URL, _ size: CGSize, _ scale: CGFloat) async throws -> SendableImage {
            requests.append(url)
            if let immediate {
                onRequest?(url)
                return immediate
            }
            return try await withCheckedThrowingContinuation { continuation in
                pending.append((url, continuation))
                onRequest?(url)
            }
        }

        func complete(identifier: String, image: SendableImage) {
            let matches = pending.filter { $0.0.lastPathComponent == identifier }
            pending.removeAll { $0.0.lastPathComponent == identifier }
            for (_, continuation) in matches { continuation.resume(returning: image) }
        }

        func cancelPending() {
            let waiting = pending
            pending.removeAll()
            for (_, continuation) in waiting { continuation.resume(throwing: CancellationError()) }
        }
    }

    @MainActor
    private final class State: ObservableObject {
        @Published var identifier = "first"
        @Published var size: CGFloat = 180
    }

    private struct Harness: View {
        @ObservedObject var state: State
        let loader: Loader
        var body: some View {
            ArtifactArtwork(identifier: state.identifier, size: state.size, imageLoader: loader.load)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
                .ignoresSafeArea()
        }
    }

    @MainActor
    private final class MountedArtwork {
        let state = State()
        let window: UIWindow
        let host: UIHostingController<Harness>
        let previousKeyWindow: UIWindow?

        init(loader: Loader) throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive }), "Mounted regression requires the app's foreground scene")
            previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
            host = UIHostingController(rootView: Harness(state: state, loader: loader))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        func hasCover(red: Bool) throws -> Bool {
            let view = try XCTUnwrap(host.view)
            view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let snapshot = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
                view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
            }
            let cgImage = try XCTUnwrap(snapshot.cgImage)
            let center = try XCTUnwrap(cgImage.cropping(to: CGRect(x: cgImage.width / 2, y: cgImage.height / 2, width: 1, height: 1)))
            var pixel = [UInt8](repeating: 0, count: 4)
            let rendered = pixel.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return true
            }
            XCTAssertTrue(rendered)
            return red ? pixel[0] > 200 && pixel[1] < 50 && pixel[2] < 50
                : pixel[2] > 200 && pixel[0] < 50 && pixel[1] < 50
        }
    }
}
