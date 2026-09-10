import Foundation
import Security
import CryptoKit
import AuthenticationServices
import UIKit

struct AgentDirective: Decodable {
    struct Arguments: Decodable {
        var title: String?
        var detail: String?
        var estimatedMinutes: Int?
        var deadlineHint: String?
        var kind: String?
        var planningScope: String?
        var periodAnchor: String?
        var deadline: String?
        var importance: Int?
        var state: String?
        var note: String?
        var question: String?
        var startMinute: Int?
        var endMinute: Int?
        var weekdays: [Int]?
        var startsOn: String?
        var endsOn: String?

        enum CodingKeys: String, CodingKey {
            case title, detail, kind, deadline, importance, state, note, question
            case estimatedMinutes = "estimated_minutes"
            case deadlineHint = "deadline_hint"
            case planningScope = "planning_scope"
            case periodAnchor = "period_anchor"
            case startMinute = "start_minute"
            case endMinute = "end_minute"
            case weekdays
            case startsOn = "starts_on"
            case endsOn = "ends_on"
        }
    }

    var name: String
    var arguments: Arguments
    var model: String
}

enum AgentAPIClient {
    fileprivate static let supabaseURL = URL(string: "https://zmsktxdokruthaiooofb.supabase.co")!
    // Supabase publishable/anon keys are designed to ship in clients. RLS and user JWTs enforce access.
    fileprivate static let publishableKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inptc2t0eGRva3J1dGhhaW9vb2ZiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODg1MjYyNTQsImV4cCI6MjEwNDEwMjI1NH0.6CQRbDzwjkhmxKBcP8cCeWfDG7jztti4Ca6taLPvAuk"

    static func interpret(_ input: String) async throws -> AgentDirective {
        let token = try await SupabaseAnonymousSession.shared.accessToken()
        let idempotencyKey = UUID().uuidString
        let body = AgentRequest(
            schemaVersion: 1,
            input: input,
            idempotencyKey: idempotencyKey,
            timezone: TimeZone.current.identifier,
            locale: Locale.current.identifier,
            referenceDate: ISO8601DateFormatter().string(from: .now)
        )
        let encoded = try JSONEncoder().encode(body)

        for attempt in 0..<2 {
            var request = URLRequest(url: supabaseURL.appending(path: "functions/v1/agent"), timeoutInterval: 35)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(publishableKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = encoded
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
                if http.statusCode == 200 {
                    let payload = try JSONDecoder().decode(AgentResponse.self, from: data)
                    guard let call = payload.call else { throw ClientError.invalidResponse }
                    return AgentDirective(name: call.name, arguments: call.arguments, model: payload.model ?? "DeepSeek")
                }
                if attempt == 0, http.statusCode == 429 || http.statusCode >= 500 {
                    try await Task.sleep(for: .milliseconds(850))
                    continue
                }
                let payload = try? JSONDecoder().decode(APIErrorPayload.self, from: data)
                throw ClientError.server(payload?.message ?? payload?.error ?? "Lamp AI 服务暂时不可用")
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

    static func planDay(_ body: AgentPlanDayRequest, expectedStateVersion: Int = 0) async throws -> AgentPlanDayResponse {
        let configuredURL = ProcessInfo.processInfo.environment["LAMP_AGENT_CORE_URL"]
            .flatMap(URL.init(string:))
        let endpoint = configuredURL ?? supabaseURL.appending(path: "functions/v1/proposals/plan-day")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = configuredURL == nil
            ? try encoder.encode(V2CreateRequest(expectedStateVersion: expectedStateVersion, request: body))
            : try encoder.encode(body)

        for attempt in 0..<2 {
            var request = URLRequest(url: endpoint, timeoutInterval: 35)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if configuredURL == nil {
                let token = try await SupabaseAnonymousSession.shared.accessToken()
                request.setValue(publishableKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = encoded
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
                if http.statusCode == 200 {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let payload = try decoder.decode(AgentPlanDayResponse.self, from: data)
                    guard payload.schemaVersion == (configuredURL == nil ? 2 : 1),
                          payload.requestId == body.requestId,
                          payload.sourceFingerprint == body.sourceFingerprint,
                          payload.commitRequired else {
                        throw ClientError.invalidResponse
                    }
                    return payload
                }
                if attempt == 0, http.statusCode == 429 || http.statusCode >= 500 {
                    try await Task.sleep(for: .milliseconds(850))
                    continue
                }
                let payload = try? JSONDecoder().decode(APIErrorPayload.self, from: data)
                throw ClientError.server(payload?.message ?? payload?.error ?? "规划服务暂时不可用")
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

    static func replanIncomplete(_ body: AgentIncompleteReplanRequest, expectedStateVersion: Int = 0) async throws -> AgentIncompleteReplanResponse {
        let configuredURL = ProcessInfo.processInfo.environment["LAMP_AGENT_CORE_REPLAN_URL"]
            .flatMap(URL.init(string:))
        let endpoint = configuredURL ?? supabaseURL.appending(path: "functions/v1/proposals/replan-incomplete")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = configuredURL == nil
            ? try encoder.encode(V2CreateRequest(expectedStateVersion: expectedStateVersion, request: body))
            : try encoder.encode(body)

        for attempt in 0..<2 {
            var request = URLRequest(url: endpoint, timeoutInterval: 35)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if configuredURL == nil {
                let token = try await SupabaseAnonymousSession.shared.accessToken()
                request.setValue(publishableKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = encoded
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
                if http.statusCode == 200 {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let payload = try decoder.decode(AgentIncompleteReplanResponse.self, from: data)
                    guard payload.schemaVersion == (configuredURL == nil ? 2 : 1),
                          payload.eventId == body.eventId,
                          payload.sourceFingerprint == body.sourceFingerprint,
                          payload.commitRequired else {
                        throw ClientError.invalidResponse
                    }
                    return payload
                }
                if attempt == 0, http.statusCode == 429 || http.statusCode >= 500 {
                    try await Task.sleep(for: .milliseconds(850))
                    continue
                }
                let payload = try? JSONDecoder().decode(APIErrorPayload.self, from: data)
                throw ClientError.server(payload?.message ?? payload?.error ?? "重排服务暂时不可用")
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

    static func replanLanguage(_ body: AgentLanguageReplanRequest, expectedStateVersion: Int = 0) async throws -> AgentLanguageReplanResponse {
        let configuredURL = ProcessInfo.processInfo.environment["LAMP_AGENT_CORE_LANGUAGE_URL"]
            .flatMap(URL.init(string:))
        let endpoint = configuredURL ?? supabaseURL.appending(path: "functions/v1/proposals/replan-language")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = configuredURL == nil
            ? try encoder.encode(V2CreateRequest(expectedStateVersion: expectedStateVersion, request: body))
            : try encoder.encode(body)

        for attempt in 0..<2 {
            var request = URLRequest(url: endpoint, timeoutInterval: 45)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if configuredURL == nil {
                let token = try await SupabaseAnonymousSession.shared.accessToken()
                request.setValue(publishableKey, forHTTPHeaderField: "apikey")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = encoded
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
                if http.statusCode == 200 {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let payload = try decoder.decode(AgentLanguageReplanResponse.self, from: data)
                    guard payload.schemaVersion == (configuredURL == nil ? 2 : 1),
                          payload.requestId == body.requestId,
                          payload.sourceFingerprint == body.sourceFingerprint,
                          payload.commitRequired else {
                        throw ClientError.invalidResponse
                    }
                    return payload
                }
                if attempt == 0, http.statusCode == 429 || http.statusCode >= 500 {
                    try await Task.sleep(for: .milliseconds(850))
                    continue
                }
                let payload = try? JSONDecoder().decode(APIErrorPayload.self, from: data)
                throw ClientError.server(payload?.message ?? payload?.error ?? "语言重排服务暂时不可用")
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

    static func confirmProposal(
        id: UUID,
        previewHash: String,
        confirmationToken: String,
        expectedStateVersion: Int,
        idempotencyKey: UUID = UUID()
    ) async throws -> Int {
        struct Body: Encodable {
            var previewHash: String
            var confirmationToken: String
            var expectedStateVersion: Int
            var idempotencyKey: String
        }
        struct Response: Decodable { var schemaVersion: Int; var stateVersion: Int; var status: String }
        let token = try await SupabaseAnonymousSession.shared.accessToken()
        var request = URLRequest(
            url: supabaseURL.appending(path: "functions/v1/proposals/\(id.uuidString.lowercased())/confirm"),
            timeoutInterval: 35
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Body(
            previewHash: previewHash, confirmationToken: confirmationToken,
            expectedStateVersion: expectedStateVersion, idempotencyKey: idempotencyKey.uuidString.lowercased()
        ))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard http.statusCode == 200 else {
            let payload = try? JSONDecoder().decode(APIErrorPayload.self, from: data)
            throw ClientError.server(payload?.message ?? payload?.error ?? "确认失败，请刷新后重试")
        }
        let payload = try JSONDecoder().decode(Response.self, from: data)
        guard payload.schemaVersion == 2, payload.status == "applied" else { throw ClientError.invalidResponse }
        return payload.stateVersion
    }

    static func rejectProposal(id: UUID) async throws {
        let token = try await SupabaseAnonymousSession.shared.accessToken()
        var request = URLRequest(
            url: supabaseURL.appending(path: "functions/v1/proposals/\(id.uuidString.lowercased())/reject"),
            timeoutInterval: 20
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ClientError.invalidResponse }
    }

    static func fetchStateVersion() async throws -> Int {
        struct Row: Decodable { var stateVersion: Int; enum CodingKeys: String, CodingKey { case stateVersion = "state_version" } }
        let token = try await SupabaseAnonymousSession.shared.accessToken()
        var request = URLRequest(
            url: supabaseURL.appending(path: "rest/v1/profiles").appending(queryItems: [
                URLQueryItem(name: "select", value: "state_version"), URLQueryItem(name: "limit", value: "1"),
            ]),
            timeoutInterval: 20
        )
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let row = try JSONDecoder().decode([Row].self, from: data).first else {
            throw ClientError.invalidResponse
        }
        return row.stateVersion
    }

    static func analyzeScheduleImage(
        _ image: ImageIngestionService.PreparedImage,
        guidance: String = "",
        referenceDate: Date = .now,
        timezone: TimeZone = .current,
        locale: Locale = .current
    ) async throws -> ImageScheduleAnalysisResponse {
        let token = try await SupabaseAnonymousSession.shared.accessToken()
        let body = ImageAnalysisRequest(
            schemaVersion: 2,
            idempotencyKey: UUID().uuidString,
            timezone: timezone.identifier,
            locale: locale.identifier,
            referenceDate: ISO8601DateFormatter().string(from: referenceDate),
            guidance: String(guidance.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_200)),
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

    private struct AgentRequest: Encodable {
        var schemaVersion: Int
        var input: String
        var idempotencyKey: String
        var timezone: String
        var locale: String
        var referenceDate: String
    }

    private struct V2CreateRequest<Request: Encodable>: Encodable {
        var expectedStateVersion: Int
        var request: Request
    }

    private struct AgentResponse: Decodable {
        struct ToolCall: Decodable {
            var name: String
            var arguments: AgentDirective.Arguments
        }
        var call: ToolCall?
        var model: String?
    }

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
        var guidance: String
        var image: ImagePayload
    }

    private struct APIErrorPayload: Decodable {
        var error: String?
        var message: String?
    }

    enum ClientError: LocalizedError {
        case invalidResponse
        case network
        case server(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "服务器返回了无法读取的结果"
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
    private var pendingAppleSession: StoredSession?

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

    func signInWithApple(identityToken: String, nonce: String) async throws -> (accessToken: String, userID: UUID?) {
        var components = URLComponents(url: projectURL.appending(path: "auth/v1/token"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "id_token")]
        var request = URLRequest(url: components.url!, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "provider": "apple", "id_token": identityToken, "nonce": nonce,
        ])
        let session = try await performAuth(request)
        pendingAppleSession = session
        return (session.accessToken, session.userID)
    }

    func linkAppleIdentity(identityToken: String, nonce: String) async throws -> UUID? {
        let currentToken = try await accessToken()
        var components = URLComponents(url: projectURL.appending(path: "auth/v1/token"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "id_token")]
        var request = URLRequest(url: components.url!, timeoutInterval: 25)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(currentToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "provider": "apple", "id_token": identityToken, "nonce": nonce, "link_identity": true,
        ])
        let session = try await performAuth(request)
        save(session)
        return session.userID
    }

    func activatePendingAppleSession() {
        guard let session = pendingAppleSession else { return }
        pendingAppleSession = nil
        save(session)
    }

    func signOut() {
        cached = nil
        pendingAppleSession = nil
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ] as CFDictionary)
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
            expiresAt: Date.now.addingTimeInterval(TimeInterval(payload.expiresIn)),
            userID: payload.user?.id
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
        var userID: UUID?
    }

    private struct AuthResponse: Decodable {
        var accessToken: String
        var refreshToken: String
        var expiresIn: Int
        var user: User?

        struct User: Decodable { var id: UUID }

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

enum SyncTransportFailure: Error {
    case conflict
    case unauthorized
    case unavailable
    case invalidResponse
}

@MainActor
final class SupabaseSyncTransport: SyncTransport {
    func push(_ mutations: [LocalOutboxMutation]) async throws {
        guard let deviceID = mutations.first?.deviceID,
              mutations.allSatisfy({ $0.deviceID == deviceID }) else { return }
        let changes: [[String: Any]] = try mutations.map { item in
            var change: [String: Any] = [
                "entityType": item.entityType,
                "entityId": item.entityID.uuidString.lowercased(),
                "entityVersion": item.entityVersion,
                "operation": item.operation,
                "clientMutationId": item.clientMutationID.uuidString.lowercased(),
                "contentHash": item.contentHash,
            ]
            if let payload = item.payload {
                change["payload"] = try JSONSerialization.jsonObject(with: payload)
            } else {
                change["payload"] = NSNull()
            }
            return change
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "p_device_id": deviceID.uuidString.lowercased(),
            "p_changes": changes,
        ])
        _ = try await rpc("push_sync_batch", body: body)
    }

    func pull(after cursor: Int64, limit: Int) async throws -> [RemoteSyncChange] {
        let body = try JSONSerialization.data(withJSONObject: [
            "p_after_cursor": max(0, cursor), "p_limit": min(500, max(1, limit)),
        ])
        let data = try await rpc("pull_sync_changes", body: body)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SyncTransportFailure.invalidResponse
        }
        return try rows.map { row in
            guard let cursor = (row["cursor"] as? NSNumber)?.int64Value,
                  let entityType = row["entity_type"] as? String,
                  let entityID = UUID(uuidString: row["entity_id"] as? String ?? ""),
                  let entityVersion = (row["entity_version"] as? NSNumber)?.intValue,
                  let operation = row["operation"] as? String,
                  let mutationID = UUID(uuidString: row["client_mutation_id"] as? String ?? "") else {
                throw SyncTransportFailure.invalidResponse
            }
            let payloadObject = row["payload"]
            let payload = payloadObject == nil || payloadObject is NSNull
                ? nil
                : try JSONSerialization.data(withJSONObject: payloadObject!)
            return RemoteSyncChange(
                cursor: cursor, entityType: entityType, entityID: entityID,
                entityVersion: entityVersion, operation: operation,
                payload: payload, clientMutationID: mutationID
            )
        }
    }

    private func rpc(_ name: String, body: Data) async throws -> Data {
        let token = try await SupabaseAnonymousSession.shared.accessToken()
        var request = URLRequest(
            url: AgentAPIClient.supabaseURL.appending(path: "rest/v1/rpc/\(name)"),
            timeoutInterval: 25
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AgentAPIClient.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncTransportFailure.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw SyncTransportFailure.unauthorized }
        if http.statusCode == 409 || String(data: data, encoding: .utf8)?.contains("stale_state") == true {
            throw SyncTransportFailure.conflict
        }
        guard (200..<300).contains(http.statusCode) else { throw SyncTransportFailure.unavailable }
        return data
    }
}

@MainActor
final class AccountService: NSObject, ObservableObject {
    static let shared = AccountService()

    @Published private(set) var isAppleLinked = false
    @Published private(set) var statusMessage = "当前使用安全匿名账户"
    private var authorizationContinuation: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?
    private var rawNonce: String?

    func upgradeAnonymousToApple() async throws {
        let sourceToken = try await SupabaseAnonymousSession.shared.accessToken()
        let nonce = randomNonce()
        rawNonce = nonce
        let credential = try await requestAppleCredential(nonce: nonce)
        guard let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8) else {
            throw AgentAPIClient.ClientError.invalidResponse
        }
        do {
            _ = try await SupabaseAnonymousSession.shared.linkAppleIdentity(
                identityToken: identityToken, nonce: nonce
            )
            isAppleLinked = true
            statusMessage = "已使用 Apple 登录，账户标识保持不变"
            return
        } catch {
            // If the Apple identity already belongs to a separate account, the server-side
            // migration below is the only allowed fallback; clients never rewrite user_id.
        }
        let target = try await SupabaseAnonymousSession.shared.signInWithApple(identityToken: identityToken, nonce: nonce)
        var request = URLRequest(
            url: AgentAPIClient.supabaseURL.appending(path: "functions/v1/account/upgrade"), timeoutInterval: 40
        )
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AgentAPIClient.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(target.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Bearer \(sourceToken)", forHTTPHeaderField: "X-Source-Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AgentAPIClient.ClientError.server("Apple 账户升级未完成，匿名数据保持不变")
        }
        await SupabaseAnonymousSession.shared.activatePendingAppleSession()
        isAppleLinked = true
        statusMessage = "已使用 Apple 登录并保留原有数据"
    }

    func exportCloudData() async throws -> URL {
        let data = try await accountRequest(operation: "export", body: Data("{}".utf8))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Lamp-cloud-export.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    func deleteAccount() async throws {
        _ = try await accountRequest(
            operation: "delete",
            body: try JSONSerialization.data(withJSONObject: ["confirmation": "DELETE"])
        )
        await SupabaseAnonymousSession.shared.signOut()
        isAppleLinked = false
        statusMessage = "账户及云端数据已删除"
    }

    func signOut() async {
        await SupabaseAnonymousSession.shared.signOut()
        isAppleLinked = false
        statusMessage = "已退出；下次操作会创建新的匿名账户"
    }

    private func accountRequest(operation: String, body: Data) async throws -> Data {
        let token = try await SupabaseAnonymousSession.shared.accessToken()
        var request = URLRequest(
            url: AgentAPIClient.supabaseURL.appending(path: "functions/v1/account/\(operation)"), timeoutInterval: 40
        )
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AgentAPIClient.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AgentAPIClient.ClientError.server("账户操作未完成")
        }
        return data
    }

    private func requestAppleCredential(nonce: String) async throws -> ASAuthorizationAppleIDCredential {
        try await withCheckedThrowingContinuation { continuation in
            authorizationContinuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    private func randomNonce() -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}

extension AccountService: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        Task { @MainActor in
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                authorizationContinuation?.resume(throwing: AgentAPIClient.ClientError.invalidResponse)
                authorizationContinuation = nil
                return
            }
            authorizationContinuation?.resume(returning: credential)
            authorizationContinuation = nil
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        Task { @MainActor in
            authorizationContinuation?.resume(throwing: error)
            authorizationContinuation = nil
        }
    }

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
