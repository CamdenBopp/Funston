import XCTest
import PDFKit
import UIKit
import Darwin
@testable import Funston

/// Opt in with IA_PDF_PERFORMANCE=1. An optional IA_PDF_LOCAL_PATH points to an
/// existing file inside the test process's accessible filesystem. Otherwise the
/// live IA PDF is downloaded once into Caches, outside the measurement window.
@MainActor
final class PDFRenderingPerformanceTests: XCTestCase {
    private enum Mode: String, CaseIterable, Sendable { case continuousVertical, pagedHorizontal, continuousCached, continuousLowInterpolation }
    private static let source = URL(string: "https://archive.org/download/B-001-013-719/B-001-013-719.pdf")!

    func testWholeEarthCatalogNativeRenderingComparison() async throws {
        guard ProcessInfo.processInfo.environment["IA_PDF_PERFORMANCE"] == "1" else {
            throw XCTSkip("Set IA_PDF_PERFORMANCE=1 to measure the real Whole Earth Catalog PDF")
        }
        let localURL = try await localDocument()
        let bytes = (try localURL.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            throw XCTSkip("Native drawing requires a foreground window scene")
        }
        let originalKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let originalRoot = originalKeyWindow?.rootViewController
        let originalIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        // A temporary window avoids replacing or dismantling the running app's
        // root. Restore key status even when loading or measurement throws.
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalKeyWindow?.makeKey()
            UIApplication.shared.isIdleTimerDisabled = originalIdleTimerDisabled
            XCTAssertTrue(originalKeyWindow?.rootViewController === originalRoot)
        }

        var modes = Mode.allCases
        if let value = ProcessInfo.processInfo.environment["IA_PDF_PERFORMANCE_MODE"], let only = Mode(rawValue: value) { modes = [only] }
        if ProcessInfo.processInfo.environment["IA_PDF_PERFORMANCE_ORDER"] == "pagedFirst" { modes.reverse() }
        for mode in modes {
            let document = try await Task.detached(priority: .userInitiated) {
                guard let document = PDFDocument(url: localURL), document.pageCount > 25 else {
                    throw NSError(domain: "PDFPerformance", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The local PDF could not be opened or has fewer than 26 pages."])
                }
                return PDFPerformanceDocument(document, cached: mode == .continuousCached)
            }.value
            // PDFDocument.delegate is weak. Keep the holder (and its rendering
            // delegate) alive through the awaited measurement, including errors.
            defer { withExtendedLifetime(document) {} }
            try await measure(mode, document: document.value, window: window, fileBytes: bytes)
        }
    }

    private func localDocument() async throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let supplied = environment["IA_PDF_LOCAL_PATH"] {
            let url = URL(fileURLWithPath: supplied)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("IA_PDF_LOCAL_PATH does not exist in this test process: \(supplied)")
            }
            return url
        }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "PDFRenderingPerformance", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "B-001-013-719.pdf")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(from: Self.source)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "PDFPerformance", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Internet Archive did not return the requested PDF."])
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    private func measure(_ mode: Mode, document: PDFDocument, window: UIWindow, fileBytes: Int) async throws {
        let host = UIViewController()
        host.view.backgroundColor = .systemBackground
        let pdf = IAPDFPerformanceView(frame: .zero)
        pdf.translatesAutoresizingMaskIntoConstraints = false
        pdf.backgroundColor = .secondarySystemBackground
        pdf.autoScales = true
        if mode == .continuousLowInterpolation { pdf.interpolationQuality = .low }
        pdf.displayMode = mode == .pagedHorizontal ? .singlePage : .singlePageContinuous
        pdf.displayDirection = mode == .pagedHorizontal ? .horizontal : .vertical
        if mode == .pagedHorizontal { pdf.usePageViewController(true, withViewOptions: nil) }
        host.view.addSubview(pdf)
        NSLayoutConstraint.activate([
            pdf.leadingAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.leadingAnchor),
            pdf.trailingAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.trailingAnchor),
            pdf.topAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.topAnchor),
            pdf.bottomAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.bottomAnchor)
        ])
        // Map only the requested pages and nearby pages; avoid materializing every
        // PDFPage solely for instrumentation. Unmapped tile callbacks use index -1.
        for index in 0..<min(document.pageCount, 28) {
            if let page = document.page(at: index) { pdf.register(page: page, index: index) }
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { pdf.document = nil; pdf.removeFromSuperview(); window.rootViewController = nil }
        pdf.document = document
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(900))

        let probe = PDFMainQueueProbe()
        probe.start()
        defer { probe.stop() }
        // Arm the heartbeat before the first measured synchronous navigation.
        try await Task.sleep(for: .milliseconds(20))
        let began = ProcessInfo.processInfo.systemUptime
        let resourceStart = PDFProcessSample.read()
        var memory = [resourceStart.residentBytes].compactMap { $0 }
        var navigation: [PDFNavigationSample] = []
        for index in 10...25 {
            try Task.checkCancellation()
            guard window.windowScene?.activationState == .foregroundActive else {
                throw XCTSkip("PDF benchmark lost foreground visibility; unlock the device and rerun")
            }
            guard let page = document.page(at: index) else { continue }
            let started = ProcessInfo.processInfo.systemUptime
            pdf.go(to: page)
            let returned = ProcessInfo.processInfo.systemUptime
            // Deliberately quick navigation, with bounded dwell for native tiled
            // drawing. This is not a wait for complete page/GPU presentation.
            try await Task.sleep(for: .milliseconds(200))
            let afterDwell = ProcessInfo.processInfo.systemUptime
            let visibleIndex = pdf.currentPage.map { document.index(for: $0) }
            navigation.append(PDFNavigationSample(pageIndex: index, started: started,
                callMilliseconds: (returned - started) * 1_000,
                observedAfterMilliseconds: (afterDwell - started) * 1_000,
                currentPageIndexAfterDwell: visibleIndex))
            if let resident = PDFProcessSample.read().residentBytes { memory.append(resident) }
        }
        try await Task.sleep(for: .milliseconds(700))
        let ended = ProcessInfo.processInfo.systemUptime
        probe.stop()
        let resourceEnd = PDFProcessSample.read()
        if let resident = resourceEnd.residentBytes { memory.append(resident) }
        let allDraws = pdf.drawSnapshot()
        let measuredDraws = allDraws.events.filter { $0.started >= began && $0.finished <= ended }
            .map { PDFDrawSample(pageIndex: $0.pageIndex, started: $0.started,
                finished: $0.finished, milliseconds: ($0.finished - $0.started) * 1_000,
                onMainThread: $0.onMainThread) }
        let elapsed = ended - began
        let cpuSeconds = resourceEnd.cpuSeconds - resourceStart.cpuSeconds
        let report = PDFPerformanceReport(
            mode: mode.rawValue, device: UIDevice.current.model, system: UIDevice.current.systemVersion,
            simulator: Self.isSimulator, source: Self.source.absoluteString, fileBytes: fileBytes,
            pageCount: document.pageCount, viewportWidth: Double(pdf.bounds.width), viewportHeight: Double(pdf.bounds.height),
            measurementSeconds: elapsed, cpuSeconds: cpuSeconds, cpuPercentOfOneCore: 100 * cpuSeconds / elapsed,
            residentBytesAtStart: resourceStart.residentBytes, residentBytesAtEnd: resourceEnd.residentBytes,
            peakSampledResidentBytes: memory.max(), drawHookObserved: !allDraws.events.isEmpty,
            totalObservedDrawCallbacks: allDraws.events.count, droppedDrawEvents: Int(allDraws.dropped),
            measuredDrawCallbacks: measuredDraws, navigation: navigation,
            mainQueueWakeDelayMilliseconds: probe.delays,
            notes: [
                "Page indices are zero-based. go(to:) duration measures the synchronous navigation call only.",
                "Draw callbacks are native super.draw page/tile CPU work, not full-page, GPU or screen-present completion.",
                "No manual draw call is made. Zero observed callbacks means this OS renderer did not exercise the public hook; draw timing is unavailable.",
                "Heartbeat is Task.sleep(16ms) resumed on MainActor; excess wake delay includes scheduler contention, not only main-thread stalls.",
                "CPU and RSS cover the whole test-host app, including unrelated work. RSS is sampled, not an instantaneous peak.",
                "Modes use separate PDFDocument instances and run sequentially; OS/filesystem caches are not flushed. Repeat with IA_PDF_PERFORMANCE_ORDER=pagedFirst to reverse order."
            ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "PDF performance \(mode.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
        print("PDF_PERFORMANCE mode=\(mode.rawValue) draws=\(measuredDraws.count) hookObserved=\(report.drawHookObserved) wall=\(elapsed)s cpu=\(cpuSeconds)s rssSampleMax=\(memory.max() ?? 0) maxWakeDelayMs=\(probe.delays.max() ?? 0)")
        if let rendering = document.delegate as? PDFScreenRendering {
            print("PDF_RASTER_CACHE \(rendering.cache.statistics)")
        }
        // Capture after closing the measurement window: screenshot work must not
        // inflate the reported rendering/CPU interval.
        guard window.windowScene?.activationState == .foregroundActive,
              !window.isHidden, host.view.window === window else {
            XCTFail("PDF benchmark lost its visible foreground window before capture")
            return
        }
        host.view.layoutIfNeeded()
        var hierarchyRendered = false
        // Capture the content root, whose bounds are in its own coordinate space,
        // rather than the UIWindow container. This still captures native tiles;
        // no PDFPage draw or substitute raster is used to manufacture proof.
        let screenshot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            hierarchyRendered = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let captureDetails = """
        drawHierarchySucceeded=\(hierarchyRendered)
        applicationState=\(UIApplication.shared.applicationState.rawValue)
        sceneActivationState=\(window.windowScene?.activationState.rawValue ?? -999)
        protectedDataAvailable=\(UIApplication.shared.isProtectedDataAvailable)
        windowHidden=\(window.isHidden) keyWindow=\(window.isKeyWindow) alpha=\(window.alpha)
        windowBounds=\(window.bounds) rootBounds=\(host.view.bounds) pdfBounds=\(pdf.bounds)
        rootAttached=\(host.view.window === window) pdfAttached=\(pdf.window === window)
        currentPage=\(pdf.currentPage.map { document.index(for: $0) } ?? -1)
        This is an in-process hierarchy capture, not proof of unlocked display or completed compositor presentation.
        """
        let captureAttachment = XCTAttachment(string: captureDetails)
        captureAttachment.name = "PDF capture diagnostics \(mode.rawValue)"
        captureAttachment.lifetime = .keepAlways
        add(captureAttachment)
        print("PDF_CAPTURE \(mode.rawValue) \(captureDetails)")
        XCTAssertTrue(hierarchyRendered, "Native hierarchy capture failed; screenshot is not visual evidence")
        let image = XCTAttachment(image: screenshot)
        image.name = "PDF visible result \(mode.rawValue)"
        image.lifetime = .keepAlways
        add(image)
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
}

/// Exclusive off-main creation, followed by a one-way handoff to PDFView.
private final class PDFPerformanceDocument: @unchecked Sendable {
    let value: PDFDocument
    let rendering: PDFScreenRendering?
    init(_ value: PDFDocument, cached: Bool) {
        self.value = value
        rendering = cached ? PDFScreenRendering() : nil
        value.delegate = rendering
    }
}

@MainActor
private final class PDFMainQueueProbe {
    private var task: Task<Void, Never>?
    private(set) var delays: [Double] = []
    func start() {
        task = Task { [weak self] in
            while !Task.isCancelled {
                let before = ProcessInfo.processInfo.systemUptime
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                delays.append(max(0, (ProcessInfo.processInfo.systemUptime - before - 0.016) * 1_000))
            }
        }
    }
    func stop() { task?.cancel(); task = nil }
}

private struct PDFProcessSample {
    let cpuSeconds: Double
    let residentBytes: UInt64?
    static func read() -> Self {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return Self(cpuSeconds: cpu, residentBytes: status == KERN_SUCCESS ? UInt64(info.resident_size) : nil)
    }
}

private struct PDFDrawSample: Codable, Sendable {
    let pageIndex: Int
    let started: Double
    let finished: Double
    let milliseconds: Double
    let onMainThread: Bool
}
private struct PDFNavigationSample: Codable {
    let pageIndex: Int
    let started: Double
    let callMilliseconds: Double
    let observedAfterMilliseconds: Double
    let currentPageIndexAfterDwell: Int?
}
private struct PDFPerformanceReport: Codable {
    let mode: String
    let device: String
    let system: String
    let simulator: Bool
    let source: String
    let fileBytes: Int
    let pageCount: Int
    let viewportWidth: Double
    let viewportHeight: Double
    let measurementSeconds: Double
    let cpuSeconds: Double
    let cpuPercentOfOneCore: Double
    let residentBytesAtStart: UInt64?
    let residentBytesAtEnd: UInt64?
    let peakSampledResidentBytes: UInt64?
    let drawHookObserved: Bool
    let totalObservedDrawCallbacks: Int
    let droppedDrawEvents: Int
    let measuredDrawCallbacks: [PDFDrawSample]
    let navigation: [PDFNavigationSample]
    let mainQueueWakeDelayMilliseconds: [Double]
    let notes: [String]
}
