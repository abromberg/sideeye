import Foundation

/// What's left to spend on OpenRouter: the account's balance or the key's own spending limit, whichever is lower.
/// Both endpoints are free, so the app checks before a session and keeps checking while it's out, to pick up again
/// on its own once credit is added.
public enum Credit {
    public static let keyEndpoint = URL(string: "https://openrouter.ai/api/v1/key")!
    public static let creditsEndpoint = URL(string: "https://openrouter.ai/api/v1/credits")!
    public static let addCreditPage = URL(string: "https://openrouter.ai/settings/credits")!

    /// Dollars left, or nil if neither endpoint answered. `/credits` is documented as management-key only but answers
    /// ordinary keys too; if that stops, the key's limit is all there is to go on.
    public static func remaining(apiKey: String?, session: URLSession = .shared) async -> Double? {
        guard let apiKey, !apiKey.isEmpty else { return nil }
        async let key = get(keyEndpoint, apiKey: apiKey, session: session).flatMap(keyRemaining)
        async let account = get(creditsEndpoint, apiKey: apiKey, session: session).flatMap(accountRemaining)
        return [await key, await account].compactMap { $0 }.min()
    }

    /// `limit_remaining` from `/key`; nil when the key has no limit of its own.
    static func keyRemaining(_ data: Data) -> Double? {
        struct Body: Decodable {
            struct Key: Decodable { var limit_remaining: Double? }
            var data: Key
        }
        return (try? JSONDecoder().decode(Body.self, from: data))?.data.limit_remaining
    }

    /// Credits bought less credits used, from `/credits`.
    static func accountRemaining(_ data: Data) -> Double? {
        struct Body: Decodable {
            struct Account: Decodable { var total_credits: Double; var total_usage: Double }
            var data: Account
        }
        return (try? JSONDecoder().decode(Body.self, from: data)).map { $0.data.total_credits - $0.data.total_usage }
    }

    private static func get(_ url: URL, apiKey: String, session: URLSession) async -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await session.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
