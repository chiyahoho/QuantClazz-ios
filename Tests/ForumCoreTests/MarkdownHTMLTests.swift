import XCTest
@testable import ForumCore

final class MarkdownHTMLTests: XCTestCase {
    func testRemovesHiddenRawHTMLBlockWithoutRemovingAdjacentContent() {
        let markdown = """
        正文

        <p style='display: none;'><OGtbNl>watermark</OGtbNl></p>

        后文
        """

        let html = MarkdownHTML.render(markdown)

        XCTAssertTrue(html.contains("正文"))
        XCTAssertTrue(html.contains("后文"))
        XCTAssertFalse(html.contains("watermark"))
        XCTAssertFalse(html.contains("display"))
    }

    func testHiddenFooterBlocksDoNotLeaveBlankPreformattedBoxes() {
        let markdown = """
        正文

        <p style='display: none;'><OGtbNl>first</OGtbNl></p>

        <p style='display: none !important;'><shOiDY>second</shOiDY></p>
        """

        let html = MarkdownHTML.render(markdown)

        XCTAssertEqual(html, "<p>正文</p>")
        XCTAssertFalse(html.contains("<pre>"))
    }

    func testHiddenStyleAcceptsCaseWhitespaceQuotesAndImportant() {
        let variants = [
            #"<DIV STYLE = " color: red; DISPLAY : none ! important ; "><x>secret</x></DIV>"#,
            #"<span style=display:none>secret</span> visible"#,
            #"<p style = 'display: none!important'>secret</p>"#
        ]

        for markdown in variants {
            let html = MarkdownHTML.render(markdown)
            XCTAssertFalse(html.contains("secret"), markdown)
        }
        XCTAssertTrue(MarkdownHTML.render(variants[1]).contains("visible"))
    }

    func testHiddenElementCanCloseInALaterParagraph() {
        let markdown = """
        <span style="display:none">

        secret

        </span> visible after close
        """

        let html = MarkdownHTML.render(markdown)

        XCTAssertFalse(html.contains("secret"))
        XCTAssertTrue(html.contains("visible after close"))
    }

    func testSelfClosingHiddenElementDoesNotSuppressFollowingContent() {
        let html = MarkdownHTML.render(#"<img STYLE="DISPLAY: NONE"> visible text"#)

        XCTAssertFalse(html.contains("&lt;img"))
        XCTAssertTrue(html.contains("visible text"))
    }

    func testPreservesLiteralHTMLInCodeExamples() {
        let markdown = """
        `<p style='display:none'>inline example</p>`

        ~~~html
        <p style="display: none !important">fenced example</p>
        ~~~
        """

        let html = MarkdownHTML.render(markdown)

        XCTAssertTrue(html.contains("inline example"))
        XCTAssertTrue(html.contains("fenced example"))
        XCTAssertTrue(html.contains("&lt;p style="))
    }

    func testKeepsVisibleRawHTMLEscapedAndNeverActivatesIt() {
        let html = MarkdownHTML.render("before <span class='note'>shown</span> after\n\n<script>alert(1)</script>")

        XCTAssertTrue(html.contains("before"))
        XCTAssertTrue(html.contains("shown"))
        XCTAssertTrue(html.contains("&lt;span class='note'&gt;"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertFalse(html.contains("<script>"))
    }
}
