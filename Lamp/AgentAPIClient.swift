import Foundation
import Security

struct AgentDirective: Decodable {
    struct Arguments: Decodable {
        var title: String?
        var detail: String?
        var estimatedMinutes: Int?
        var deadlineHint: String?
        var state: String?
        var note: String?
        var question: String?

        enum CodingKeys: String, CodingKey {
            case title, detail, state, note, question
            case estimatedMinutes = "estimated_minutes"
            case deadlineHint = "deadline_hint"
        }
    }

    var name: String
    var arguments: Arguments
    var model: String
}

enum AgentAPIClient {
    private static let supabaseURL = URL(string: "https://zmsktxdokruthaiooofb.supabase.co")!
    // Supabase publishable/anon keys are designed to ship in clients. RLS and user JWTs enforce access.
    private static let publishableKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inptc2t0eGRva3J1dGhhaW9vb2ZiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODg1MjYyNTQsImV4cCI6MjEwNDEwMjI1NH0.6CQRbDzwjkhmxKBcP8cCeWfDG7jztti4Ca6taLPvAuk"

    static func interpret(_ input: String) async throws -> AgentDirective {
        #if DEBUG
        let endpoint = URL(string: "http://127.0.0.1:8787/v1/interpret")!
        var request = URLRequest(url: endpoint, timeoutInterval: 22)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(input: input))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ClientError.invalidResponse
        }
        return try JSONDecoder().decode(AgentDirective.self, from: data)
        #else
        throw ClientError.productionEndpointNotConfigured
        #endif
    }

    static func analyzeScheduleImage(
        _ image: ImageIngestionService.PreparedImage,
        referenceDate: Date = .now,
        timezone: TimeZone = .current,
        locale: Locale = .current
    ) async throws -> ImageScheduleAnalysisResponse {
        let token = try await SupabaseAnonymousSession.shared.accessToken()
        let body = ImageAnalysisRequest(
            schemaVersion: 1,
            idempotencyKey: UUID().uuidString,
            timezone: timezone.identifier,
            locale: locale.identifier,
            referenceDate: ISO8601DateFormatter().string(from: referenceDate),
            image: .init(mimeType: image.mimeType, base64: image.base64, sha256: image.sha256)
        )
        let encoded = try JSONEncoder().encode(body)

        for attempt in 0..<2 {
            var request = URLRequest(
                url: supabaseURL.appending(path: "functions/v1/image-schedule"),
                timeoutInterval: 80
            )
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(publishableKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = encoded

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
                if http.statusCode == 200 {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    return try decoder.decode(ImageScheduleAnalysisResponse.self, from: data)
                }
                if attempt == 0, http.statusCode == 429 || http.statusCode >= 500 {
                    try await Task.sleep(for: .milliseconds(850))
                    continue
                }
                let payload = try? JSONDecoder().decode(APIErrorPayload.self, from: data)
                throw ClientError.server(payload?.message ?? payload?.error ?? "图片分析服务暂时不可用")
            } catch let error as ClientError {
                throw error
            } catch {
                if attempt == 0 {
                    try await Task.sleep(for: .milliseconds(850))
                    continue
                }
                throw ClientError.network
            }
        }
        throw ClientError.invalidResponse
    }

    private struct RequestBody: Encodable { var input: String }

    private struct ImageAnalysisRequest: Encodable {
        struct ImagePayload: Encodable {
            var mimeType: String
            var base64: String
            var sha256: String
        }

        var schemaVersion: Int
        var idempotencyKey: String
        var timezone: String
        var locale: String
        var referenceDate: String
        var image: ImagePayload
    }

    private struct APIErrorPayload: Decodable {
        var error: String?
        var message: String?
    }

    enum ClientError: LocalizedError {
        case invalidResponse
        case productionEndpointNotConfigured
        case network
        case server(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "服务器返回了无法读取的结果"
            case .productionEndpointNotConfigured: "生产端点尚未配置"
            case .network: "网络连接失败，请稍后重试"
            case let .server(message): message
            }
        }
    }
}

private actor SupabaseAnonymousSession {
    static let shared = SupabaseAnonymousSession()

    private let projectURL = URL(string: "https://zmsktxdokruthaiooofb.supabase.co")!
    private let publishableKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inptc2t0eGRva3J1dGhhaW9vb2ZiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODg1MjYyNTQsImV4cCI6MjEwNDEwMjI1NH0.6CQRbDzwjkhmxKBcP8cCeWfDG7jztti4Ca6taLPvAuk"
    private let keychainService = "com.lamp.planner.supabase"
    private let keychainAccount = "anonymous-session"
    private var cached: StoredSession?

    func accessToken() async throws -> String {
        let session = cached ?? load()
        if let session, session.expiresAt > Date.now.addingTimeInterval(90) {
            cached = session
            return session.accessToken
        }
        if let session, let refreshed = try? await refresh(session.refreshToken) {
            save(refreshed)
            return refreshed.accessToken
        }
        let created = try await signInAnonymously()
        save(created)
        return created.accessToken
    }

    private func signInAnonymously() async throws -> StoredSession {
        var request = authRequest(path: "auth/v1/signup")
        request.httpBody = Data("{}".utf8)
        return try await performAuth(request)
    }

    private func refresh(_ refreshToken: String) async throws -> StoredSession {
        var components = URLComponents(
            url: projectURL.appending(path: "auth/v1/token"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        var request = URLRequest(url: components.url!, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONEncoder().encode(["refresh_token": refreshToken])
        return try await performAuth(request)
    }

    private func authRequest(path: String) -> URLRequest {
        var request = URLRequest(url: projectURL.appending(path: path), timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        return request
    }

    private func performAuth(_ request: URLRequest) async throws -> StoredSession {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let payload = try? JSONDecoder().decode(AuthError.self, from: data)
            throw AgentAPIClient.ClientError.server(
                payload?.msg ?? payload?.message ?? "无法建立安全的匿名会话"
            )
        }
        let payload = try JSONDecoder().decode(AuthResponse.self, from: data)
        return StoredSession(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken,
            expiresAt: Date.now.addingTimeInterval(TimeInterval(payload.expiresIn))
        )
    }

    private func save(_ session: StoredSession) {
        cached = session
        guard let data = try? JSONEncoder().encode(session) else { return }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = baseQuery
            attributes.forEach { item[$0.key] = $0.value }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    private func load() -> StoredSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    private struct StoredSession: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
    }

    private struct AuthResponse: Decodable {
        var accessToken: String
        var refreshToken: String
        var expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    private struct AuthError: Decodable {
        var msg: String?
        var message: String?
    }
}
