//
//  UsageFormattingTests.swift
//  ClaudeUsageWidgetTests
//

import Foundation
import Testing
@testable import ClaudeUsageWidget

struct UsageFormattingTests {

    private let enUS = Locale(identifier: "en_US")

    static let durationCases: [(TimeInterval, String)] = [
        (0, "0s"), (1, "1s"), (45, "45s"), (59.4, "1m"),
        (60, "1m"), (840, "14m"), (3_599, "59m"),
        (3_600, "1h"), (8_040, "2h 14m"),
        (86_400, "1d"), (273_600, "3d 4h"), (-5, "0s"),
    ]

    @Test(arguments: durationCases)
    func durationFormatting(interval: TimeInterval, expected: String) {
        #expect(UsageFormatting.durationText(interval) == expected)
    }

    @Test func countdownText() {
        let now = Fixture.date("2026-10-20T13:46:00Z")
        #expect(UsageFormatting.countdownText(resetsAt: Fixture.date("2026-10-20T16:00:00Z"), now: now) == "Resets in 2h 14m")
        #expect(UsageFormatting.countdownText(resetsAt: nil, now: now) == nil)
    }

    @Test func resetInPastShowsWaitingMessage() {
        let now = Fixture.date("2026-10-20T16:00:00Z")
        #expect(UsageFormatting.countdownText(resetsAt: Fixture.date("2026-10-20T15:59:00Z"), now: now)
                == "Reset time passed — waiting for updated usage data")
        #expect(UsageFormatting.countdownText(resetsAt: now, now: now, short: true) == "Awaiting updated data")
    }

    @Test func percentAndRemainingText() {
        #expect(UsageFormatting.percentText(62.4) == "62%")
        #expect(UsageFormatting.percentText(62.5) == "63%")
        let limit = UsageLimit(id: "w", title: "Weekly", kind: .sevenDay, usedPercentage: 78.4, resetsAt: nil)
        #expect(UsageFormatting.remainingText(for: limit) == "22% left")
    }

    @Test func absoluteResetUsesGivenTimeZone() {
        let instant = Fixture.date("2026-10-26T07:00:00Z")
        let utc = UsageFormatting.absoluteResetText(instant, locale: enUS, timeZone: TimeZone(identifier: "UTC")!)
        let tokyo = UsageFormatting.absoluteResetText(instant, locale: enUS, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        let la = UsageFormatting.absoluteResetText(instant, locale: enUS, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        #expect(utc.contains("7:00"))
        #expect(utc.contains("Mon"))
        #expect(tokyo.contains("4:00"))       // 16:00 JST
        #expect(la.contains("12:00"))         // midnight PDT
        #expect(la.contains("Mon"))
    }

    @Test func daylightSavingTransition() {
        // Europe/Paris leaves summer time on 2026-10-25 at 03:00 local (01:00 UTC).
        let paris = TimeZone(identifier: "Europe/Paris")!
        let before = Fixture.date("2026-10-25T00:30:00Z") // 02:30 CEST
        let after = Fixture.date("2026-10-25T01:30:00Z")  // 02:30 CET
        #expect(UsageFormatting.absoluteResetText(before, locale: enUS, timeZone: paris).contains("2:30"))
        #expect(UsageFormatting.absoluteResetText(after, locale: enUS, timeZone: paris).contains("2:30"))
        // The countdown is computed from absolute instants, so the repeated
        // local hour does not distort it.
        #expect(UsageFormatting.countdownText(resetsAt: after, now: before) == "Resets in 1h")
    }

    @Test(arguments: [
        (0.0, "Updated just now"), (59.0, "Updated just now"),
        (120.0, "Updated 2 min ago"), (3_599.0, "Updated 59 min ago"),
        (7_200.0, "Updated 2 h ago"),
    ])
    func updatedText(elapsed: TimeInterval, expected: String) {
        let observed = Fixture.date("2026-10-20T13:54:00Z")
        #expect(UsageFormatting.updatedText(observedAt: observed, now: observed.addingTimeInterval(elapsed)) == expected)
    }

    @Test func stalenessThreshold() {
        let observed = Fixture.date("2026-10-20T13:00:00Z")
        #expect(Freshness.evaluate(observedAt: observed, now: observed) == .fresh)
        #expect(Freshness.evaluate(observedAt: observed, now: observed.addingTimeInterval(15 * 60)) == .fresh)
        #expect(Freshness.evaluate(observedAt: observed, now: observed.addingTimeInterval(15 * 60 + 1)) == .stale)
        #expect(Freshness.evaluate(observedAt: observed, now: observed.addingTimeInterval(120), threshold: 60) == .stale)
        #expect(UsageFormatting.staleText(observedAt: observed, now: observed.addingTimeInterval(32 * 60))
                == "Last updated 32 minutes ago. Open Claude Code or refresh the source.")
    }

    @Test(arguments: [(0.0, UsageSeverity.normal), (69.9, .normal), (70.0, .warning), (89.9, .warning), (90.0, .critical), (120.0, .critical)])
    func severityThresholds(pct: Double, expected: UsageSeverity) {
        #expect(UsageSeverity.forPercentage(pct) == expected)
    }

    @Test func accessibilityLabels() {
        let now = Fixture.date("2026-10-20T13:00:00Z")
        let utc = TimeZone(identifier: "UTC")!
        let weekly = UsageLimit(id: "weekly", title: "Weekly limit", kind: .sevenDay, usedPercentage: 78, resetsAt: Fixture.date("2026-10-26T09:00:00Z"))
        let label = UsageFormatting.accessibilityLabel(for: weekly, now: now, locale: enUS, timeZone: utc)
        #expect(label.hasPrefix("Weekly limit, 78 percent used, 22 percent remaining, high usage, resets Mon"))

        let missing = UsageLimit(id: "session", title: "Current session", kind: .fiveHour, usedPercentage: nil, resetsAt: nil)
        #expect(UsageFormatting.accessibilityLabel(for: missing, now: now) == "Current session, Not available from this data source")
    }
}
