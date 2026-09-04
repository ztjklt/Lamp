import Foundation

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
    static func interpret(_ input: String) async throws -> AgentDirective {
        #if DEBUG
        let endpoint = URL(string: "http://127.0.0.1:8787/v1/interpret")!
        #else
        throw ClientError.productionEndpointNotConfigured
        #endif
        var request = URLRequest(url: endpoint, timeoutInterval: 22)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(input: input))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ClientError.invalidResponse
        }
        return try JSONDecoder().decode(AgentDirective.self, from: data)
    }

    private struct RequestBody: Encodable { var input: String }
    enum ClientError: Error { case invalidResponse, productionEndpointNotConfigured }
}

