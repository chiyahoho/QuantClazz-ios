import Foundation
import CoreFoundation

public enum ForumError: Error, LocalizedError, Equatable {
    case unauthorized, forbidden, verificationRequired, message(String), invalidResponse
    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "请先登录，或重新登录已过期的会话。"
        case .forbidden: return "当前账号没有查看此内容的权限。"
        case .verificationRequired: return "网站要求完成验证，请在官网验证后重试。"
        case .message(let text): return text
        case .invalidResponse: return "网站返回了无法识别的数据。"
        }
    }
}

public struct ForumClient: Sendable {
    public static let siteURL = URL(string: "https://bbs.quantclass.cn")!
    public static let isolatedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()
    private let token: String?
    private let session: URLSession
    private let pageSize = 20
    public init(token: String? = nil, session: URLSession = ForumClient.isolatedSession) { self.token = token; self.session = session }

    /// Loads the authenticated account through the same `/users/{id}` resource
    /// used by the official forum client. The id is taken from the signed access
    /// token rather than guessed from unrelated account data.
    public func currentUser() async throws -> ForumUser {
        try requireToken()
        guard let token, let userID = Self.jwtSubject(token) else { throw ForumError.invalidResponse }
        let root = try await get("users/" + userID, authenticated: true)
        guard let resource = root["data"] as? JSON,
              let id = resource.id("id"), id == userID else { throw ForumError.invalidResponse }
        let attributes = resource["attributes"] as? JSON ?? resource
        let name = attributes.string("username", "userName", "name")
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ForumError.invalidResponse }
        let unread = attributes.int("unreadNotifications")
        let typeUnread = (attributes["typeUnreadNotifications"] as? JSON ?? [:]).reduce(into: [String: Int]()) { result, pair in
            if let value = pair.value as? NSNumber { result[pair.key] = value.intValue }
            else if let value = pair.value as? String, let count = Int(value) { result[pair.key] = count }
        }
        return ForumUser(id: id, name: name, avatarURL: Self.safeImageURL(attributes.string("avatar", "avatarUrl", "avatarURL")), unreadNotifications: unread, typeUnreadNotifications: typeUnread)
    }

    public func categories() async throws -> [ForumCategory] {
        let root = try await get("categories.v2")
        guard let rows = root["Data"] as? [JSON] else { throw ForumError.invalidResponse }
        func flatten(_ rows: [JSON]) throws -> [ForumCategory] {
            try rows.flatMap { row -> [ForumCategory] in
                guard let id = row.id("pid", "id"), let name = row["name"] as? String else { throw ForumError.invalidResponse }
                return [ForumCategory(id: id, name: name)] + (try flatten(row["children"] as? [JSON] ?? []))
            }
        }
        return try flatten(rows)
    }
    public func threads(page: Int, categoryID: String? = nil, essenceOnly: Bool = false) async throws -> Page<ThreadSummary> {
        var query = pagination(page) + [.init(name: "filter[sticky]", value: "0"), .init(name: "filter[essence]", value: essenceOnly ? "1" : "0")]
        if let categoryID { query.append(URLQueryItem(name: "filter[categoryids][]", value: categoryID)) }
        let root = try await get("threads.v2", query)
        let result = try v2Page(root) { try Self.summary($0) }
        // The live v2 endpoint prepends a non-essence pinned rules thread even
        // with sticky=0. Preserve server pagination while enforcing this API's
        // essence-only contract locally.
        return essenceOnly ? Page(items: result.items.filter(\.isEssence), hasMore: result.hasMore) : result
    }
    public func userThreads(userID: String, page: Int, essenceOnly: Bool = false) async throws -> Page<ThreadSummary> {
        guard !userID.isEmpty else { throw ForumError.invalidResponse }
        let query: [URLQueryItem] = [
            .init(name: "filter[isDeleted]", value: "no"),
            .init(name: "filter[isDisplay]", value: "yes"),
            .init(name: "filter[type]", value: "0,1,2,3,4,6"),
            .init(name: "filter[isApproved]", value: "1"),
            .init(name: "filter[userId]", value: userID),
            .init(name: "filter[isEssence]", value: essenceOnly ? "1" : "0"),
            .init(name: "sort", value: "-createdAt"),
            .init(name: "include", value: "user,firstPost,firstPost.images,category"),
            .init(name: "page[number]", value: String(max(1, page))),
            .init(name: "page[limit]", value: String(pageSize))
        ]
        let root = try await get("threads", query)
        guard let rows = root["data"] as? [JSON] else { throw ForumError.invalidResponse }
        let included = root["included"] as? [JSON] ?? []
        let items = try rows.map { try Self.jsonSummary($0, included: included) }
        let meta = root["meta"] as? JSON ?? [:]
        let hasMore = meta["threadCount"] != nil ? max(1, page) * pageSize < meta.int("threadCount") : rows.count == pageSize
        return Page(items: items, hasMore: hasMore)
    }
    public func thread(id: String) async throws -> ThreadDetail {
        let root = try await get("threads.detail.v2", [URLQueryItem(name: "pid", value: id)])
        guard let data = root["Data"] as? JSON, let thread = data["thread"] as? JSON else { throw ForumError.invalidResponse }
        let canView = thread.bool("canViewPosts") ?? thread.bool("canViewPost") ?? false
        let post = data["firstPost"] as? JSON ?? [:]
        let html = canView ? Self.postHTML(post) : ""

        // The official page always renders its comment composer and gates publish on
        // login. `thread.canComment` controls a separate original-post side action,
        // so it must not disable ordinary replies when absent or false.
        let canReply = canView && !(token?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return ThreadDetail(summary: try Self.summary(data), html: html, canView: canView, isFavorite: data.bool("isFavorite") ?? thread.bool("isFavorite") ?? false, canFavorite: data.bool("canFavorite") ?? thread.bool("canFavorite") ?? false, canReply: canReply, isVoted: data.bool("isVoted") ?? false, remainingVotes: data.int("remainingVotes"), canVote: thread.bool("canVote") ?? false, voteCount: thread.int("voteCount"))
    }
    public func comments(threadID: String, page: Int) async throws -> Page<ForumComment> {
        let root = try await get("posts.v2", pagination(page) + [.init(name: "filter[thread]", value: threadID), .init(name: "sort", value: "createdAt")])
        return try v2Page(root) { row in
            guard let id = row.id("id", "pid") else { throw ForumError.invalidResponse }
            let user = row["user"] as? JSON ?? [:]
            return ForumComment(id: id, authorID: user.id("id") ?? row.id("userId"), authorName: user.string("username", "userName"), avatarURL: Self.safeImageURL(user.string("avatar", "avatarUrl")), html: row.string("contentHtml"), createdAt: row.string("createdAt"))
        }
    }
    public func createComment(threadID: String, text: String) async throws -> CommentSubmission {
        try requireToken()
        guard !threadID.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ForumError.message("评论内容不能为空。") }
        guard text.count <= 40_000 else { throw ForumError.message("评论内容不能超过 40000 个字符。") }
        var request = try makeRequest("posts", [])
        request.httpMethod = "POST"
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "data": [
                "type": "posts",
                "attributes": ["content": text],
                "relationships": ["thread": ["data": ["type": "threads", "id": threadID]]]
            ]
        ])
        let root = try await perform(request, allowUnrecognizedSuccess: true)
        guard let resource = root["data"] as? JSON else { return CommentSubmission(comment: nil, status: .accepted) }
        let attributes = resource["attributes"] as? JSON ?? resource
        let included = root["included"] as? [JSON] ?? []
        let relationships = resource["relationships"] as? JSON ?? [:]
        let userRef = (relationships["user"] as? JSON)?["data"] as? JSON ?? [:]
        let includedUser = included.first { $0.id("id") == userRef.id("id") && $0.string("type") == userRef.string("type") }
        let user = attributes["user"] as? JSON ?? includedUser?["attributes"] as? JSON ?? [:]
        let returnedHTML = attributes.string("contentHtml", "parseContentHtml")
        let html = returnedHTML.isEmpty ? Self.plainTextHTML(text) : returnedHTML
        let comment = resource.id("id").map { ForumComment(id: $0, authorID: userRef.id("id") ?? user.id("id") ?? attributes.id("userId"), authorName: user.string("username", "userName"), avatarURL: Self.safeImageURL(user.string("avatar", "avatarUrl")), html: html, createdAt: attributes.string("createdAt")) }
        let status: CommentSubmissionStatus
        if attributes["isApproved"] == nil { status = .accepted }
        else if attributes.int("isApproved") == 0 { status = .pendingModeration }
        else if attributes.int("isApproved") == 1 { status = .published }
        else { status = .accepted }
        return CommentSubmission(comment: comment, status: status)
    }
    public func favoriteFolders() async throws -> [FavoriteFolder] {
        let root = try await get("user/favorites", [.init(name: "page[number]", value: "1"), .init(name: "page[limit]", value: "0"), .init(name: "isAll", value: "1")], authenticated: true)
        let custom = root["data"] as? JSON
        guard let rows = custom?["favorites"] as? [JSON] ?? root["data"] as? [JSON] else { throw ForumError.invalidResponse }
        return try rows.map { row in
            guard let id = row.id("id") else { throw ForumError.invalidResponse }
            let attrs = row["attributes"] as? JSON ?? row
            return FavoriteFolder(id: id, name: attrs.string("name"), count: attrs.int("threadCount", "thread_count", "count"))
        }
    }
    public func favorites(folderID: String, page: Int) async throws -> Page<ThreadSummary> {
        let root = try await get("favorites", [.init(name: "favorite_id", value: folderID), .init(name: "page[number]", value: String(max(1, page))), .init(name: "page[limit]", value: String(pageSize)), .init(name: "include", value: "user,firstPost,firstPost.images,category")], authenticated: true)
        guard let rows = root["data"] as? [JSON] else { throw ForumError.invalidResponse }
        let included = root["included"] as? [JSON] ?? []
        let items = try rows.map { try Self.jsonSummary($0, included: included) }
        let meta = root["meta"] as? JSON ?? [:]
        let hasMore: Bool
        if meta["threadCount"] != nil { hasMore = max(1, page) * pageSize < meta.int("threadCount") }
        else if let links = root["links"] as? JSON { hasMore = links["next"] is String }
        else { hasMore = rows.count == pageSize }
        return Page(items: items, hasMore: hasMore)
    }
    public func setFavorite(threadID: String, folderIDs: [String], isFavorite: Bool) async throws {
        try requireToken()
        guard !isFavorite || !folderIDs.isEmpty else { throw ForumError.message("请选择至少一个收藏夹。") }
        var attrs: JSON = ["isFavorite": isFavorite]
        if isFavorite { attrs["favorite_id"] = folderIDs }
        var request = try makeRequest("threads/" + threadID, [])
        request.httpMethod = "POST"
        request.setValue("patch", forHTTPHeaderField: "x-http-method-override")
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["data": ["type": "threads", "id": threadID, "attributes": attrs]])
        _ = try await perform(request, allowEmpty: true)
    }
    public func viewRecords(page: Int) async throws -> Page<ThreadActivity> {
        try await activities(path: "user/viewrecords", page: page, dateKey: "viewAt", votes: false)
    }
    public func voteRecords(page: Int) async throws -> Page<ThreadActivity> {
        try await activities(path: "user/vote/records", page: page, dateKey: "voteAt", votes: true)
    }
    private func activities(path: String, page: Int, dateKey: String, votes: Bool) async throws -> Page<ThreadActivity> {
        let page = max(1, page)
        let root = try await get(path, [.init(name: "page[number]", value: String(page)), .init(name: "page[limit]", value: String(pageSize))], authenticated: true)
        guard let rows = root["data"] as? [JSON] else { throw ForumError.invalidResponse }
        let included = root["included"] as? [JSON] ?? []
        let items = try rows.map { row -> ThreadActivity in
            let attrs = row["attributes"] as? JSON ?? [:]
            return ThreadActivity(thread: try Self.jsonSummary(row, included: included), occurredAt: attrs.string(dateKey), votes: votes ? attrs.int("votes") : nil)
        }
        let total = (root["meta"] as? JSON)?.int("threadCount") ?? 0
        return Page(items: items, hasMore: total > 0 ? page * pageSize < total : rows.count == pageSize)
    }
    public func notifications(types: [String], page: Int, limit: Int = 10) async throws -> Page<ForumNotification> {
        try requireToken()
        let page = max(1, page), limit = max(1, limit)
        let root = try await get("notification", [.init(name: "filter[type]", value: types.joined(separator: ",")), .init(name: "page[number]", value: String(page)), .init(name: "page[limit]", value: String(limit))], authenticated: true)
        guard let rows = root["data"] as? [JSON] else { throw ForumError.invalidResponse }
        let items = try rows.map { row -> ForumNotification in
            guard let id = row.id("id"), let attrs = row["attributes"] as? JSON else { throw ForumError.invalidResponse }
            let raw = attrs["raw"] as? JSON ?? [:]
            return ForumNotification(id: id, type: attrs.string("type"), userID: attrs.id("user_id"), userName: attrs.string("user_name"), userAvatarURL: Self.safeImageURL(attrs.string("user_avatar")), createdAt: attrs.string("created_at"), threadID: attrs.id("thread_id"), threadTitle: Self.displayText(attrs.string("thread_title")), threadUserName: attrs.string("thread_username"), postContent: Self.displayText(attrs.string("post_content")), content: Self.displayText(attrs.string("content")), title: Self.displayText(attrs.string("title")), templateID: raw["tpl_id"].flatMap { ($0 as? NSNumber)?.intValue ?? Int($0 as? String ?? "") })
        }
        let total = (root["meta"] as? JSON)?.int("total") ?? 0
        return Page(items: items, hasMore: total > 0 ? page * limit < total : rows.count == limit)
    }
    public func vote(threadID: String, votes: Int) async throws {
        try requireToken()
        guard !threadID.isEmpty, (1...3).contains(votes) else { throw ForumError.message("请选择 1 至 3 籽。") }
        var request = try makeRequest("thread/vote/records", [])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["thread_id": threadID, "votes": votes])
        let root = try await perform(request, expectedStatus: 200)
        guard root.int("code") == 200 else { throw ForumError.message(root.string("msg", "Message").isEmpty ? "投籽结果无法确认，请刷新后查看。" : root.string("msg", "Message")) }
    }
    private func requireToken() throws { guard let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ForumError.unauthorized } }
    private static func jwtSubject(_ token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded),
              let payload = try? JSONSerialization.jsonObject(with: bytes) as? JSON else { return nil }
        let subject: String
        if let value = payload["sub"] as? String { subject = value }
        else if let value = payload["sub"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { subject = value.stringValue }
        else { return nil }
        // Discuz user ids are decimal. Keeping this to one path segment also
        // ensures token claims cannot alter the request target.
        guard !subject.isEmpty, subject.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return subject
    }
    private func pagination(_ page: Int) -> [URLQueryItem] { [.init(name: "page", value: String(max(1, page))), .init(name: "perPage", value: String(pageSize))] }
    private func makeRequest(_ path: String, _ query: [URLQueryItem]) throws -> URLRequest {
        // IDs are a single path segment; never permit callers to redirect requests.
        guard !path.contains(".."), !path.contains("?"), !path.contains("#") else { throw ForumError.invalidResponse }
        var components = URLComponents(url: Self.siteURL.appendingPathComponent("api/" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ForumError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.api+json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        return request
    }
    private func get(_ path: String, _ query: [URLQueryItem] = [], authenticated: Bool = false) async throws -> JSON {
        if authenticated { try requireToken() }
        return try await perform(makeRequest(path, query))
    }
    private func perform(_ request: URLRequest, allowEmpty: Bool = false, allowUnrecognizedSuccess: Bool = false, expectedStatus: Int? = nil) async throws -> JSON {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ForumError.invalidResponse }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? JSON
        let errors = root?["errors"] as? [JSON] ?? []
        let message = root?.string("Message", "msg") ?? ""
        let errorText = errors.map { $0.string("code") + " " + $0.string("detail", "title") }.joined(separator: " ")
        let text = message + " " + errorText
        let lower = text.lowercased()
        if lower.contains("captcha") || http.statusCode == 429 { throw ForumError.verificationRequired }
        if http.statusCode == 401 || lower.contains("not_authenticated") || lower.contains("token_expired") || lower.contains("access_denied") { throw ForumError.unauthorized }
        if http.statusCode == 403 || lower.contains("permission_denied") { throw ForumError.forbidden }
        guard (200..<300).contains(http.statusCode) else { throw ForumError.message(errors.first?.string("detail", "title") ?? "请求失败（HTTP \(http.statusCode)）。") }
        if let expectedStatus, http.statusCode != expectedStatus { throw ForumError.message("请求结果无法确认，请刷新后查看。") }
        if let code = root?["Code"], String(describing: code) != "0" { throw ForumError.message(message.isEmpty ? "接口调用失败。" : message) }
        if let code = root?["code"], String(describing: code) != "200" { throw ForumError.message(message.isEmpty ? "接口调用失败。" : message) }
        if !errors.isEmpty { throw ForumError.message(errorText.trimmingCharacters(in: .whitespaces)) }
        if allowEmpty && data.isEmpty { return [:] }
        if allowUnrecognizedSuccess && root == nil { return [:] }
        guard let root else { throw ForumError.invalidResponse }
        return root
    }
    private func v2Page<T: Sendable>(_ root: JSON, transform: (JSON) throws -> T) throws -> Page<T> {
        guard let data = root["Data"] as? JSON, let rows = data["pageData"] as? [JSON] else { throw ForumError.invalidResponse }
        let hasMore = data["totalPage"] != nil ? data.int("currentPage") < data.int("totalPage") : (data["nextPageUrl"] is String)
        return Page(items: try rows.map(transform), hasMore: hasMore)
    }
    // Display-only conversion. Never evaluates HTML or changes the article HTML.
    private static func displayText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1\\s*>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?i)</?(?:p|div|h[1-6]|li|br|tr)\\b[^>]*>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&amp;": "&"]
        for key in entities.keys.sorted() where key != "&amp;" { text = text.replacingOccurrences(of: key, with: entities[key]!) }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let range = Range(match.range(at: 1), in: text), let fullRange = Range(match.range, in: text) else { continue }
                let number = String(text[range])
                let value = number.hasPrefix("x") ? UInt32(number.dropFirst(), radix: 16) : UInt32(number)
                if let value, let scalar = UnicodeScalar(value) { text.replaceSubrange(fullRange, with: String(scalar)) }
            }
        }
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    private static func postHTML(_ post: JSON) -> String {
        // Official frontend uses Vditor.preview(firstPost.threadContent).
        if let markdown = post["threadContent"] as? String, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return MarkdownHTML.render(markdown) }

        if let html = post["contentHtml"] as? String, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return html }
        if let html = post["parseContentHtml"] as? String, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return html }
        // Older detail responses expose markdown only. Preserve it as safe text.
        let text = post.string("content").replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        return text.isEmpty ? "" : "<pre>" + text + "</pre>"
    }
    private static func plainTextHTML(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "\n", with: "<br>")
        return "<p>" + escaped + "</p>"
    }
    private static func summary(_ row: JSON) throws -> ThreadSummary {
        guard let thread = row["thread"] as? JSON, let id = thread.id("pid", "id") else { throw ForumError.invalidResponse }
        let user = row["user"] as? JSON ?? row["author"] as? JSON ?? [:]
        let category = thread["category"] as? JSON ?? row["category"] as? JSON ?? [:]
        let post = row["firstPost"] as? JSON ?? [:]
        let summary = thread["summary"] as? String ?? post.string("summaryText", "summary")
        return ThreadSummary(id: id, title: thread.string("title"), authorID: user.id("pid", "id", "userId"), authorName: user.string("userName", "username"), avatarURL: safeImageURL(user.string("avatar", "avatarUrl")), summary: Self.displayText(summary), categoryName: category.string("name"), createdAt: thread.string("createdAt"), replyCount: thread.int("postCount", "replyCount"), viewCount: thread.int("viewCount"), imageURLs: images(row, post: post, canView: thread.bool("canViewPosts") ?? false), thumbnailURL: thumbnail(row, post: post, canView: thread.bool("canViewPosts") ?? false), isEssence: thread.bool("isEssence") ?? false, isOriginal: thread.bool("isOriginal") ?? false)
    }
    private static func safeImageURL(_ raw: String) -> URL? {
        guard !raw.isEmpty, let url = URL(string: raw, relativeTo: siteURL)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
    private static func imageRows(_ rows: [JSON], thumbnails: Bool = false) -> [URL] {
        rows.compactMap { row in
            for key in thumbnails ? ["thumbUrl", "url"] : ["url", "thumbUrl"] { if let raw = row[key] as? String, let url = safeImageURL(raw) { return url } }
            return nil
        }
    }
    private static func uniqueImages(_ images: [URL]) -> [URL] {
        var seen = Set<URL>()
        return images.filter { seen.insert($0).inserted }
    }
    private static func images(_ row: JSON, post: JSON, canView: Bool) -> [URL] {
        if row["firstPost"] != nil && !canView { return [] }
        let rows = (row["attachment"] as? [JSON] ?? []) + (row["images"] as? [JSON] ?? []) + (row["attachments"] as? [JSON] ?? []) + (post["images"] as? [JSON] ?? [])
        let urls = uniqueImages(imageRows(rows))
        if !urls.isEmpty { return urls }
        return canView ? MarkdownHTML.imageURLs(post.string("threadContent")) : []
    }
    private static func thumbnail(_ row: JSON, post: JSON, canView: Bool) -> URL? {
        if row["firstPost"] != nil && !canView { return nil }
        let rows = (row["attachment"] as? [JSON] ?? []) + (row["images"] as? [JSON] ?? []) + (row["attachments"] as? [JSON] ?? []) + (post["images"] as? [JSON] ?? [])
        return imageRows(rows, thumbnails: true).first ?? images(row, post: post, canView: canView).first
    }
    private static func jsonImages(row: JSON, included: [JSON], post: JSON, thumbnails: Bool = false) -> [URL] {
        let relationships = row["relationships"] as? JSON ?? [:]
        let postRef = ((relationships["firstPost"] as? JSON)?["data"] as? JSON) ?? [:]
        let postResource = included.first { $0.id("id") == postRef.id("id") && $0.string("type") == postRef.string("type") } ?? [:]
        let postRelationships = postResource["relationships"] as? JSON ?? [:]
        let refs = ((postRelationships["images"] as? JSON)?["data"] as? [JSON]) ?? []
        let rows = refs.compactMap { ref in included.first { $0.id("id") == ref.id("id") && $0.string("type") == ref.string("type") }?["attributes"] as? JSON }
        let urls = uniqueImages(imageRows(rows + (post["images"] as? [JSON] ?? []), thumbnails: thumbnails))
        return urls.isEmpty && (row["attributes"] as? JSON)?.bool("canViewPosts") == true ? MarkdownHTML.imageURLs(post.string("threadContent")) : urls
    }
    private static func jsonSummary(_ row: JSON, included: [JSON]) throws -> ThreadSummary {
        guard let id = row.id("id"), let attrs = row["attributes"] as? JSON else { throw ForumError.invalidResponse }
        func relationshipRef(_ name: String) -> JSON {
            let relationships = row["relationships"] as? JSON ?? [:]
            let rel = relationships[name] as? JSON ?? [:]
            return rel["data"] as? JSON ?? [:]
        }
        func related(_ name: String) -> JSON {
            let ref = relationshipRef(name)
            return (included.first { $0.id("id") == ref.id("id") && $0.string("type") == ref.string("type") }?["attributes"] as? JSON) ?? [:]
        }
        let user = related("user"), category = related("category"), post = related("firstPost")
        return ThreadSummary(id: id, title: attrs.string("title"), authorID: relationshipRef("user").id("id"), authorName: user.string("username", "userName"), avatarURL: safeImageURL(user.string("avatarUrl", "avatar")), summary: Self.displayText(post.string("summaryText", "summary")), categoryName: category.string("name"), createdAt: attrs.string("createdAt"), replyCount: attrs.int("postCount", "replyCount"), viewCount: attrs.int("viewCount"), imageURLs: jsonImages(row: row, included: included, post: post), thumbnailURL: jsonImages(row: row, included: included, post: post, thumbnails: true).first, isEssence: attrs.bool("isEssence") ?? false, isOriginal: attrs.bool("isOriginal") ?? false)
    }
}
private typealias JSON = [String: Any]
private extension Dictionary where Key == String, Value == Any {
    func string(_ keys: String...) -> String { for key in keys { if let value = self[key] as? String { return value } }; return "" }
    func id(_ keys: String...) -> String? { for key in keys { if let s = self[key] as? String, !s.isEmpty { return s }; if let n = self[key] as? NSNumber { return n.stringValue } }; return nil }
    func int(_ keys: String...) -> Int { for key in keys { if let n = self[key] as? NSNumber { return n.intValue }; if let s = self[key] as? String, let n = Int(s) { return n } }; return 0 }
    func bool(_ key: String) -> Bool? { if let n = self[key] as? NSNumber { return n.boolValue }; if let s = self[key] as? String { return s == "1" || s.lowercased() == "true" }; return nil }
}
