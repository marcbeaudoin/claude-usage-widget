//
//  UsageModels.swift
//  Shared between the Claude Usage app and widget extension.
//

import Foundation

/// The quota window a limit describes.
///
/// Unknown kinds found in a snapshot file decode as `.other` so that newer
/// integrations remain readable (forward compatibility).
nonisolated enum UsageWindowKind: String, Codable, Sendable, CaseIterable {
    /// Rolling five-hour session window (`rate_limits.five_hour`).
    case fiveHour
    /// Seven-day window (`rate_limits.seven_day`).
    case sevenDay
    /// Model-specific weekly window. Not exposed by the status line today;
    /// kept so a future provider can report it.
    case modelSpecific
    /// Claude apps gateway spend limit (`rate_limits.spend_limit`).
    /// Unlike the other windows it may legitimately exceed 100%.
    case spendLimit
    /// Any other provider-reported window.
    case other

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = UsageWindowKind(rawValue: raw) ?? .other
    }

    /// Display priority (FR-1). Lower values are shown first.
    var displayPriority: Int {
        switch self {
        case .fiveHour: 0
        case .sevenDay: 1
        case .modelSpecific: 2
        case .other: 3
        case .spendLimit: 4
        }
    }

    /// Whether the source may report more than 100% for this kind.
    var allowsOverLimit: Bool { self == .spendLimit }
}

/// Whether the source reported a value for a limit.
nonisolated enum LimitAvailability: String, Codable, Sendable {
    /// The source reported a usage percentage for this limit.
    case reported
    /// The source did not report this limit in its latest payload.
    /// The UI must show "Not available from this data source", never `0%`.
    case notReported
}

/// One usage limit as reported by a provider. Values are never estimated.
nonisolated struct UsageLimit: Codable, Identifiable, Equatable, Sendable {
    /// Stable identifier, e.g. `session`, `weekly`, `spendLimit`.
    let id: String
    let title: String
    let kind: UsageWindowKind
    /// Source-reported percentage used. `nil` when not reported.
    let usedPercentage: Double?
    /// Source-reported absolute reset time. `nil` when not reported.
    let resetsAt: Date?
    let availability: LimitAvailability

    init(
        id: String,
        title: String,
        kind: UsageWindowKind,
        usedPercentage: Double?,
        resetsAt: Date?,
        availability: LimitAvailability? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
        self.availability = availability ?? (usedPercentage == nil ? .notReported : .reported)
    }

    /// `100 - usedPercentage`, clamped to `0...100`.
    var remainingPercentage: Double? {
        guard let usedPercentage else { return nil }
        return min(max(100 - usedPercentage, 0), 100)
    }

    /// Fraction for a progress bar representing usage, clamped to `0...1`.
    var progressFraction: Double? {
        guard let usedPercentage else { return nil }
        return min(max(usedPercentage / 100, 0), 1)
    }

    /// True when the source reported more than 100% used.
    var isOverLimit: Bool { (usedPercentage ?? 0) > 100 }

    /// True when the reported reset time is in the past relative to `now`.
    func resetHasPassed(now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }
}

/// A complete, validated set of usage values from one successful read.
nonisolated struct UsageSnapshot: Codable, Equatable, Sendable {
    /// Version of the local snapshot file format. See SPEC.md §5.3.
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    /// Local time at which the integration read and validated the source payload.
    let observedAt: Date
    /// Identifier of the source, e.g. `claude-code-status-line`.
    let source: String
    /// Claude Code version that produced the payload, when known.
    let sourceVersion: String?
    let limits: [UsageLimit]

    init(
        schemaVersion: Int = UsageSnapshot.currentSchemaVersion,
        observedAt: Date,
        source: String,
        sourceVersion: String? = nil,
        limits: [UsageLimit]
    ) {
        self.schemaVersion = schemaVersion
        self.observedAt = observedAt
        self.source = source
        self.sourceVersion = sourceVersion
        self.limits = limits
    }

    /// Limits sorted by display priority (FR-1), preserving source order within a kind.
    var orderedLimits: [UsageLimit] {
        limits.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.kind.displayPriority != rhs.element.kind.displayPriority {
                    return lhs.element.kind.displayPriority < rhs.element.kind.displayPriority
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    func limit(kind: UsageWindowKind) -> UsageLimit? {
        limits.first { $0.kind == kind }
    }

    /// The limit to feature in compact layouts: session if reported, else weekly,
    /// else the first reported limit.
    var primaryLimit: UsageLimit? {
        let ordered = orderedLimits
        return ordered.first { $0.kind == .fiveHour && $0.availability == .reported }
            ?? ordered.first { $0.kind == .sevenDay && $0.availability == .reported }
            ?? ordered.first { $0.availability == .reported }
    }
}

/// Known source identifiers.
nonisolated enum UsageSource {
    static let statusLine = "claude-code-status-line"
    /// Anthropic's (unofficial) OAuth usage endpoint, polled by the app when opted in.
    static let usageAPI = "claude-usage-api"
}
