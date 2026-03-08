import XCTest
@testable import SpeakBook

final class PDFTextCleanerTests: XCTestCase {

    func testCleanRemovesPageNumbers() {
        let text = "42\nThis is the actual content of the page."
        let result = PDFTextCleaner.clean(text)
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.contains("42"))
        XCTAssertTrue(result!.contains("actual content"))
    }

    func testCleanRemovesDottedPageNumbers() {
        let text = "12.\nSome real text here on the page."
        let result = PDFTextCleaner.clean(text)
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.hasPrefix("12"))
    }

    func testCleanRemovesDashedNumbers() {
        let text = "12-13\nThe chapter continues with discussion."
        let result = PDFTextCleaner.clean(text)
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.contains("12-13"))
    }

    func testCleanRemovesShortHeaders() {
        let text = "CH 3\niv\nThe actual paragraph text goes here and is long enough."
        let result = PDFTextCleaner.clean(text)
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.contains("CH 3"))
        XCTAssertFalse(result!.contains("iv"))
        XCTAssertTrue(result!.contains("actual paragraph"))
    }

    func testCleanJoinsLinesWithSpaces() {
        let text = "First line of text is here.\nSecond line of text follows."
        let result = PDFTextCleaner.clean(text)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("here. Second"))
    }

    func testCleanReturnsNilForEmptyContent() {
        XCTAssertNil(PDFTextCleaner.clean(""))
        XCTAssertNil(PDFTextCleaner.clean("\n\n\n"))
    }

    func testCleanReturnsNilForOnlyNumbers() {
        XCTAssertNil(PDFTextCleaner.clean("42\n13\n7"))
    }

    func testCleanReturnsNilForOnlyShortLines() {
        XCTAssertNil(PDFTextCleaner.clean("CH 1\niv\np. 3"))
    }

    func testCleanPreservesLongContent() {
        let text = "This is a sufficiently long line that should be preserved in the output."
        let result = PDFTextCleaner.clean(text)
        XCTAssertEqual(result, text)
    }

    func testCleanHandlesMultipleEmptyLines() {
        let text = "\n\n\nSome actual content that is long enough.\n\n\nMore content on another line.\n\n"
        let result = PDFTextCleaner.clean(text)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Some actual"))
        XCTAssertTrue(result!.contains("More content"))
    }

    func testCleanTypicalPDFPage() {
        let text = """
        42

        Chapter 3: The Rise of Empires

        The Roman Empire was one of the largest empires in history, spanning across Europe, North Africa, and parts of the Middle East. At its height, the empire controlled an estimated 70 million people.

        The empire was founded in 27 BC when Augustus became the first emperor. It lasted for several centuries before falling in 476 AD.

        Notes
        1
        2
        """
        let result = PDFTextCleaner.clean(text)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("Roman Empire"))
        XCTAssertTrue(result!.contains("Augustus"))
        XCTAssertFalse(result!.hasPrefix("42"))
    }
}
