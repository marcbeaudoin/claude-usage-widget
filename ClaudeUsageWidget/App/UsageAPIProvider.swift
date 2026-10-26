//
//  UsageAPIProvider.swift
//  ClaudeUsageWidget
//
//  App only — the widget extension never touches the network or the Keychain.
//

import Foundation
import Security

/// Fetches account-wide usage from Anthropic's OAuth usage endpoint.
///
/// Unlike the status line, this covers every client signed in to the same
/// account (Claude Code in a terminal, Claude in Xcode, claude.ai), because
/// the server reports the account's quotas directly.
///
/// The endpoint is **unofficial and undocumented**; it is what Claude Code's
/// own `/usage` command calls. It is used only when the user opts in
/// (Settings → Claude usage API).
///
/// Security:
/// - The access token is read from the Claude Code login stored in the
///   Keychain (macOS asks the user the first time) and is kept in memory only.
/// - It is sent only to `api.anthropic.com` over HTTPS; redirects are refused
///   so it can never be forwarded to another host.
/// - Tokens are never refreshed, written, logged, or included in errors.
///   Claude Code renews its own token when it is used.
actor UsageAPIProvider: UsageProvider {
    static let identifierValue = "usage-api"
    static let displayNameValue = "Claude usage API"

    nonisolated var identifier: String { Self.identifierValue }
    nonisolated var displayName: String { Self.displayNameValue }

    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"

    private let session: URLSession
    /// Token reused between polls so the Keychain is not read every time.
    private var cachedCredentials: ClaudeCredentials?

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: RefuseRedirectsDelegate(), delegateQueue: nil)
    }

    /// Drops the in-memory token (used when the user turns the feature off).
    func forgetCredentials() {
        cachedCredentials = nil
    }

    func fetchUsage() async throws(UsageProviderError) -> UsageSnapshot {
        let now = Date.now
        if let cached = cachedCredentials, !cached.isExpired(now: now) {
            do {
                return try await request(with: cached)
            } catch .authenticationRequired {
                // Claude Code may have renewed the token since it was cached; re-read once.
                cachedCredentials = nil
            }
        }
        let credentials = try ClaudeCredentialsReader.load(now: now)
        cachedCredentials = credentials
        do {
            return try await request(with: credentials)
        } catch .authenticationRequired {
            cachedCredentials = nil
            throw .authenticationRequired
        }
    }

    private func request(with credentials: ClaudeCredentials) async throws(UsageProviderError) -> UsageSnapshot {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw .networkUnavailable
        }
        guard let http = response as? HTTPURLResponse else {
            throw .networkUnavailable
        }
        switch http.statusCode {
        case 200:
            return try UsageAPIResponseParser.parse(data, observedAt: .now)
        case 401, 403:
            throw .authenticationRequired
        case 429:
            throw .rateLimited
        default:
            throw .unexpectedResponse(status: http.statusCode)
        }
    }
}

/// Refuses every redirect so the bearer token never leaves `api.anthropic.com`.
/// (Completion-handler form: the async variant crashes the Swift 6.4 compiler.)
private nonisolated final class RefuseRedirectsDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

// MARK: - Response parsing

/// Converts the usage endpoint's JSON into a validated `UsageSnapshot`.
///
/// Observed shape (unofficial, may change):
/// ```json
/// { "five_hour":        { "utilization": 24.0, "resets_at": "2026-10-25T23:00:00.123456+00:00" },
///   "seven_day":        { "utilization": 41.0, "resets_at": "…" },
///   "seven_day_opus":   null,
///   "seven_day_sonnet": { "utilization": 12.0, "resets_at": "…" },
///   "extra_usage":      { … } }
/// ```
/// `utilization` is a percentage (0–100). Unknown keys are ignored; a window
/// with a missing or out-of-range value is reported as "not available",
/// never estimated (same rule as the status-line script).
nonisolated enum UsageAPIResponseParser {

    static func parse(_ data: Data, observedAt: Date) throws(UsageProviderError) -> UsageSnapshot {
        let raw: RawResponse
        do {
            raw = try JSONDecoder().decode(RawResponse.self, from: data)
        } catch {
            throw .malformedPayload(reason: "The usage service returned an unexpected format.")
        }

        // Session and weekly are always listed (as unavailable if missing);
        // model-specific weekly windows only when reported.
        var limits = [
            limit(id: "session", title: "Current session", kind: .fiveHour, raw.fiveHour),
            limit(id: "weekly", title: "Weekly limit", kind: .sevenDay, raw.sevenDay),
        ]
        for (id, title, window) in [
            ("weeklySonnet", "Weekly · Sonnet", raw.sevenDaySonnet),
            ("weeklyOpus", "Weekly · Opus", raw.sevenDayOpus),
        ] {
            let modelLimit = limit(id: id, title: title, kind: .modelSpecific, window)
            if modelLimit.availability == .reported { limits.append(modelLimit) }
        }

        guard limits.contains(where: { $0.availability == .reported }) else {
            throw .unsupportedUsageField
        }
        return UsageSnapshot(observedAt: observedAt, source: UsageSource.usageAPI, limits: limits)
    }

    /// Parses `resets_at`, which carries microseconds (more digits than
    /// `ISO8601DateFormatter` accepts), by retrying without the fraction.
    static func parseResetTime(_ string: String?) -> Date? {
        guard let string else { return nil }
        if let date = UsageSnapshotParser.parseTimestamp(string) { return date }
        let withoutFraction = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return UsageSnapshotParser.parseTimestamp(withoutFraction)
    }

    private static func limit(id: String, title: String, kind: UsageWindowKind, _ window: RawWindow?) -> UsageLimit {
        guard let utilization = window?.utilization,
              UsageSnapshotParser.isValidPercentage(utilization, kind: kind) else {
            return UsageLimit(id: id, title: title, kind: kind, usedPercentage: nil, resetsAt: nil)
        }
        return UsageLimit(id: id, title: title, kind: kind, usedPercentage: utilization, resetsAt: parseResetTime(window?.resetsAt))
    }

    private struct RawResponse: Decodable {
        let fiveHour: RawWindow?
        let sevenDay: RawWindow?
        let sevenDayOpus: RawWindow?
        let sevenDaySonnet: RawWindow?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
        }

        // Tolerate a window of an unexpected type instead of rejecting the whole response.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fiveHour = try? container.decodeIfPresent(RawWindow.self, forKey: .fiveHour)
            sevenDay = try? container.decodeIfPresent(RawWindow.self, forKey: .sevenDay)
            sevenDayOpus = try? container.decodeIfPresent(RawWindow.self, forKey: .sevenDayOpus)
            sevenDaySonnet = try? container.decodeIfPresent(RawWindow.self, forKey: .sevenDaySonnet)
        }
    }

    private struct RawWindow: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
}

// MARK: - Keychain

/// An OAuth access token from a Claude Code login. Never persisted or logged.
nonisolated struct ClaudeCredentials: Sendable {
    let accessToken: String
    let expiresAt: Date?

    /// Treats a token expiring within a minute as already expired.
    func isExpired(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(60)
    }

    /// Extracts the token from the JSON Claude Code stores in the Keychain:
    /// `{"claudeAiOauth": {"accessToken": "…", "expiresAt": <epoch ms>, …}}`.
    /// Only the access token and its expiry are kept.
    static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return nil
        }
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return ClaudeCredentials(accessToken: token, expiresAt: expiresAt)
    }
}

/// Reads Claude Code logins from the login Keychain.
///
/// Claude Code stores its login as a generic password named
/// `Claude Code-credentials`. A Claude Code instance using a custom config
/// directory — such as Claude in Xcode — uses `Claude Code-credentials-<hash>`.
/// All of them belong to the same account, so the one with the latest
/// expiry is used.
nonisolated enum ClaudeCredentialsReader {
    static let servicePrefix = "Claude Code-credentials"

    static func load(now: Date) throws(UsageProviderError) -> ClaudeCredentials {
        var found: [ClaudeCredentials] = []
        for service in candidateServices() {
            if let credentials = try read(service: service) {
                found.append(credentials)
            }
        }
        guard !found.isEmpty else { throw .credentialsNotFound }
        let valid = found.filter { !$0.isExpired(now: now) }
        guard let best = valid.max(by: { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }) else {
            throw .authenticationRequired
        }
        return best
    }

    /// Service names of Claude Code logins. Listing attributes does not
    /// expose secrets and does not prompt the user.
    private static func candidateServices() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        var services = [servicePrefix]
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let items = result as? [[String: Any]] {
            let others = items
                .compactMap { $0[kSecAttrService as String] as? String }
                .filter { $0.hasPrefix(servicePrefix + "-") }
            services += Set(others).sorted()
        }
        return services
    }

    /// Reads one login. macOS shows its own consent prompt the first time.
    private static func read(service: String) throws(UsageProviderError) -> ClaudeCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return (result as? Data).flatMap(ClaudeCredentials.parse)
        case errSecItemNotFound:
            return nil
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw .keychainAccessDenied
        default:
            return nil
        }
    }
}
