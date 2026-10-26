//
//  UsageSync.swift
//  Shared between the Claude Usage app and widget extension.
//

import Foundation

/// Outcome of one read from the provider into the shared store.
nonisolated enum UsageSyncOutcome: Equatable, Sendable {
    /// A newer valid snapshot was stored.
    case updated(UsageSnapshot)
    /// The provider returned data no newer than the stored snapshot.
    case unchanged(UsageSnapshot)
    /// The read failed. The stored snapshot (if any) was left untouched.
    case failed(UsageProviderError, lastKnownGood: UsageSnapshot?)

    /// The snapshot to display after this outcome.
    var snapshot: UsageSnapshot? {
        switch self {
        case .updated(let snapshot), .unchanged(let snapshot): snapshot
        case .failed(_, let lastKnownGood): lastKnownGood
        }
    }
}

/// Copies validated snapshots from a provider into the shared store.
///
/// The store is only written after a complete snapshot has been parsed and
/// validated, so a failed or malformed read never erases known-good data.
nonisolated struct UsageSync: Sendable {
    let provider: any UsageProvider
    let store: UsageStore

    func run() async -> UsageSyncOutcome {
        // A corrupt shared file is treated as "no stored snapshot"; it will be
        // replaced by the next valid read.
        let stored = try? store.load()

        let incoming: UsageSnapshot
        do {
            incoming = try await provider.fetchUsage()
        } catch {
            return .failed(error, lastKnownGood: stored)
        }

        guard SnapshotMergePolicy.shouldReplace(stored: stored, with: incoming) else {
            return .unchanged(stored ?? incoming)
        }
        do {
            try store.save(incoming)
        } catch {
            return .failed(.permissionDenied, lastKnownGood: stored)
        }
        return .updated(incoming)
    }
}
