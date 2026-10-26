//
//  UsageSnapshotParser.swift
//  Shared between the Claude Usage app and widget extension.
//

import Foundation

/// Decodes and validates the versioned local snapshot file (SPEC.md §5.3).
///
/// Validation happens here, at the boundary, so the rest of the app only ever
/// sees values that satisfy the documented rules. Any violation rejects the
/// whole file so the caller keeps its last known-good snapshot.
nonisolated enum UsageSnapshotParser {

    static func parse(_ data: Data) throws(UsageProviderError) -> UsageSnapshot {
        let raw: RawSnapshot
        do {
            raw = try JSONDecoder().decode(RawSnapshot.self, from: data)
        } catch {
            throw .malformedPayload(reason: "Invalid JSON or missing required fields.")
        }

        guard raw.schemaVersion == UsageSnapshot.currentSchemaVersion else {
            throw .unsupportedSchema(version: raw.schemaVersion)
        }
        guard let observedAt = parseTimestamp(raw.observedAt) else {
            throw .malformedPayload(reason: "observedAt is not an ISO 8601 timestamp with a time zone.")
        }
        guard !raw.source.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw .malformedPayload(reason: "source is empty.")
        }

        var seenIDs = Set<String>()
        var limits: [UsageLimit] = []
        for rawLimit in raw.limits {
            let limit = try validate(rawLimit)
            guard seenIDs.insert(limit.id).inserted else {
                throw .malformedPayload(reason: "Duplicate limit id.")
            }
            limits.append(limit)
        }

        return UsageSnapshot(
            schemaVersion: raw.schemaVersion,
            observedAt: observedAt,
            source: raw.source,
            sourceVersion: raw.sourceVersion,
            limits: limits
        )
    }

    /// Validates a percentage for a given kind. Returns `false` for NaN,
    /// infinity, negative values, and values above 100 (unless the kind
    /// documents over-limit values, i.e. the gateway spend limit).
    static func isValidPercentage(_ value: Double, kind: UsageWindowKind) -> Bool {
        guard value.isFinite, value >= 0 else { return false }
        return kind.allowsOverLimit || value <= 100
    }

    /// Parses ISO 8601 timestamps that carry an explicit offset or `Z`,
    /// with or without fractional seconds.
    static func parseTimestamp(_ string: String?) -> Date? {
        guard let string else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }

    private static func validate(_ raw: RawLimit) throws(UsageProviderError) -> UsageLimit {
        guard !raw.id.isEmpty else {
            throw .malformedPayload(reason: "A limit has an empty id.")
        }
        let kind = UsageWindowKind(rawValue: raw.kind) ?? .other

        if let pct = raw.usedPercentage, !isValidPercentage(pct, kind: kind) {
            throw .malformedPayload(reason: "Limit \(raw.id) has an out-of-range percentage.")
        }

        var resetsAt: Date?
        if let rawReset = raw.resetsAt {
            guard let date = parseTimestamp(rawReset) else {
                throw .malformedPayload(reason: "Limit \(raw.id) has an invalid resetsAt timestamp.")
            }
            resetsAt = date
        }

        let availability: LimitAvailability
        switch raw.availability {
        case nil:
            availability = raw.usedPercentage == nil ? .notReported : .reported
        case "reported"?:
            guard raw.usedPercentage != nil else {
                throw .malformedPayload(reason: "Limit \(raw.id) is marked reported without a percentage.")
            }
            availability = .reported
        case "notReported"?:
            availability = .notReported
        default:
            throw .malformedPayload(reason: "Limit \(raw.id) has an unknown availability value.")
        }

        return UsageLimit(
            id: raw.id,
            title: raw.title ?? raw.id,
            kind: kind,
            // A not-reported limit never carries a value.
            usedPercentage: availability == .reported ? raw.usedPercentage : nil,
            resetsAt: availability == .reported ? resetsAt : nil,
            availability: availability
        )
    }

    // MARK: - Raw file shape (unknown fields are ignored by JSONDecoder)

    private struct RawSnapshot: Decodable {
        let schemaVersion: Int
        let observedAt: String
        let source: String
        let sourceVersion: String?
        let limits: [RawLimit]
    }

    private struct RawLimit: Decodable {
        let id: String
        let title: String?
        let kind: String
        let usedPercentage: Double?
        let resetsAt: String?
        let availability: String?
    }
}

/// Encodes snapshots in the documented file format (used by the app's shared store).
nonisolated enum UsageSnapshotEncoder {
    static func encode(_ snapshot: UsageSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }
}
