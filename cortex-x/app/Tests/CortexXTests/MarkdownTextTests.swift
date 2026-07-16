// MarkdownBlocks.split tests: the pure block splitter behind MarkdownText.
// Headers (levels + clamping + the no-space non-header), bullet/numbered
// list grouping and indent, code fences (verbatim contents, language tag
// dropped, unclosed fence), paragraph joining, and mixed-document order.

import XCTest
@testable import CortexX

final class MarkdownTextTests: XCTestCase {
    // MARK: - Paragraphs

    func testEmptyAndWhitespaceOnlyYieldNoBlocks() {
        XCTAssertEqual(MarkdownBlocks.split(""), [])
        XCTAssertEqual(MarkdownBlocks.split("   \n\n\t\n"), [])
    }

    func testPlainTextIsOneParagraph() {
        XCTAssertEqual(
            MarkdownBlocks.split("risk tightened on the geo signal."),
            [.paragraph("risk tightened on the geo signal.")]
        )
    }

    func testAdjacentLinesJoinBlankLineSplitsParagraphs() {
        let blocks = MarkdownBlocks.split("line one\nline two\n\nsecond para")
        XCTAssertEqual(blocks, [
            .paragraph("line one\nline two"),
            .paragraph("second para"),
        ])
    }

    // MARK: - Headers

    func testHeaderLevels() {
        XCTAssertEqual(
            MarkdownBlocks.split("# Market read\n## Drivers\n### Detail"),
            [
                .heading(level: 1, text: "Market read"),
                .heading(level: 2, text: "Drivers"),
                .heading(level: 3, text: "Detail"),
            ]
        )
    }

    func testDeepHeaderClampsToLevelThree() {
        XCTAssertEqual(
            MarkdownBlocks.split("#### deep\n###### deeper"),
            [.heading(level: 3, text: "deep"), .heading(level: 3, text: "deeper")]
        )
    }

    func testHashWithoutSpaceIsParagraphNotHeader() {
        XCTAssertEqual(MarkdownBlocks.split("#hashtag"), [.paragraph("#hashtag")])
        XCTAssertEqual(MarkdownBlocks.split("###"), [.paragraph("###")])
    }

    func testHeaderFlushesRunningParagraph() {
        XCTAssertEqual(
            MarkdownBlocks.split("intro text\n# Section"),
            [.paragraph("intro text"), .heading(level: 1, text: "Section")]
        )
    }

    // MARK: - Lists

    func testBulletMarkersNormalizeToDot() {
        let blocks = MarkdownBlocks.split("- alpha\n* beta\n+ gamma")
        XCTAssertEqual(blocks, [.list(items: [
            MarkdownListItem(marker: "•", indent: 0, text: "alpha"),
            MarkdownListItem(marker: "•", indent: 0, text: "beta"),
            MarkdownListItem(marker: "•", indent: 0, text: "gamma"),
        ])])
    }

    func testNumberedListKeepsNumbers() {
        let blocks = MarkdownBlocks.split("1. first\n2) second\n10. tenth")
        XCTAssertEqual(blocks, [.list(items: [
            MarkdownListItem(marker: "1.", indent: 0, text: "first"),
            MarkdownListItem(marker: "2.", indent: 0, text: "second"),
            MarkdownListItem(marker: "10.", indent: 0, text: "tenth"),
        ])])
    }

    func testIndentedItemsCarryDepth() {
        let blocks = MarkdownBlocks.split("- top\n  - nested\n    - deeper")
        XCTAssertEqual(blocks, [.list(items: [
            MarkdownListItem(marker: "•", indent: 0, text: "top"),
            MarkdownListItem(marker: "•", indent: 1, text: "nested"),
            MarkdownListItem(marker: "•", indent: 2, text: "deeper"),
        ])])
    }

    func testBlankLineSplitsLists() {
        let blocks = MarkdownBlocks.split("- one\n\n- two")
        XCTAssertEqual(blocks, [
            .list(items: [MarkdownListItem(marker: "•", indent: 0, text: "one")]),
            .list(items: [MarkdownListItem(marker: "•", indent: 0, text: "two")]),
        ])
    }

    func testEmphasisAtLineStartIsNotABullet() {
        // "*bold*" has no space after the star — inline emphasis, not a list.
        XCTAssertEqual(
            MarkdownBlocks.split("*emphasis* leads this line"),
            [.paragraph("*emphasis* leads this line")]
        )
    }

    func testParagraphLineEndsList() {
        let blocks = MarkdownBlocks.split("- item\nplain trailing line")
        XCTAssertEqual(blocks, [
            .list(items: [MarkdownListItem(marker: "•", indent: 0, text: "item")]),
            .paragraph("plain trailing line"),
        ])
    }

    // MARK: - Code fences

    func testFenceKeepsContentsVerbatimAndDropsLanguageTag() {
        let text = "```swift\nlet x = 1\n\n# not a header\n```"
        XCTAssertEqual(
            MarkdownBlocks.split(text),
            [.code("let x = 1\n\n# not a header")]
        )
    }

    func testUnclosedFenceRunsToEnd() {
        XCTAssertEqual(
            MarkdownBlocks.split("before\n```\ntrailing code"),
            [.paragraph("before"), .code("trailing code")]
        )
    }

    func testEmptyUnclosedFenceIsDropped() {
        XCTAssertEqual(MarkdownBlocks.split("text\n```"), [.paragraph("text")])
    }

    // MARK: - Mixed document

    func testMixedDocumentOrder() {
        let text = """
        ## Read
        Momentum is broadening.

        - NVDA holds the bid
        - crypto lags

        ```
        composite > 80
        ```
        Watch the close.
        """
        XCTAssertEqual(MarkdownBlocks.split(text), [
            .heading(level: 2, text: "Read"),
            .paragraph("Momentum is broadening."),
            .list(items: [
                MarkdownListItem(marker: "•", indent: 0, text: "NVDA holds the bid"),
                MarkdownListItem(marker: "•", indent: 0, text: "crypto lags"),
            ]),
            .code("composite > 80"),
            .paragraph("Watch the close."),
        ])
    }
}
