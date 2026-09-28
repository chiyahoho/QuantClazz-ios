import XCTest
@testable import ForumCore

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class ForumClientTests: XCTestCase {
    func client(token: String? = nil) -> ForumClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return ForumClient(token: token, session: URLSession(configuration: config))
    }
    func testFeedRealShapeAndPagination() async throws {
        StubProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "filter[categoryids][]" }?.value, "48")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return (200, #"{"Code":0,"Data":{"pageData":[{"user":{"userName":"示例作者","avatar":"https://example.com/avatar.png"},"thread":{"pid":42,"title":"测试","summary":"<p>葫芦评定规则</p>\n\n... &amp; &#x4E2D;","category":{"id":1,"name":"策略"},"postCount":8,"replyCount":0,"viewCount":12,"createdAt":"2026-09-26"}}],"currentPage":1,"totalPage":3}}"#)
        }
        let page = try await client(token: "test-token").threads(page: 1, categoryID: "48")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.items.first?.replyCount, 8)
        XCTAssertEqual(page.items.first?.id, "42")
        XCTAssertEqual(page.items.first?.summary, "葫芦评定规则 ... & 中")
    }
    func testCategoriesFlattenAndComments() async throws {
        StubProtocol.handler = { request in
            if request.url!.path.contains("categories") { return (200, #"{"Code":0,"Data":[{"pid":48,"name":"小组","children":[{"pid":185,"name":"子组"}]}]}"#) }
            XCTAssertTrue(request.url!.absoluteString.contains("posts.v2"))
            return (200, #"{"Code":0,"Data":{"pageData":[{"id":8,"contentHtml":"<p>回复</p>","createdAt":"today","user":{"username":"示例"}}],"currentPage":2,"totalPage":2}}"#)
        }
        let categories = try await client().categories()
        XCTAssertEqual(categories.map(\.id), ["48", "185"])
        let page = try await client().comments(threadID: "42", page: 2)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.items[0].html, "<p>回复</p>")
    }
    func testDetailsFailClosedWithoutServerPermission() async throws {
        for permission in ["false", "true"] {
            StubProtocol.handler = { _ in (200, "{\"Code\":0,\"Data\":{\"isFavorite\":true,\"canFavorite\":false,\"thread\":{\"pid\":42,\"canViewPosts\":\(permission)},\"firstPost\":{\"contentHtml\":\"<p>private</p>\"}}}") }
            let detail = try await client().thread(id: "42")
            XCTAssertEqual(detail.canView, permission == "true")
            XCTAssertEqual(detail.html, permission == "true" ? "<p>private</p>" : "")
            XCTAssertTrue(detail.isFavorite)
            XCTAssertFalse(detail.canFavorite)
        }
    }
    func testReplyAvailabilityMatchesOfficialComposerLoginAndViewGates() async throws {
        for canView in [true, false] {
            for legacySideActionFlag: Bool? in [true, false, nil] {
            StubProtocol.handler = { _ in
                var thread: [String: Any] = ["id": 42, "canViewPosts": canView]
                if let legacySideActionFlag { thread["canComment"] = legacySideActionFlag }
                let body: [String: Any] = ["Code": 0, "Data": ["thread": thread, "firstPost": [:]]]
                return (200, String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)!)
            }
                let anonymous = try await client().thread(id: "42")
                XCTAssertFalse(anonymous.canReply)
                let authenticated = try await client(token: "test").thread(id: "42")
                XCTAssertEqual(authenticated.canReply, canView)
            }
        }
    }
    func testCreatePlainTextCommentRequestAndPendingResult() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/posts")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/vnd.api+json")
            var bytes = request.httpBody
            if bytes == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var result = Data(), buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(buffer, count: count) }
                bytes = result
            }
            let root = try JSONSerialization.jsonObject(with: bytes!) as! [String: Any]
            let data = root["data"] as! [String: Any]
            XCTAssertEqual(data["type"] as? String, "posts")
            XCTAssertEqual((data["attributes"] as? [String: Any])?["content"] as? String, "纯文本 **不转换**")
            let relationships = data["relationships"] as! [String: Any]
            let thread = ((relationships["thread"] as! [String: Any])["data"] as! [String: Any])
            XCTAssertEqual(thread["type"] as? String, "threads")
            XCTAssertEqual(thread["id"] as? String, "42")
            return (201, #"{"data":{"type":"posts","id":"91","attributes":{"contentHtml":"<p>纯文本</p>","createdAt":"today","isApproved":0,"user":{"username":"我"}}}}"#)
        }
        let result = try await client(token: "test-token").createComment(threadID: "42", text: "纯文本 **不转换**")
        XCTAssertEqual(result.comment?.id, "91")
        XCTAssertEqual(result.comment?.authorName, "我")
        XCTAssertEqual(result.comment?.html, "<p>纯文本</p>")
        XCTAssertTrue(result.isPendingModeration)
    }
    func testCreateCommentTreatsUnknownSuccessfulResponseAsAccepted() async throws {
        StubProtocol.handler = { _ in (204, "") }
        let result = try await client(token: "test").createComment(threadID: "42", text: "内容")
        XCTAssertNil(result.comment)
        XCTAssertEqual(result.status, .accepted)
    }
    func testCreateCommentUsesIncludedUserAndSafeTextFallback() async throws {
        StubProtocol.handler = { _ in (201, #"{"data":{"type":"posts","id":"92","attributes":{"isApproved":1},"relationships":{"user":{"data":{"type":"users","id":"7"}}}},"included":[{"type":"users","id":"7","attributes":{"username":"作者"}}]}"#) }
        let result = try await client(token: "test").createComment(threadID: "42", text: "<b>纯文本</b>\n下一行")
        XCTAssertEqual(result.status, .published)
        XCTAssertEqual(result.comment?.authorName, "作者")
        XCTAssertEqual(result.comment?.html, "<p>&lt;b&gt;纯文本&lt;/b&gt;<br>下一行</p>")
    }
    func testCreateCommentValidationAuthenticationAndServerError() async throws {
        StubProtocol.handler = { _ in XCTFail("Invalid local input must not send a request"); return (200, "{}") }
        do { _ = try await client(token: "test").createComment(threadID: "42", text: " \n "); XCTFail() }
        catch { XCTAssertEqual(error as? ForumError, .message("评论内容不能为空。")) }
        do { _ = try await client().createComment(threadID: "42", text: "内容"); XCTFail() }
        catch { XCTAssertEqual(error as? ForumError, .unauthorized) }

        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (422, #"{"errors":[{"code":"validation_error","detail":"该主题不允许评论"}]}"#)
        }
        do { _ = try await client(token: "test").createComment(threadID: "42", text: "内容"); XCTFail() }
        catch { XCTAssertEqual(error as? ForumError, .message("该主题不允许评论")) }
    }
    func testJSONAPIRelationshipsAndFavoriteTotal() async throws {
        StubProtocol.handler = { _ in (200, #"{"data":[{"type":"threads","id":"42","attributes":{"title":"收藏","postCount":2},"relationships":{"user":{"data":{"type":"users","id":"3"}},"firstPost":{"data":{"type":"posts","id":"9"}},"category":{"data":{"type":"categories","id":"1"}}}}],"included":[{"type":"users","id":"3","attributes":{"username":"作者","avatarUrl":"https://example.com/a.png"}},{"type":"posts","id":"9","attributes":{"summary":"<h1>正文摘要</h1> &lt;示例&gt;"}},{"type":"categories","id":"1","attributes":{"name":"分类"}}],"meta":{"threadCount":21}}"#) }
        let page = try await client(token: "test").favorites(folderID: "2", page: 1)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.items[0].authorName, "作者")
        XCTAssertEqual(page.items[0].summary, "正文摘要 <示例>")
        XCTAssertEqual(page.items[0].categoryName, "分类")
    }
    func testFoldersAndMutationFormat() async throws {
        StubProtocol.handler = { request in
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-http-method-override"), "patch")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/vnd.api+json")
                // URLSession may expose the body as a stream to URLProtocol.
                var bytes = request.httpBody
                if bytes == nil, let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var result = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(buffer, count: count) }
                    bytes = result
                }
                let root = try JSONSerialization.jsonObject(with: bytes!) as! [String: Any]
                let data = root["data"] as! [String: Any], attrs = data["attributes"] as! [String: Any]
                XCTAssertEqual(data["id"] as? String, "42")
                XCTAssertEqual(attrs["isFavorite"] as? Bool, false)
                XCTAssertNil(attrs["favorite_id"])
                return (204, "")
            }
            return (200, #"{"code":200,"msg":"success","data":{"favorites":[{"id":2,"name":"默认","count":7}],"total":1}}"#)
        }
        let folders = try await client(token: "test").favoriteFolders()
        XCTAssertEqual(folders[0].count, 7)
        try await client(token: "test").setFavorite(threadID: "42", folderIDs: ["2"], isFavorite: false)
    }
    func testAddFavoriteFoldersAndSessionIsolation() async throws {
        XCTAssertNil(ForumClient.isolatedSession.configuration.urlCache)
        XCTAssertNil(ForumClient.isolatedSession.configuration.httpCookieStorage)
        XCTAssertFalse(ForumClient.isolatedSession.configuration.httpShouldSetCookies)
        StubProtocol.handler = { request in
            if request.httpMethod == "GET" {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "page[limit]" }?.value, "0")
                return (200, #"{"code":200,"data":{"favorites":[],"total":0}}"#)
            }
            var bytes = request.httpBody
            if bytes == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var result = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(buffer, count: count) }
                bytes = result
            }
            let root = try JSONSerialization.jsonObject(with: bytes!) as! [String: Any]
            let data = root["data"] as! [String: Any], attrs = data["attributes"] as! [String: Any]
            XCTAssertEqual(attrs["isFavorite"] as? Bool, true)
            XCTAssertEqual(attrs["favorite_id"] as? [String], ["2", "3"])
            return (200, #"{"data":{"id":"42","type":"threads","attributes":{"isFavorite":true}}}"#)
        }
        _ = try await client(token: "test").favoriteFolders()
        try await client(token: "test").setFavorite(threadID: "42", folderIDs: ["2", "3"], isFavorite: true)
    }
    func testMissingPermissionAndMarkdownFallback() async throws {
        StubProtocol.handler = { _ in (200, #"{"Code":0,"Data":{"thread":{"pid":42},"firstPost":{"contentHtml":"<p>hidden</p>"}}}"#) }
        let hidden = try await client().thread(id: "42")
        XCTAssertFalse(hidden.canView)
        XCTAssertEqual(hidden.html, "")
        StubProtocol.handler = { _ in (200, ##"{"Code":0,"Data":{"thread":{"pid":42,"canViewPosts":true},"firstPost":{"content":"# title <script>&"}}}"##) }
        let markdown = try await client().thread(id: "42")
        XCTAssertEqual(markdown.html, "<pre># title &lt;script&gt;&amp;</pre>")
    }
    func testRealDetailSchemaAuthorAndCategory() async throws {
        StubProtocol.handler = { _ in (200, #"{"Code":0,"Data":{"author":{"id":1,"username":"示例作者","avatar":"https://example.com/a.png"},"category":{"id":1,"name":"策略分享会"},"thread":{"id":89957,"title":"示例帖子","canViewPosts":true,"postCount":4},"firstPost":{"parseContentHtml":"<p>正文</p>","summaryText":"摘要"},"isFavorite":false,"canFavorite":true}}"#) }
        let detail = try await client().thread(id: "89957")
        XCTAssertEqual(detail.summary.id, "89957")
        XCTAssertEqual(detail.summary.authorName, "示例作者")
        XCTAssertEqual(detail.summary.categoryName, "策略分享会")
        XCTAssertEqual(detail.summary.summary, "摘要")
        XCTAssertEqual(detail.html, "<p>正文</p>")
        XCTAssertTrue(detail.canFavorite)
    }
    func testEmptyContentHTMLFallsBackToParsedHTML() async throws {
        for empty in ["", "   "] {
            StubProtocol.handler = { _ in (200, "{\"Code\":0,\"Data\":{\"thread\":{\"id\":42,\"canViewPosts\":true},\"firstPost\":{\"contentHtml\":\"\(empty)\",\"parseContentHtml\":\"<p>正文</p>\",\"content\":\"fallback\"}}}") }
            let detail = try await client().thread(id: "42")
            XCTAssertEqual(detail.html, "<p>正文</p>")
        }
    }
    func testOfficialMarkdownSourcePriorityAndSafeRendering() async throws {
        StubProtocol.handler = { _ in (200, ##"{"Code":0,"Data":{"thread":{"id":42,"canViewPosts":true},"firstPost":{"contentHtml":"<div></div>","threadContent":"# 正文\n\n段落 **重点** [链接](https://example.com) ![图片](/image.png)\n\n```python\nprint(1 < 2)\n```\n\n|列一|列二|\n|---|---|\n|值一|值二|\n\n~~删除~~\n\n<script>bad()</script>\n\n[危险](javascript:bad) ![危险](data:image/png,abc)"}}}"##) }
        let detail = try await client().thread(id: "42")
        XCTAssertTrue(detail.html.contains("<h1>正文</h1>"))
        XCTAssertTrue(detail.html.contains("<strong>重点</strong>"))
        XCTAssertTrue(detail.html.contains("print(1 &lt; 2)"))
        XCTAssertTrue(detail.html.contains("src=\"https://bbs.quantclass.cn/image.png\""))
        XCTAssertTrue(detail.html.contains("<table>"))
        XCTAssertTrue(detail.html.contains("<del>删除</del>"))
        XCTAssertFalse(detail.html.contains("<script>"))
        XCTAssertFalse(detail.html.contains("href=\"javascript:"))
        XCTAssertFalse(detail.html.contains("src=\"data:"))
    }
    func testMarkdownResourceSchemesAndCommonBlocks() {
        let html = MarkdownHTML.render("1. first\n2. second\n\n> quote\n\n![insecure](http://example.com/a.png) [file](file:///tmp/a) [relative](/thread/42)\n\n`inline <code>`")
        XCTAssertTrue(html.contains("<ol"))
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("https://bbs.quantclass.cn/thread/42"))
        XCTAssertTrue(html.contains("inline &lt;code&gt;"))
        XCTAssertFalse(html.contains("src=\"http:"))
        XCTAssertFalse(html.contains("href=\"file:"))
    }
    func testFeedImagesAndVerifiedFlags() async throws {
        StubProtocol.handler = { _ in (200, #"{"Code":0,"Data":{"pageData":[{"user":{"avatar":"javascript:bad"},"thread":{"pid":42,"isEssence":true,"isOriginal":true},"attachment":[{"thumbUrl":"https://example.com/thumb.png","url":"https://example.com/full.png"},{"url":"file:///private/a"},{"url":"https://example.com/thumb.png"}]}],"currentPage":1,"totalPage":1}}"#) }
        let item = try await client().threads(page: 1).items[0]
        XCTAssertEqual(item.imageURLs.map(\.absoluteString), ["https://example.com/full.png", "https://example.com/thumb.png"])
        XCTAssertEqual(item.thumbnailURL?.absoluteString, "https://example.com/thumb.png")
        XCTAssertNil(item.avatarURL)
        XCTAssertTrue(item.isEssence)
        XCTAssertTrue(item.isOriginal)
    }
    func testMarkdownImagesRespectPermissionAndPreviewEncoding() async throws {
        let markdown = "![图片](https://example.com/a.png?x=1&y=2)"
        let rendered = MarkdownHTML.render(markdown)
        XCTAssertTrue(rendered.contains("qc-image://open?url="))
        let href = rendered.components(separatedBy: "href=\"")[1].components(separatedBy: "\"")[0].replacingOccurrences(of: "&amp;", with: "&")
        let preview = try XCTUnwrap(URLComponents(string: href))
        XCTAssertEqual(preview.queryItems?.first?.value, "https://example.com/a.png?x=1&y=2")
        for permission in [true, false] {
            StubProtocol.handler = { _ in
                let body: [String: Any] = ["Code": 0, "Data": ["thread": ["id": 42, "canViewPosts": permission], "firstPost": ["threadContent": markdown]]]
                return (200, String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)!)
            }
            let detail = try await client().thread(id: "42")
            XCTAssertEqual(detail.summary.imageURLs.count, permission ? 1 : 0)
            if !permission { XCTAssertEqual(detail.html, "") }
        }
    }
    func testFavoriteIncludedImageRelationship() async throws {
        StubProtocol.handler = { _ in (200, #"{"data":[{"id":"42","type":"threads","attributes":{"isEssence":true},"relationships":{"firstPost":{"data":{"id":"9","type":"posts"}}}}],"included":[{"id":"9","type":"posts","attributes":{"summaryText":"摘要"},"relationships":{"images":{"data":[{"id":"7","type":"attachments"}]}}},{"id":"7","type":"attachments","attributes":{"thumbUrl":"https://example.com/thumb.jpg","url":"https://example.com/full.jpg"}}],"meta":{"threadCount":1}}"#) }
        let item = try await client(token: "test").favorites(folderID: "2", page: 1).items[0]
        XCTAssertEqual(item.imageURLs.map(\.absoluteString), ["https://example.com/full.jpg"])
        XCTAssertEqual(item.thumbnailURL?.absoluteString, "https://example.com/thumb.jpg")
        XCTAssertTrue(item.isEssence)
    }
    func testHTTPAndBusinessErrors() async throws {
        let cases: [(Int, String, ForumError)] = [(401, "{}", .unauthorized), (403, "<html>Forbidden</html>", .forbidden), (200, #"{"Code":0,"Message":"list_captcha"}"#, .verificationRequired), (200, #"{"Code":5,"Message":"维护中"}"#, .message("维护中")), (200, #"{"errors":[{"code":"not_authenticated"}]}"#, .unauthorized), (200, #"{"code":500,"msg":"失败"}"#, .message("失败")), (200, #"{"errors":[{"code":"access_denied"}]}"#, .unauthorized), (200, "[]", .invalidResponse)]
        for (status, body, expected) in cases {
            StubProtocol.handler = { _ in (status, body) }
            do { _ = try await client().threads(page: 1); XCTFail("Expected error") } catch { XCTAssertEqual(error as? ForumError, expected) }
        }
        StubProtocol.handler = { _ in XCTFail("Missing token must not send a request"); return (200, "{}") }
        do { _ = try await client().favoriteFolders(); XCTFail() } catch { XCTAssertEqual(error as? ForumError, .unauthorized) }
    }
    func testActivityRecordsPaginationAndRepeatedThreadIdentity() async throws {
        StubProtocol.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "page[number]" }?.value, "1")
            XCTAssertEqual(query.first { $0.name == "page[limit]" }?.value, "20")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            return (200, #"{"data":[{"type":"threads","id":"42","attributes":{"title":"记录","viewAt":"2026-09-28 10:00:00"}},{"type":"threads","id":"42","attributes":{"title":"记录","viewAt":"2026-09-27 09:00:00"}}],"included":[],"meta":{"threadCount":21}}"#)
        }
        let page = try await client(token: "token").viewRecords(page: 1)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.items.map(\.thread.id), ["42", "42"])
        XCTAssertEqual(Set(page.items.map(\.id)).count, 2)
    }
    func testVoteRecordsAndThreadVoteState() async throws {
        StubProtocol.handler = { request in
            if request.url!.path.contains("user/vote/records") {
                return (200, #"{"data":[{"type":"threads","id":"8","attributes":{"title":"投籽记录","voteAt":"2026-09-28 11:00:00","votes":3}}],"included":[],"meta":{"threadCount":1}}"#)
            }
            return (200, #"{"Code":0,"Data":{"thread":{"id":8,"canViewPosts":true,"canVote":true,"voteCount":12},"firstPost":{"content":"正文"},"isVoted":false,"remainingVotes":5}}"#)
        }
        let record = try await client(token: "token").voteRecords(page: 1).items[0]
        XCTAssertEqual(record.votes, 3)
        let detail = try await client(token: "token").thread(id: "8")
        XCTAssertTrue(detail.canVote); XCTAssertFalse(detail.isVoted); XCTAssertEqual(detail.remainingVotes, 5); XCTAssertEqual(detail.voteCount, 12)
    }
    func testNotificationsParsingPermissionAndPagination() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems?.first { $0.name == "filter[type]" }?.value, "rewarded,withdrawal")
            return (200, #"{"data":[{"id":"n1","type":"notification","attributes":{"type":"system","created_at":"2026-09-28","thread_id":"42","thread_title":"审核","content":"<b>审核中</b>","raw":{"tpl_id":4}}},{"id":"n2","type":"notification","attributes":{"type":"voted","user_id":"7","user_name":"同学","created_at":"2026-09-28","thread_id":"43","post_content":"<p>正文</p>"}}],"meta":{"total":11}}"#)
        }
        do { _ = try await client().notifications(types: ["system"], page: 1); XCTFail() } catch { XCTAssertEqual(error as? ForumError, .unauthorized) }
        let page = try await client(token: "token").notifications(types: ["rewarded", "withdrawal"], page: 1)
        XCTAssertTrue(page.hasMore); XCTAssertFalse(page.items[0].canOpenThread); XCTAssertTrue(page.items[1].canOpenThread); XCTAssertEqual(page.items[1].postContent, "正文")
    }
    func testVoteRequestAndUnknownSuccessRequiresFailure() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.url?.path, "/api/thread/vote/records")
            var bytes = request.httpBody
            if bytes == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var result = Data(), buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(buffer, count: count) }
                bytes = result
            }
            let body = try JSONSerialization.jsonObject(with: bytes!) as! [String: Any]
            XCTAssertEqual(body["thread_id"] as? String, "42"); XCTAssertEqual(body["votes"] as? Int, 2)
            return (200, #"{"code":200,"msg":"ok"}"#)
        }
        try await client(token: "token").vote(threadID: "42", votes: 2)
        StubProtocol.handler = { _ in (200, #"{"code":0}"#) }
        do { try await client(token: "token").vote(threadID: "42", votes: 1); XCTFail() } catch { XCTAssertEqual(error as? ForumError, .message("接口调用失败。")) }
        StubProtocol.handler = { _ in (201, #"{"code":200}"#) }
        do { try await client(token: "token").vote(threadID: "42", votes: 1); XCTFail() } catch { XCTAssertEqual(error as? ForumError, .message("请求结果无法确认，请刷新后查看。")) }
        StubProtocol.handler = { _ in XCTFail(); return (200, "{}") }
        do { try await client(token: "token").vote(threadID: "42", votes: 4); XCTFail() } catch { XCTAssertEqual(error as? ForumError, .message("请选择 1 至 3 籽。")) }
        do { try await client().vote(threadID: "42", votes: 1); XCTFail() } catch { XCTAssertEqual(error as? ForumError, .unauthorized) }
    }
}
