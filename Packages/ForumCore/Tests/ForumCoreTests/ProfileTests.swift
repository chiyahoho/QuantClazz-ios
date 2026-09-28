import XCTest
@testable import ForumCore

final class ProfileTests: XCTestCase {
    private func client() -> ForumClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ForumClient(session: URLSession(configuration: configuration))
    }

    func testEssenceFeedUsesVerifiedV2FilterAndExcludesPinnedNonEssenceRow() async throws {
        StubProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(request.url?.path, "/api/threads.v2")
            XCTAssertEqual(query.first { $0.name == "filter[essence]" }?.value, "1")
            XCTAssertEqual(query.first { $0.name == "filter[sticky]" }?.value, "0")
            return (200, #"{"Code":0,"Data":{"pageData":[{"user":{"pid":7,"userName":"精华作者"},"thread":{"pid":1,"title":"精华","isEssence":true}},{"user":{"pid":8,"userName":"置顶作者"},"thread":{"pid":2,"title":"置顶规则","isEssence":false}}],"currentPage":1,"totalPage":2}}"#)
        }
        let page = try await client().threads(page: 1, essenceOnly: true)
        XCTAssertEqual(page.items.map(\.id), ["1"])
        XCTAssertEqual(page.items.first?.authorID, "7")
        XCTAssertTrue(page.hasMore, "Filtering a server-injected row must not end pagination")
    }

    func testUserHistoryUsesOfficialFiltersAndRelationshipAuthorID() async throws {
        StubProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(request.url?.path, "/api/threads")
            XCTAssertEqual(query.first { $0.name == "filter[userId]" }?.value, "85765")
            XCTAssertEqual(query.first { $0.name == "filter[isEssence]" }?.value, "1")
            XCTAssertEqual(query.first { $0.name == "filter[isApproved]" }?.value, "1")
            XCTAssertEqual(query.first { $0.name == "filter[isDeleted]" }?.value, "no")
            XCTAssertEqual(query.first { $0.name == "filter[isDisplay]" }?.value, "yes")
            XCTAssertEqual(query.first { $0.name == "filter[type]" }?.value, "0,1,2,3,4,6")
            XCTAssertEqual(query.first { $0.name == "sort" }?.value, "-createdAt")
            XCTAssertEqual(query.first { $0.name == "page[number]" }?.value, "2")
            return (200, #"{"data":[{"type":"threads","id":"42","attributes":{"title":"历史帖","isEssence":true},"relationships":{"user":{"data":{"type":"users","id":"85765"}},"firstPost":{"data":{"type":"posts","id":"9"}},"category":{"data":{"type":"categories","id":"3"}}}}],"included":[{"type":"users","id":"85765","attributes":{"username":"作者","avatarUrl":"https://example.com/avatar.png"}},{"type":"posts","id":"9","attributes":{"summaryText":"摘要"}},{"type":"categories","id":"3","attributes":{"name":"策略"}}],"meta":{"threadCount":41}}"#)
        }
        let page = try await client().userThreads(userID: "85765", page: 2, essenceOnly: true)
        XCTAssertEqual(page.items.first?.authorID, "85765")
        XCTAssertEqual(page.items.first?.authorName, "作者")
        XCTAssertEqual(page.items.first?.avatarURL?.absoluteString, "https://example.com/avatar.png")
        XCTAssertTrue(page.hasMore)
    }

    func testCommentMapsTappableAuthorFromNestedUserAndRowFallback() async throws {
        StubProtocol.handler = { _ in
            (200, #"{"Code":0,"Data":{"pageData":[{"id":8,"userId":99,"contentHtml":"<p>一</p>","user":{"id":7,"username":"作者","avatar":"https://example.com/a.png"}},{"id":9,"userId":88,"contentHtml":"<p>二</p>","user":{"username":"备用"}}],"currentPage":1,"totalPage":1}}"#)
        }
        let comments = try await client().comments(threadID: "42", page: 1).items
        XCTAssertEqual(comments[0].authorID, "7")
        XCTAssertEqual(comments[0].avatarURL?.absoluteString, "https://example.com/a.png")
        XCTAssertEqual(comments[1].authorID, "88")
    }
}
