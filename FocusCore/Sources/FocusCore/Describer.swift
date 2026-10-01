import Foundation

public struct Description: Sendable, Equatable {
    public var text: String
    /// The upstream provider that served the call — check it's a ZDR endpoint that took the image.
    public var provider: String?
    public var model: String?
}

/// Cheap vision model that turns a window screenshot into text for Jev. Never decides anything itself.
public struct Describer: Sendable {
    public static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    public static let prompt = "Describe in 1–2 sentences what the user is doing in this window. Be concrete: name the site/app and the main content they are looking at. Ignore tab bars, toolbars, bookmarks, and sidebars."

    public var model: String
    public var apiKey: @Sendable () -> String?
    public var session: URLSession
    public var record: CallRecorder?

    public init(model: String = "~deepseek/deepseek-flash-latest", session: URLSession = .shared, record: CallRecorder? = nil,
                apiKey: @escaping @Sendable () -> String?) {
        self.model = model
        self.session = session
        self.record = record
        self.apiKey = apiKey
    }

    public func describe(jpeg: Data) async throws -> Description {
        let data = try await OpenRouter.post(Self.endpoint, body: Self.requestBody(model: model, jpeg: jpeg), timeout: 30,
                                             apiKey: apiKey(), session: session, kind: "describe", model: model,
                                             image: jpeg, record: record)
        return try Self.parse(data)
    }

    public static func requestBody(model: String, jpeg: Data) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 200,
            // deepseek-flash reasons by default and spends the token budget before answering (finish_reason
            // "length", empty content). A one-line description needs no reasoning: faster and cheaper too.
            "reasoning": ["effort": "none"],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]],
                ],
            ]],
            // ZDR only, cheapest first. Never use :floor — it widens to non-ZDR flex endpoints.
            "provider": ["zdr": true, "sort": "price"],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    public static func parse(_ data: Data) throws -> Description {
        struct Message: Decodable { var content: String? }
        struct Choice: Decodable { var message: Message }
        struct Response: Decodable {
            var provider: String?
            var model: String?
            var choices: [Choice]
        }
        guard let r = try? JSONDecoder().decode(Response.self, from: data),
              let text = r.choices.first?.message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { throw OpenRouterError.badResponse(String(decoding: data.prefix(300), as: UTF8.self)) }
        return Description(text: text, provider: r.provider, model: r.model)
    }
}
