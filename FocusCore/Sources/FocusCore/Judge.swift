import Foundation

public struct JudgeResult: Sendable, Equatable {
    public var onTask: Double
    public var category: String?
    public var model: String?
    public var cost: Double?

    public init(onTask: Double, category: String?, model: String? = nil, cost: Double? = nil) {
        self.onTask = onTask
        self.category = category
        self.model = model
        self.cost = cost
    }
}

/// Anything that can score a state string. Jev is the default; swap by conforming.
public protocol Judge: Sendable {
    func judge(state: String) async throws -> JudgeResult
}

public enum OpenRouterError: Error, LocalizedError, Equatable {
    case missingKey
    case http(Int, String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: "No OpenRouter API key set."
        case .http(401, _): "OpenRouter rejected the API key (401)."
        case .http(402, _): "OpenRouter account is out of credit (402)."
        case .http(429, _): "OpenRouter rate limited the request (429)."
        case let .http(code, body): "OpenRouter HTTP \(code): \(body.prefix(200))"
        case let .badResponse(why): "Unexpected OpenRouter response: \(why)"
        }
    }
}

/// Jev via OpenRouter's Decisions API (`/api/v1/systemone`). Not chat-completions.
public struct JevJudge: Judge {
    public static let endpoint = URL(string: "https://openrouter.ai/api/v1/systemone")!
    public static let categories: [(String, String)] = [
        ("task work", "Directly working on the stated task"),
        ("communication", "Email, chat, messaging, calls"),
        ("reference/research", "Reading docs, searching, looking things up"),
        ("entertainment", "Video, games, music, streaming for fun"),
        ("social media", "Feeds like X, Instagram, Reddit, LinkedIn, TikTok"),
        ("news", "News sites and news aggregators"),
        ("shopping", "Browsing or buying products"),
        ("other", "Anything else"),
    ]

    /// Tested 2026-09-27 on hand-labeled contexts. "Plausibly serving" overlapped on/off (0.47 vs 0.49). Asking whether
    /// the content is "directly related" separated them, but terse tasks made of names failed: for the task
    /// "Alex K / Openevidence project", the OpenHealth (OE Consumer) doc scored 0.47 and a DM with Alex Kayajan 0.27.
    /// Saying the task may be a name, project or abbreviation lifted those to 0.92 and 0.72; across 24 labeled contexts
    /// nothing is confidently wrong at Balanced (lowest on 0.52, highest off 0.52 — both "unsure", which escalates).
    public static let onTaskInstructions = "Is what the user is looking at right now directly related to their stated TASK? The task may be terse: a person's name, a project name, or an abbreviation; count content involving those people or that project as related. Judge by the document, page, or conversation shown, not by the app. Answer no for unrelated content even inside a work app (notes app, editor, terminal)."

    public var model: String
    public var apiKey: @Sendable () -> String?
    public var session: URLSession
    public var record: CallRecorder?

    public init(model: String = "jev-latest", session: URLSession = .shared, record: CallRecorder? = nil,
                apiKey: @escaping @Sendable () -> String?) {
        self.model = model
        self.session = session
        self.record = record
        self.apiKey = apiKey
    }

    public func judge(state: String) async throws -> JudgeResult {
        let data = try await OpenRouter.post(Self.endpoint, body: Self.requestBody(model: model, state: state), timeout: 15,
                                             apiKey: apiKey(), session: session, kind: "judge", model: model, record: record)
        return try Self.parse(data)
    }

    public static func requestBody(model: String, state: String) throws -> Data {
        let criteria = Dictionary(uniqueKeysWithValues: categories)
        let body: [String: Any] = [
            "model": model,
            "state": state,
            // Zero-data-retention providers only (TypeSafe, Jev's sole provider, is one; this makes it explicit).
            "provider": ["zdr": true],
            "questions": [
                "on_task": [
                    "type": "noul",
                    "instructions": onTaskInstructions,
                ],
                "category": [
                    "type": "choice",
                    "instructions": "What kind of activity is this?",
                    "criteria": criteria,
                ],
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    public static func parse(_ data: Data) throws -> JudgeResult {
        struct Answer: Decodable {
            var noul: Double?
            var choice: String?
        }
        struct Usage: Decodable { var cost: Double? }
        struct Response: Decodable {
            var model: String?
            var answers: [String: Answer]
            var usage: Usage?
        }
        let r: Response
        do {
            r = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw OpenRouterError.badResponse(String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let p = r.answers["on_task"]?.noul else {
            throw OpenRouterError.badResponse("missing answers.on_task.noul")
        }
        return JudgeResult(onTask: p, category: r.answers["category"]?.choice, model: r.model, cost: r.usage?.cost)
    }
}
