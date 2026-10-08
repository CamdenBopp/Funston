import XCTest
@testable import Funston

final class MetadataFormatterTests: XCTestCase {
    /// Archive advanced-search/metadata values captured 2026-10-08. Identifiers
    /// make every real example traceable back to archive.org/details/<id>.
    func testRealArchiveExamples() {
        let examples: [(id: String, title: String, creators: [String], displayTitle: String, displayCreators: String)] = [
            ("flatlandromanceo00abbouoft", "Flatland : a romance of many dimensions", ["Abbott, Edwin Abbott, 1838-1926"], "Flatland: a romance of many dimensions", "Edwin Abbott Abbott"),
            ("sensesensibilit200aust", "Sense and sensibility", ["Austen, Jane, 1775-1817"], "Sense and sensibility", "Jane Austen"),
            ("workscharlesdic39dickgoog", "Our mutual friend; Mugby Junction; George Silverman's explanation", ["Dickens, Charles, 1812-1870"], "Our mutual friend; Mugby Junction; George Silverman's explanation", "Charles Dickens"),
            ("bwb_P9-AGB-888", "Huckleberry Finn", ["Twain, Mark, 1835-1910"], "Huckleberry Finn", "Mark Twain"),
            ("prideprejudice0000jane_l6i1", "Pride and Prejudice", ["Austen, Jane, 1775-1817, author"], "Pride and Prejudice", "Austen, Jane, 1775-1817, author"),
            ("worksvolume00langgoog", "The works of Charles Dickens in thirty-four volumes", ["Dickens, Charles, 1812-1870"], "The works of Charles Dickens in thirty-four volumes", "Charles Dickens"),
            ("workscharlesdic25langgoog", "Barnaby Rudge ; a tale of the riots of 'eighty", ["Dickens, Charles, 1812-1870"], "Barnaby Rudge ; a tale of the riots of 'eighty", "Charles Dickens"),
            ("worksofcharlesdi09dick_3", "The works of Charles Dickens", ["Dickens, Charles, 1812-1870"], "The works of Charles Dickens", "Charles Dickens"),
            ("sketchesbyboz00dick_0", "Sketches by Boz", ["Dickens, Charles, 1812-1870"], "Sketches by Boz", "Charles Dickens"),
            ("prideprejudiceno0000aust_q9o8", "Pride and prejudice : a novel", ["Austen, Jane"], "Pride and prejudice: a novel", "Jane Austen"),
            ("works06dickgoog", "Bleak House", ["Dickens, Charles, 1812-1870"], "Bleak House", "Charles Dickens"),
            ("shortstoriestall00mark", "Short stories and tall tales [electronic resource]", ["Twain, Mark, 1835-1910"], "Short stories and tall tales [electronic resource]", "Mark Twain"),
            ("marktwain0000unse", "Life on the Mississippi", ["Twain, Mark, 1835-1910"], "Life on the Mississippi", "Mark Twain"),
            ("tomsawabroad00twairich", "Tom Sawyer abroad, Tom Sawyer, detective, and other stories, etc., etc.;", ["Twain, Mark, 1835-1910", "Letchworth, Sarah", "Letchworth, Pierre"], "Tom Sawyer abroad, Tom Sawyer, detective, and other stories, etc., etc.;", "Mark Twain, Sarah Letchworth & Pierre Letchworth"),
            ("tomsawyeradv00twairich", "The adventures of Tom Sawyer", ["Twain, Mark, 1835-1910", "Brehm, Worth, 1883-1928", "Hart, James David, 1911-"], "The adventures of Tom Sawyer", "Mark Twain, Worth Brehm & James David Hart"),
            ("OTRR_Gunsmoke_Singles", "Gunsmoke - Single Episodes", ["Old Time Radio Researchers Group"], "Gunsmoke - Single Episodes", "Old Time Radio Researchers Group"),
            ("acpstv-GOOD_MORNING_MACARTHUR_2_13_2019", "GOOD MORNING MACARTHUR, 2/13/2019", ["ACPSTV"], "Good Morning MacArthur, 2/13/2019", "ACPSTV"),
            ("thingiverse-239711", "iphone case 5 (239711)", ["Nadeem (drumrboy44)"], "iPhone Case 5 (239711)", "Nadeem (drumrboy44)"),
            ("introducing-i-phone-11-apple", "Introducing iPhone 11 — Apple", ["Apple"], "Introducing iPhone 11 — Apple", "Apple"),
            ("pctvppa-McGee_Electric_Home_Expo_Spot", "McGee Electric Home Expo Spot", ["PCTV"], "McGee Electric Home Expo Spot", "PCTV"),
            ("MacArthur_Foundation_100andChange_Yht_Wh3LMCU", "MacArthur Foundation 100&Change: RTI/Penn Building Blocks for Safer Neighborhoods", [], "MacArthur Foundation 100&Change: RTI/Penn Building Blocks for Safer Neighborhoods", "")
        ]
        XCTAssertGreaterThanOrEqual(examples.count, 20)
        for example in examples {
            XCTAssertEqual(MetadataFormatter.title(example.title), example.displayTitle, example.id)
            XCTAssertEqual(MetadataFormatter.creators(example.creators), example.displayCreators, example.id)
        }
    }

    func testCatalogEdgesAndConservativeNameHandling() {
        XCTAssertEqual(MetadataFormatter.creators(["Smith, Jane, b. 1901", "Jones, John, -1950", "Brown, Mary, fl. 1890"]), "Jane Smith, John Jones & Mary Brown")
        XCTAssertEqual(MetadataFormatter.creator("United States, Department of Agriculture"), "United States, Department of Agriculture")
        XCTAssertEqual(MetadataFormatter.creator("Smith, John, Jr."), "Smith, John, Jr.")
        XCTAssertEqual(MetadataFormatter.title("  THE   HISTORY OF ART : A STUDY / .  "), "The History of Art: A Study")
        XCTAssertEqual(MetadataFormatter.title("a tale of the sea: in the night"), "A Tale of the Sea: In the Night")
        XCTAssertEqual(MetadataFormatter.title("iPhone, McGee and MacArthur"), "iPhone, McGee and MacArthur")
    }

    func testDisplayCleanupPreservesRawSearchValuesAndCodableKeys() throws {
        let rawTitle = "THE   HISTORY : A STUDY /"
        let rawCreator = "Smith, Jane, 1901-1980"
        let item = ArtifactSummary(identifier: "unchanged-id", title: rawTitle, creators: [rawCreator])
        XCTAssertEqual(item.title, "The History: A Study")
        XCTAssertEqual(item.rawTitle, rawTitle)
        XCTAssertEqual(item.rawCreators, [rawCreator])
        let data = try JSONEncoder().encode(item)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, rawTitle)
        XCTAssertEqual(object["creators"] as? [String], [rawCreator])
        XCTAssertEqual(try JSONDecoder().decode(ArtifactSummary.self, from: data), item)
        XCTAssertEqual(item.resolvingArtwork(files: []).rawTitle, rawTitle)
    }
}
