import Foundation
import Security

enum ShotloomFeedbackType: String, CaseIterable, Identifiable, Codable {
    case feature = "feature_request", bug, improvement, other
    var id: String { rawValue }
    var title: String {
        let key: String
        switch self {
        case .feature: key = "Feature request"
        case .bug: key = "Bug report"
        case .improvement: key = "Improvement"
        case .other: key = "Other feedback"
        }
        return L10n.translate(key)
    }
}

struct ShotloomFeedbackDraft: Encodable {
    var type: ShotloomFeedbackType = .improvement
    var title = ""
    var description = ""
    var email = ""
    let product = "shotloom"
    var context: ShotloomSupportContext?
    enum CodingKeys: String, CodingKey {
        case product, type, title, description, email
        case context = "extension"
    }
    init(context: ShotloomSupportContext? = .current) { self.context = context }
    var normalized: Self {
        var value = self
        value.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        value.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        value.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }
    var isValid: Bool {
        let value = normalized
        return (3...160).contains(value.title.utf16.count) &&
            (10...5_000).contains(value.description.utf16.count) &&
            value.email.utf16.count <= 254 &&
            value.email.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }
}

/// Deliberately excludes proxy addresses, credentials, connection history and logs.
struct ShotloomSupportContext: Encodable {
    let source = "macos-native"
    let platform = "macOS"
    let appVersion: String
    let build: String
    let systemVersion: String
    let language = L10n.language
    static var current: Self {
        Self(appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-",
             build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-",
             systemVersion: ProcessInfo.processInfo.operatingSystemVersionString)
    }
}

struct ShotloomSupportThread: Codable, Identifiable, Equatable {
    let id: String
    let conversationToken: String
    let title: String
    let createdAt: String
    var isValid: Bool {
        UUID(uuidString: id) != nil &&
            conversationToken.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }
}

struct ShotloomSupportConversation: Decodable {
    struct Feedback: Decodable {
        let id: String
        let title: String
        let status: String
        let updatedAt: String
        var statusTitle: String {
            let key: String
            switch status {
            case "open": key = "Received"
            case "reviewing": key = "Under review"
            case "planned": key = "Planned"
            case "resolved": key = "Resolved"
            case "closed": key = "Closed"
            default: key = "Unknown status"
            }
            return L10n.translate(key)
        }
    }
    struct Message: Decodable, Identifiable {
        let id: String
        let author: String
        let body: String
        let createdAt: String
    }
    let feedback: Feedback
    let messages: [Message]
}

enum ShotloomSupportError: LocalizedError {
    case invalidDraft, invalidResponse, rejected(Int), uncertainSubmission, uncertainReply, storage
    var errorDescription: String? {
        let key: String
        switch self {
        case .invalidDraft: key = "Enter a title of 3–160 characters, a description of 10–5,000 characters, and a valid email."
        case .invalidResponse: key = "Support returned an invalid response. Please try refreshing."
        case .rejected(let status):
            switch status {
            case 401, 404: key = "This support conversation is unavailable. Check your saved access credentials."
            case 400, 413: key = "Support could not accept this content. Check the field lengths and email address."
            default: key = "Support is unavailable right now. Please try again later."
            }
        case .uncertainSubmission: key = "Submission could not be confirmed. It may have reached support. Do not send the same feedback again immediately."
        case .uncertainReply: key = "Reply could not be confirmed. Refresh the conversation to check whether it arrived before sending again."
        case .storage: key = "The conversation could not be saved in Keychain. Keep this window open and retry saving; your feedback will not be submitted again."
        }
        return L10n.translate(key)
    }
}

/// Native requests carry no Origin header. Never follow redirects with a bearer token.
final class ShotloomSupportClient {
    static let website = URL(string: "https://support.monoware.app/?product=shotloom")!
    private let endpoint = URL(string: "https://support.monoware.app/api/v1/feedback")!
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    func submit(_ draft: ShotloomFeedbackDraft) async throws -> ShotloomSupportThread {
        guard draft.isValid else { throw ShotloomSupportError.invalidDraft }
        let data = try JSONEncoder().encode(draft.normalized)
        guard data.count <= 24_576 else { throw ShotloomSupportError.invalidDraft }
        let result: Created = try await send(url: endpoint, method: "POST", body: data, uncertain: .uncertainSubmission)
        let thread = ShotloomSupportThread(id: result.id, conversationToken: result.conversationToken,
                                            title: draft.normalized.title, createdAt: result.createdAt)
        guard result.ok, thread.isValid else { throw ShotloomSupportError.uncertainSubmission }
        return thread
    }
    func conversation(_ thread: ShotloomSupportThread) async throws -> ShotloomSupportConversation {
        guard thread.isValid else { throw ShotloomSupportError.invalidResponse }
        let result: ShotloomSupportConversation = try await send(url: endpoint.appendingPathComponent(thread.id), token: thread.conversationToken)
        guard result.feedback.id == thread.id else { throw ShotloomSupportError.invalidResponse }
        return result
    }
    func reply(_ message: String, to thread: ShotloomSupportThread) async throws {
        let value = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard thread.isValid, (1...5_000).contains(value.utf16.count) else { throw ShotloomSupportError.invalidDraft }
        let body = try JSONEncoder().encode(["message": value])
        guard body.count <= 16_384 else { throw ShotloomSupportError.invalidDraft }
        let result: Reply = try await send(url: endpoint.appendingPathComponent(thread.id).appendingPathComponent("messages"),
                                          method: "POST", body: body, token: thread.conversationToken, uncertain: .uncertainReply)
        guard result.ok else { throw ShotloomSupportError.uncertainReply }
    }
    private struct Created: Decodable { let ok: Bool; let id: String; let conversationToken: String; let createdAt: String }
    private struct Reply: Decodable { let ok: Bool; let message: ShotloomSupportConversation.Message }

    private func send<T: Decodable>(url: URL, method: String = "GET", body: Data? = nil,
                                    token: String? = nil, uncertain: ShotloomSupportError? = nil) async throws -> T {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw uncertain ?? error }
        guard let http = response as? HTTPURLResponse else { throw uncertain ?? .invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            // Server failures can happen after a write. Do not automatically repeat POSTs.
            if http.statusCode >= 500, let uncertain { throw uncertain }
            throw ShotloomSupportError.rejected(http.statusCode)
        }
        guard data.count <= 2_097_152 else { throw uncertain ?? .invalidResponse }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw uncertain ?? .invalidResponse }
    }
}

protocol ShotloomSupportPersistence {
    func load() async throws -> [ShotloomSupportThread]
    func save(_ threads: [ShotloomSupportThread]) async throws
}

actor ShotloomSupportKeychain: ShotloomSupportPersistence {
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "app.monoware.shotloom.support.production",
        kSecAttrAccount as String: "conversations"] }
    func load() async throws -> [ShotloomSupportThread] {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let data = item as? Data,
              let threads = try? JSONDecoder().decode([ShotloomSupportThread].self, from: data),
              threads.allSatisfy(\.isValid) else { throw ShotloomSupportError.storage }
        return threads
    }
    func save(_ threads: [ShotloomSupportThread]) async throws {
        guard threads.allSatisfy(\.isValid) else { throw ShotloomSupportError.storage }
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(threads),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw ShotloomSupportError.storage }
        var insertion = query
        attributes.forEach { insertion[$0.key] = $0.value }
        guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { throw ShotloomSupportError.storage }
    }
}
