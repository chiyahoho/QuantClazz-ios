import Combine
import Foundation
import ForumCore
import Security
import WebKit

@MainActor
final class AppSession: ObservableObject {
    @Published private(set) var token: String?
    @Published var showLogin = false
    @Published private(set) var isValidating = false
    @Published var authError: String?
    @Published private(set) var identityVersion = 0
    @Published private(set) var currentUser: ForumUser?
    @Published private(set) var profileLoading = false
    @Published private(set) var profileError: String?
    private var generation = 0
    private var lastProfileRefresh: Date?
    private var profileRequestID = 0
    var isLoggedIn: Bool { token != nil }
    var client: ForumClient { ForumClient(token: token) }
    static let loginStore = WKWebsiteDataStore.nonPersistent()

    init() {
        do {
            if let saved = try CredentialStore.read() {
                isValidating = true
                Task { await acceptToken(saved) }
            }
        } catch { authError = error.localizedDescription }
    }

    func acceptToken(_ candidate: String) async {
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count < 32_768 else {
            authError = "官网尚未完成登录，请刷新二维码后重试。"
            return
        }
        generation += 1
        let request = generation
        isValidating = true
        authError = nil
        defer { if generation == request { isValidating = false } }
        do {
            let candidateClient = ForumClient(token: value)
            _ = try await candidateClient.favoriteFolders()
            guard generation == request, !Task.isCancelled else { return }
            try CredentialStore.save(value)
            currentUser = nil
            profileError = nil
            token = value
            identityVersion += 1
            showLogin = false
            isValidating = false
            await refreshCurrentUser()
        } catch {
            guard generation == request, !Task.isCancelled, !Self.isCancellation(error) else { return }
            authError = error.localizedDescription
            if case ForumError.unauthorized = error, token == nil {
                token = nil
                identityVersion += 1
                do { try CredentialStore.delete() } catch { authError = error.localizedDescription }
                showLogin = true
            }
        }
    }

    func signOut() async {
        generation += 1
        token = nil
        currentUser = nil
        lastProfileRefresh = nil
        profileLoading = false
        profileError = nil
        identityVersion += 1
        isValidating = false
        authError = nil
        do { try CredentialStore.delete() } catch { authError = error.localizedDescription }
        await Self.loginStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    func handle(_ error: Error) {
        guard !Self.isCancellation(error) else { return }
        authError = error.localizedDescription
        if case ForumError.unauthorized = error {
            generation += 1
            token = nil
            currentUser = nil
            lastProfileRefresh = nil
            profileLoading = false
            profileError = nil
            identityVersion += 1
            isValidating = false
            do { try CredentialStore.delete() } catch { authError = error.localizedDescription }
            showLogin = true
        } else if case ForumError.verificationRequired = error {
            showLogin = true
        }
    }

    func refreshCurrentUser(force: Bool = true) async {
        guard token != nil else {
            currentUser = nil; profileLoading = false; profileError = nil; lastProfileRefresh = nil
            return
        }
        if !force, let lastProfileRefresh, Date().timeIntervalSince(lastProfileRefresh) < 60 { return }
        let request = generation
        let version = identityVersion
        profileRequestID += 1
        let profileRequest = profileRequestID
        let client = client
        profileLoading = true
        profileError = nil
        defer {
            if generation == request, identityVersion == version, profileRequest == profileRequestID { profileLoading = false }
        }
        do {
            let user = try await client.currentUser()
            guard generation == request, identityVersion == version, profileRequest == profileRequestID, !Task.isCancelled else { return }
            currentUser = user
            lastProfileRefresh = Date()
        } catch {
            guard generation == request, identityVersion == version, profileRequest == profileRequestID,
                  !Task.isCancelled, !Self.isCancellation(error) else { return }
            profileError = error.localizedDescription
            if case ForumError.unauthorized = error { handle(error) }
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

private enum CredentialStore {
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "io.github.chiyahoho.QuantClazz.forum",
         kSecAttrAccount as String: "access_token"]
    }
    static func read() throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Keychain", code: -1, userInfo: [NSLocalizedDescriptionKey: "钥匙串中的登录信息无法读取。"])
        }
        return token
    }
    static func save(_ token: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try check(SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil))
        } else { try check(status) }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: "Keychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "钥匙串操作失败（\(status)）。"])
        }
    }
}
