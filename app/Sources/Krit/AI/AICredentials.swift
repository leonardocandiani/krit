import Foundation
import Security

/// Stores and uses the user's Claude *subscription* token: the long-lived OAuth
/// token they generate with `claude setup-token` (an `sk-ant-oat…` value). KRIT's
/// cloud AI tier authenticates with it as `Authorization: Bearer` plus the
/// `anthropic-beta: oauth-2025-04-20` header, so usage bills against the user's
/// Claude subscription, never a paid per-token API key.
///
/// The token lives in the Keychain (encrypted at rest, this-device-only, never
/// synced to iCloud). It is never written to disk in the clear and never logged.
enum AICredentials {

    private static let service = "com.krit.app.anthropic"
    private static let account = "subscription-token"

    /// Whether a subscription token is stored.
    static var hasToken: Bool { token != nil }

    /// The stored token, or nil. Read from the Keychain.
    static var token: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Store (replacing any existing) the token in the Keychain. An empty value
    /// removes it. Returns true on success.
    @discardableResult
    static func store(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return remove() }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Masked tail for display (never the whole token).
    static var maskedSuffix: String? {
        guard let token else { return nil }
        return token.count >= 4 ? "••••" + token.suffix(4) : "••••"
    }

    enum ValidationResult {
        case ok
        case invalid
        case rateLimited
        case network(String)
    }

    /// User-Agent for subscription (OAuth) requests. Anthropic routes OAuth
    /// traffic that lacks a `claude-cli/...` agent into an aggressively
    /// rate-limited bucket, so every subscription request sends this.
    static let userAgent = "claude-cli/1.0 (external; KRIT)"

    /// The literal system prefix the OAuth subscription path requires on
    /// non-Haiku models (a request whose system field does not begin with it
    /// returns HTTP 400). Sent on every subscription request, Haiku included.
    static let claudeCodeSystemPrefix = "You are Claude Code, Anthropic's official CLI for Claude."

    /// Confirm the stored token works using the SAME subscription auth path the
    /// features use: a minimal POST to /v1/messages. The subscription (OAuth)
    /// token is inference-only and is rejected on /v1/models, so validation must
    /// hit the Messages API. Routed through Haiku (exempt from the system-prompt
    /// enforcement) with the Claude Code prefix sent anyway, and no tools.
    static func validate() async -> ValidationResult {
        guard let token else { return .invalid }
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            return .network("bad URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let body: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 1,
            "system": claudeCodeSystemPrefix,
            "messages": [["role": "user", "content": "ping"]],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .network("no response") }
            switch http.statusCode {
            case 200:        return .ok
            case 401, 403:   return .invalid
            case 429:        return .rateLimited
            default:         return .network("HTTP \(http.statusCode)")
            }
        } catch {
            return .network(error.localizedDescription)
        }
    }
}
