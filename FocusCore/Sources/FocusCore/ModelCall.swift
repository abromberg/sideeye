import Foundation

/// One model call as sent and received. Kept only with Settings → Debug logging on (see `Store.logModelCall`).
public struct ModelCall: Sendable {
    /// "judge", "brief" or "describe".
    public var kind: String
    public var requestedModel: String
    /// The request body; a screenshot's base64 is replaced by a placeholder and kept in `image`.
    public var request: String
    public var image: Data?
    public var status: Int?
    public var response: String?
    public var error: String?
    public var latencyMs: Int
    /// The host and model that served it, and what it cost, read off the response.
    public var provider: String?
    public var model: String?
    public var cost: Double?
}

public typealias CallRecorder = @Sendable (ModelCall) -> Void

enum OpenRouter {
    /// POSTs a JSON body and returns the 200 response's body. Every call, failed ones too, goes to `record` if set.
    static func post(_ url: URL, body: Data, timeout: TimeInterval, apiKey: String?, session: URLSession,
                     kind: String, model: String, image: Data? = nil, record: CallRecorder?) async throws -> Data {
        guard let key = apiKey, !key.isEmpty else { throw OpenRouterError.missingKey }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Side Eye", forHTTPHeaderField: "X-Title")
        req.httpBody = body

        let start = Date()
        var call = ModelCall(kind: kind, requestedModel: model, request: "", image: image, latencyMs: 0)
        defer {
            if let record {
                call.latencyMs = Int(Date().timeIntervalSince(start) * 1000)
                call.request = String(decoding: body, as: UTF8.self).replacingOccurrences(
                    of: #"data:image\\?/jpeg;base64,[A-Za-z0-9+\\/=]+"#, with: "<jpeg in image>", options: .regularExpression)
                record(call)
            }
        }
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            call.status = code
            call.response = String(decoding: data, as: UTF8.self)
            struct Served: Decodable {
                struct Usage: Decodable { var cost: Double? }
                var provider: String?
                var model: String?
                var usage: Usage?
            }
            if let s = try? JSONDecoder().decode(Served.self, from: data) {
                call.provider = s.provider
                call.model = s.model
                call.cost = s.usage?.cost
            }
            guard code == 200 else { throw OpenRouterError.http(code, call.response ?? "") }
            return data
        } catch {
            call.error = call.error ?? error.localizedDescription
            throw error
        }
    }
}
