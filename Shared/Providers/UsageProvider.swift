//
//  UsageProvider.swift
//  Shared between the Claude Usage app and widget extension.
//

import Foundation

/// A source of validated usage snapshots. The UI never depends on a concrete provider.
nonisolated protocol UsageProvider: Sendable {
    /// Stable identifier shown in diagnostics.
    var identifier: String { get }
    /// Human-readable name shown in the UI.
    var displayName: String { get }
    /// Returns a validated snapshot or a non-sensitive error category.
    func fetchUsage() async throws(UsageProviderError) -> UsageSnapshot
}

/// Reads the normalized snapshot written by the Claude Code status-line script.
///
/// The script (Integration/claude-usage-statusline.sh) receives Claude Code's
/// status-line JSON on stdin, keeps only `rate_limits.five_hour`,
/// `rate_limits.seven_day` and `rate_limits.spend_limit`, and writes
/// `~/Library/Application Support/ClaudeUsage/usage.json` atomically.
nonisolated struct StatusLineFileProvider: UsageProvider {
    static let identifierValue = "status-line-file"
    static let displayNameValue = "Claude Code status line"

    var identifier: String { Self.identifierValue }
    var displayName: String { Self.displayNameValue }

    let snapshotURL: URL
    let markerURL: URL
    let statusURL: URL

    init(snapshotURL: URL, markerURL: URL, statusURL: URL? = nil) {
        self.snapshotURL = snapshotURL
        self.markerURL = markerURL
        self.statusURL = statusURL ?? snapshotURL.deletingLastPathComponent().appendingPathComponent("status.json")
    }

    /// Provider reading the standard file names inside an integration directory
    /// (normally a security-scoped URL for `~/Library/Application Support/ClaudeUsage/`).
    init(directory: URL) {
        self.init(
            snapshotURL: directory.appendingPathComponent("usage.json"),
            markerURL: directory.appendingPathComponent("integration.json"),
            statusURL: directory.appendingPathComponent("status.json")
        )
    }

    func fetchUsage() async throws(UsageProviderError) -> UsageSnapshot {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            throw fileManager.fileExists(atPath: markerURL.path) ? .sourceNotFound : .integrationNotInstalled
        }
        let data: Data
        do {
            data = try Data(contentsOf: snapshotURL)
        } catch {
            throw .permissionDenied
        }
        let snapshot = try UsageSnapshotParser.parse(data)
        guard snapshot.limits.contains(where: { $0.availability == .reported }) else {
            throw .unsupportedUsageField
        }
        return snapshot
    }
}

/// Decides whether a newly read snapshot should replace the stored one.
nonisolated enum SnapshotMergePolicy {
    /// Replace only with a snapshot that is newer (or same time but different).
    /// An older snapshot — e.g. from a second Claude Code session writing late —
    /// never overwrites newer data.
    static func shouldReplace(stored: UsageSnapshot?, with incoming: UsageSnapshot) -> Bool {
        guard let stored else { return true }
        if incoming.observedAt != stored.observedAt {
            return incoming.observedAt > stored.observedAt
        }
        return incoming != stored
    }
}
