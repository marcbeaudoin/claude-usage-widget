//
//  UsageModelTests.swift
//  ClaudeUsageWidgetTests
//

import Foundation
import Testing
@testable import ClaudeUsageWidget

struct UsageModelTests {

    private func limit(_ id: String, _ kind: UsageWindowKind, _ pct: Double?, reset: Date? = nil) -> UsageLimit {
        UsageLimit(id: id, title: id, kind: kind, usedPercentage: pct, resetsAt: reset)
    }

    @Test(arguments: [
        (0.0, 100.0), (62.0, 38.0), (78.4, 21.6), (100.0, 0.0), (130.0, 0.0),
    ])
    func remainingPercentage(used: Double, remaining: Double) {
        let value = limit("a", .spendLimit, used).remainingPercentage
        #expect(abs((value ?? -1) - remaining) < 0.0001)
    }

    @Test func remainingIsNilWhenNotReported() {
        #expect(limit("a", .fiveHour, nil).remainingPercentage == nil)
        #expect(limit("a", .fiveHour, nil).progressFraction == nil)
    }

    @Test func overLimitClampsProgressButKeepsRawValue() {
        let over = limit("spend", .spendLimit, 130)
        #expect(over.isOverLimit)
        #expect(over.progressFraction == 1)
        #expect(over.usedPercentage == 130)
        #expect(!limit("a", .fiveHour, 100).isOverLimit)
    }

    @Test func availabilityDerivedFromPercentage() {
        #expect(limit("a", .fiveHour, 10).availability == .reported)
        #expect(limit("a", .fiveHour, nil).availability == .notReported)
    }

    @Test func resetInThePast() {
        let now = Fixture.date("2026-10-20T16:00:01Z")
        #expect(limit("a", .fiveHour, 10, reset: Fixture.date("2026-10-20T16:00:00Z")).resetHasPassed(now: now))
        #expect(!limit("a", .fiveHour, 10, reset: Fixture.date("2026-10-20T16:00:02Z")).resetHasPassed(now: now))
        #expect(!limit("a", .fiveHour, 10).resetHasPassed(now: now))
    }

    @Test func orderingFollowsDisplayPriorityWithStableIDs() {
        let snapshot = UsageSnapshot(
            observedAt: .now,
            source: UsageSource.statusLine,
            limits: [
                limit("spendLimit", .spendLimit, 10),
                limit("weekly", .sevenDay, 20),
                limit("opus", .modelSpecific, 30),
                limit("session", .fiveHour, 40),
                limit("sonnet", .modelSpecific, 50),
            ]
        )
        #expect(snapshot.orderedLimits.map(\.id) == ["session", "weekly", "opus", "sonnet", "spendLimit"])
    }

    @Test func primaryLimitPrefersSessionThenWeekly() {
        let both = UsageSnapshot(observedAt: .now, source: "s", limits: [limit("w", .sevenDay, 1), limit("s", .fiveHour, 2)])
        #expect(both.primaryLimit?.id == "s")

        let noSession = UsageSnapshot(observedAt: .now, source: "s", limits: [limit("s", .fiveHour, nil), limit("w", .sevenDay, 1)])
        #expect(noSession.primaryLimit?.id == "w")

        let none = UsageSnapshot(observedAt: .now, source: "s", limits: [limit("s", .fiveHour, nil)])
        #expect(none.primaryLimit == nil)
    }

    @Test func mergePolicyKeepsNewestSnapshot() {
        let older = UsageSnapshot(observedAt: Fixture.date("2026-10-20T13:00:00Z"), source: "s", limits: [limit("s", .fiveHour, 10)])
        let newer = UsageSnapshot(observedAt: Fixture.date("2026-10-20T13:05:00Z"), source: "s", limits: [limit("s", .fiveHour, 12)])
        #expect(SnapshotMergePolicy.shouldReplace(stored: nil, with: older))
        #expect(SnapshotMergePolicy.shouldReplace(stored: older, with: newer))
        #expect(!SnapshotMergePolicy.shouldReplace(stored: newer, with: older))
        #expect(!SnapshotMergePolicy.shouldReplace(stored: newer, with: newer))
    }
}
