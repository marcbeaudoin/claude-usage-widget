//
//  UsageStore.swift
//  Shared between the Claude Usage app and widget extension.
//

import Foundation

/// Well-known locations. See README.md "Files" for the full list.
nonisolated enum SharedPaths {
    /// Info.plist key holding the App Group identifier, expanded at build time
    /// from `APP_GROUP_IDENTIFIER` in `Config/Base.xcconfig` (or `Local.xcconfig`).
    static let appGroupInfoPlistKey = "ClaudeUsageAppGroupIdentifier"

    /// App Group shared by the app and the widget extension, or `nil` if the
    /// bundle does not carry a usable value (missing, empty, or unexpanded).
    static var appGroupIdentifier: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: appGroupInfoPlistKey) as? String,
              !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }

    /// Snapshot file name inside the App Group container.
    static let sharedSnapshotFileName = "usage-snapshot.json"

    /// The user's real home directory. Inside the App Sandbox,
    /// `NSHomeDirectory()` points at the container, so read it from the
    /// password database instead.
    static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// `~/Library/Application Support/ClaudeUsage/` — written by the
    /// status-line script and installer, read (only) by the app.
    static var integrationDirectory: URL {
        realHomeDirectory.appendingPathComponent("Library/Application Support/ClaudeUsage", isDirectory: true)
    }

    /// Normalized snapshot written by the status-line script.
    static var integrationSnapshotURL: URL { integrationDirectory.appendingPathComponent("usage.json") }
    /// Heartbeat written by the status-line script on every invocation.
    static var integrationStatusURL: URL { integrationDirectory.appendingPathComponent("status.json") }
    /// Marker written by the installer.
    static var integrationMarkerURL: URL { integrationDirectory.appendingPathComponent("integration.json") }

    /// App Group container, or `nil` if it cannot be resolved.
    static func sharedContainerURL() -> URL? {
        guard let appGroupIdentifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }
}

/// Reads and writes the single versioned snapshot file in the shared container.
///
/// Every process (app, widget) reads from disk; no in-memory state is shared.
nonisolated struct UsageStore: Sendable {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Store backed by the App Group container.
    static func shared() throws(UsageProviderError) -> UsageStore {
        guard let container = SharedPaths.sharedContainerURL() else {
            throw .appGroupUnavailable
        }
        return UsageStore(fileURL: container.appendingPathComponent(SharedPaths.sharedSnapshotFileName))
    }

    /// Returns the stored snapshot, or `nil` if none has been written yet.
    func load() throws(UsageProviderError) -> UsageSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw .permissionDenied
        }
        return try UsageSnapshotParser.parse(data)
    }

    /// Atomically replaces the stored snapshot.
    func save(_ snapshot: UsageSnapshot) throws {
        let data = try UsageSnapshotEncoder.encode(snapshot)
        try AtomicFileWriter.write(data, to: fileURL)
    }
}

/// Heartbeat written by the status-line script each time Claude Code runs it.
///
/// Lets the app distinguish "Claude Code never ran the script" from
/// "Claude Code ran it but did not include subscription usage".
nonisolated struct IntegrationHeartbeat: Equatable, Sendable {
    enum Result: String, Sendable {
        /// A new snapshot was written.
        case written
        /// The payload had no usable `rate_limits` windows; nothing written.
        case noRateLimits
        /// The payload was not valid JSON; nothing written.
        case invalidInput
    }

    let invokedAt: Date
    let result: Result?
    let claudeCodeVersion: String?

    /// Parses the heartbeat file. Returns `nil` for unreadable or unknown content.
    static func parse(_ data: Data) -> IntegrationHeartbeat? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["schemaVersion"] as? Int == 1,
            let invokedAt = UsageSnapshotParser.parseTimestamp(object["invokedAt"] as? String)
        else { return nil }
        return IntegrationHeartbeat(
            invokedAt: invokedAt,
            result: (object["result"] as? String).flatMap(Result.init(rawValue:)),
            claudeCodeVersion: object["claudeCodeVersion"] as? String
        )
    }
}
