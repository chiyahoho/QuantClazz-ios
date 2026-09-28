import XCTest
@testable import ForumCore

final class CurrentUserTests: XCTestCase {
    private func token(subject: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["sub": subject])
        let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    private func client(token: String) -> ForumClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ForumClient(token: token, session: URLSession(configuration: configuration))
    }

    func testCurrentUserUsesJWTSubjectAndDecodesJSONAPIProfile() async throws {
        let expectedToken = try token(subject: "123")
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/users/123")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(expectedToken)")
            return (200, #"{"data":{"type":"users","id":"123","attributes":{"username":"量化用户","avatarUrl":"https://example.com/avatar.png","unreadNotifications":7,"typeUnreadNotifications":{"voted":2,"replied":"3"}}}}"#)
        }
        let user = try await client(token: expectedToken).currentUser()
        XCTAssertEqual(user.id, "123")
        XCTAssertEqual(user.name, "量化用户")
        XCTAssertEqual(user.avatarURL?.absoluteString, "https://example.com/avatar.png")
        XCTAssertEqual(user.unreadNotifications, 7)
        XCTAssertEqual(user.typeUnreadNotifications["voted"], 2)
        XCTAssertEqual(user.typeUnreadNotifications["replied"], 3)
    }

    func testCurrentUserRejectsOpaqueOrUnsafeSubjectWithoutRequest() async throws {
        StubProtocol.handler = { _ in XCTFail("Malformed identity must not send a request"); return (200, "{}") }
        for value in ["opaque-token", try token(subject: "../users/7"), try token(subject: ""), try token(subject: "١٢٣"), try token(subject: true)] {
            do { _ = try await client(token: value).currentUser(); XCTFail("Expected invalid response") }
            catch { XCTAssertEqual(error as? ForumError, .invalidResponse) }
        }
    }

    func testCurrentUserRequiresMatchingResponseIdentityAndName() async throws {
        for body in [
            #"{"data":{"id":"124","attributes":{"username":"wrong"}}}"#,
            #"{"data":{"id":"123","attributes":{"avatar":"https://example.com/a.png"}}}"#
        ] {
            StubProtocol.handler = { _ in (200, body) }
            do { _ = try await client(token: token(subject: "123")).currentUser(); XCTFail("Expected invalid response") }
            catch { XCTAssertEqual(error as? ForumError, .invalidResponse) }
        }
    }
}
