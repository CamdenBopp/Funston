import Foundation
import XCTest
@testable import Funston

final class BugReportTests: XCTestCase {
    private let report = BugReport(appVersion: "1.0", build: "16", systemVersion: "26.5", model: "iPhone18,1",
                                   voiceOverRunning: true, textSize: "AccessibilityXXXL")

    func testLinkOpensANewIssueOnThePublicRepository() throws {
        let url = try XCTUnwrap(report.url)
        XCTAssertEqual(url.host(), "github.com")
        XCTAssertEqual(url.path(), "/CamdenBopp/Funston/issues/new")
    }

    func testBodyRoundTripsThroughTheQueryWithDiagnostics() throws {
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(report.url), resolvingAgainstBaseURL: false))
        let body = try XCTUnwrap(components.queryItems?.first { $0.name == "body" }?.value)
        XCTAssertEqual(body, report.body)
        XCTAssertTrue(body.contains("Funston 1.0 (16)"))
        XCTAssertTrue(body.contains("iOS 26.5, iPhone18,1"))
        XCTAssertTrue(body.contains("VoiceOver on, text size AccessibilityXXXL"))
        XCTAssertTrue(body.hasPrefix("Issues on GitHub are public."))
    }

    func testBodyCarriesOnlyTheListedDiagnostics() {
        // Everything after the form is the diagnostics block; nothing else
        // about the device or the person may join it without a test change.
        let diagnostics = report.body.components(separatedBy: "1.\n\n").last?.components(separatedBy: "\n")
        XCTAssertEqual(diagnostics, ["Funston 1.0 (16)", "iOS 26.5, iPhone18,1", "VoiceOver on, text size AccessibilityXXXL"])
    }
}
