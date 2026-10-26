//
//  DiagnosticsReport.swift
//  ClaudeUsageWidget
//

import Foundation

/// Builds the sanitized diagnostics text copied from Settings (FR-7).
///
/// Contains only app state: provider, file presence, timestamps, validated
/// percentages, and error categories. It never includes raw payloads, file
/// contents, prompts, tokens, or the user's home path.
nonisolated enum DiagnosticsReport {

    struct Input: Sendable {
        var appVersion: String
        var macOSVersion: String
        var providerName: String
        var providerIdentifier: String
        var folderAccessGranted: Bool
        var integrationInstalled: Bool
        var sharedStoreAvailable: Bool
        var watchingFiles: Bool
        var snapshot: UsageSnapshot?
        var lastError: UsageProviderError?
        var lastAttemptAt: Date?
        var heartbeat: IntegrationHeartbeat?
        var usageAPIEnabled = false
        var usageAPIError: UsageProviderError? = nil
        var lastUsageAPIAttemptAt: Date? = nil
    }

    static func make(_ input: Input, now: Date) -> String {
        let iso = ISO8601DateFormatter()
        func stamp(_ date: Date?) -> String { date.map { iso.string(from: $0) } ?? "never" }

        var lines = [
            "Claude Usage diagnostics",
            "Generated: \(iso.string(from: now))",
            "App version: \(input.appVersion)",
            "macOS: \(input.macOSVersion)",
            "Provider: \(input.providerName) (\(input.providerIdentifier))",
            "Folder access granted: \(input.folderAccessGranted ? "yes" : "no")",
            "Integration installed: \(input.folderAccessGranted ? (input.integrationInstalled ? "yes" : "no") : "unknown")",
            "Shared App Group store: \(input.sharedStoreAvailable ? "available" : "unavailable")",
            "File watching: \(input.watchingFiles ? "active" : "fallback polling")",
            "Last refresh attempt: \(stamp(input.lastAttemptAt))",
            "Last error: \(input.lastError.map(describe) ?? "none")",
        ]

        if let heartbeat = input.heartbeat {
            lines.append("Status line last run: \(stamp(heartbeat.invokedAt)) (result: \(heartbeat.result?.rawValue ?? "unknown"))")
            lines.append("Claude Code version: \(heartbeat.claudeCodeVersion ?? "unknown")")
        } else {
            lines.append("Status line last run: never recorded")
        }

        if input.usageAPIEnabled {
            lines.append("Usage API: enabled, last attempt \(stamp(input.lastUsageAPIAttemptAt)), last error: \(input.usageAPIError.map(describe) ?? "none")")
        } else {
            lines.append("Usage API: disabled")
        }

        if let snapshot = input.snapshot {
            let freshness = Freshness.evaluate(observedAt: snapshot.observedAt, now: now)
            lines.append("Last successful update: \(stamp(snapshot.observedAt)) (\(freshness == .stale ? "stale" : "fresh"))")
            lines.append("Snapshot schema: \(snapshot.schemaVersion), source: \(snapshot.source)")
            for limit in snapshot.orderedLimits {
                let pct = limit.usedPercentage.map { String(format: "%.2f%%", $0) } ?? "not reported"
                lines.append("  - \(limit.id) [\(limit.kind.rawValue)]: \(pct), resets \(stamp(limit.resetsAt))")
            }
        } else {
            lines.append("Last successful update: none")
        }
        return lines.joined(separator: "\n")
    }

    private static func describe(_ error: UsageProviderError) -> String {
        switch error {
        case .malformedPayload: "malformedPayload"
        case .unsupportedSchema(let version): "unsupportedSchema(\(version))"
        case .unexpectedResponse(let status): "unexpectedResponse(\(status))"
        default: String(describing: error)
        }
    }
}
