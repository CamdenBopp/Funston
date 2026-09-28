import UIKit
import XCTest
@testable import Funston

final class ArtifactContentsSearchTests: XCTestCase {
    func testSearchMatchesAllTermsWithoutChangingOriginalPositions() {
        let index = ArtifactContentsSearchIndex(keys: ["1 Billy the Kid", "2 Café Concert", "3 The Kid Returns"])
        XCTAssertEqual(index.matchingIndices("  KID billy  "), [0])
        XCTAssertEqual(index.matchingIndices("CAFE"), [1])
        XCTAssertEqual(index.matchingIndices("kid"), [0, 2])
        XCTAssertEqual(index.matchingIndices("missing"), [])
        XCTAssertEqual(index.matchingIndices(" \n "), [0, 1, 2])
    }

    @MainActor
    func testFilteringPreservesRowIdentityAndClearingSearchRestoresContent() throws {
        let rows = [FunstonRow(id: "10", title: "Introduction"), FunstonRow(id: "23", title: "Café Concert"), FunstonRow(id: "57", title: "Finale")]
        let controller = SearchableArtifactContentsController(title: "Recordings", rows: rows,
                                                              searchKeys: rows.map(\.title), placeholder: "Find a recording", emptyTitle: "No matching recordings")
        controller.loadViewIfNeeded()
        let search = try XCTUnwrap(controller.navigationItem.searchController)
        search.searchBar.text = "cafe"
        controller.updateSearchResults(for: search)
        XCTAssertEqual(controller.rows.map(\.id), ["23"], "Opening or playing filtered rows must use original identifiers.")
        search.searchBar.text = "no such recording"
        controller.updateSearchResults(for: search)
        XCTAssertTrue(controller.rows.isEmpty)
        XCTAssertNotNil(controller.contentUnavailableConfiguration)
        search.searchBar.text = ""
        controller.updateSearchResults(for: search)
        XCTAssertEqual(controller.rows.map(\.id), ["10", "23", "57"])
        XCTAssertNil(controller.contentUnavailableConfiguration)
        XCTAssertEqual(controller.collectionView.keyboardDismissMode, .interactive)
    }
}
