import XCTest
@testable import SpeakBook

final class TTSServiceTests: XCTestCase {

    private var service: TTSService!

    override func setUp() {
        super.setUp()
        service = TTSService()
    }

    // MARK: - splitIntoChunks

    func testSplitEmptyText() {
        XCTAssertEqual(service.splitIntoChunks(""), [])
        XCTAssertEqual(service.splitIntoChunks("   "), [])
    }

    func testSplitSingleSentence() {
        let chunks = service.splitIntoChunks("This is a single sentence that is long enough to not be merged.")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].hasSuffix("."))
    }

    func testSplitMultipleSentences() {
        let text = "First sentence is here. Second sentence follows. Third sentence ends it."
        let chunks = service.splitIntoChunks(text)
        // All three may be merged if under 40 chars each, but the result should contain all text
        let joined = chunks.joined(separator: " ")
        XCTAssertTrue(joined.contains("First"))
        XCTAssertTrue(joined.contains("Third"))
    }

    func testSplitOnCommasAndSemicolons() {
        let text = "This clause has a comma, and this one has a semicolon; then we finish with a period."
        let chunks = service.splitIntoChunks(text)
        // Should split on , ; and . but merge short chunks
        XCTAssertFalse(chunks.isEmpty)
        let joined = chunks.joined(separator: " ")
        XCTAssertTrue(joined.contains("comma"))
        XCTAssertTrue(joined.contains("semicolon"))
    }

    func testShortChunksMerged() {
        let text = "Hi. Ok. Yes. No. Fine."
        let chunks = service.splitIntoChunks(text)
        // All very short — should be merged into fewer chunks
        XCTAssertTrue(chunks.count <= 2, "Expected short chunks to be merged, got \(chunks.count)")
    }

    func testTextWithoutPunctuation() {
        let text = "This text has no punctuation and just goes on without any breaks"
        let chunks = service.splitIntoChunks(text)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0], text)
    }

    func testSplitPreservesAllText() {
        let text = "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs! How vexingly quick daft zebras jump?"
        let chunks = service.splitIntoChunks(text)
        let reconstructed = chunks.joined(separator: " ")
        // All words should be present
        for word in ["quick", "brown", "fox", "liquor", "zebras"] {
            XCTAssertTrue(reconstructed.contains(word), "Missing word: \(word)")
        }
    }

    // MARK: - pauseDuration

    func testPauseDurationPeriod() {
        XCTAssertEqual(service.pauseDuration(after: "End of sentence."), 0.45)
    }

    func testPauseDurationExclamation() {
        XCTAssertEqual(service.pauseDuration(after: "Wow!"), 0.40)
    }

    func testPauseDurationQuestion() {
        XCTAssertEqual(service.pauseDuration(after: "Really?"), 0.50)
    }

    func testPauseDurationComma() {
        XCTAssertEqual(service.pauseDuration(after: "Hello,"), 0.15)
    }

    func testPauseDurationSemicolon() {
        XCTAssertEqual(service.pauseDuration(after: "clause;"), 0.25)
    }

    func testPauseDurationColon() {
        XCTAssertEqual(service.pauseDuration(after: "note:"), 0.30)
    }

    func testPauseDurationNoPunctuation() {
        XCTAssertEqual(service.pauseDuration(after: "no punctuation"), 0.10)
    }

    func testPauseDurationEmptyString() {
        XCTAssertEqual(service.pauseDuration(after: ""), 0)
    }
}
