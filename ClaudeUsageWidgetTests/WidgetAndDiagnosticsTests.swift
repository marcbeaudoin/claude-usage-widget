//
//  WidgetAndDiagnosticsTests.swift
//  ClaudeUsageWidgetTests
//

import Foundation
import Testing
@testable import ClaudeUsageWidget

struct WidgetTimelinePlannerTests {

    private let now = Fixture.date("2026-10-20T14:00:00Z")

    @Test func regularEntriesWithoutSnapshot() {
        let dates = WidgetTimelinePlanner.entryDates(now: now, snapshot: nil)
        #expect(dates.first == now)
        #expect(dates.count == 13) // now + every 15 min for 3 h
        #expect(dates.last == now.addingTimeInterval(3 * 3600))
    }

    @Test func includesResetAndStaleTransitions() {
        let reset = Fixture.date("2026-10-20T15:07:00Z")
        let snapshot = UsageSnapshot(
            observedAt: Fixture.date("2026-10-20T13:55:00Z"),
            source: UsageSource.statusLine,
            limits: [
                UsageLimit(id: "session", title: "S", kind: .fiveHour, usedPercentage: 50, resetsAt: reset),
                UsageLimit(id: "weekly", title: "W", kind: .sevenDay, usedPercentage: 50, resetsAt: Fixture.date("2026-10-26T07:00:00Z")),
            ]
        )
        let dates = WidgetTimelinePlanner.entryDates(now: now, snapshot: snapshot)
        #expect(dates.contains(reset))
        #expect(dates.contains(Fixture.date("2026-10-20T14:10:01Z"))) // observedAt + 15 min + 1 s
        #expect(!dates.contains(Fixture.date("2026-10-26T07:00:00Z")))  // beyond horizon
        #expect(dates == dates.sorted())
    }

    @Test func pastResetIsNotScheduled() {
        let snapshot = UsageSnapshot(
            observedAt: now,
            source: "s",
            limits: [UsageLimit(id: "s", title: "S", kind: .fiveHour, usedPercentage: 1, resetsAt: now.addingTimeInterval(-60))]
        )
        let dates = WidgetTimelinePlanner.entryDates(now: now, snapshot: snapshot)
        #expect(dates.allSatisfy { $0 >= now })
    }
}

struct DeepLinkTests {
    @Test func stableURLs() {
        #expect(DeepLink.open.url.absoluteString == "claudeusage://open")
        #expect(DeepLink.refresh.url.absoluteString == "claudeusage://refresh")
        #expect(DeepLink(url: URL(string: "claudeusage://refresh")!) == .refresh)
        #expect(DeepLink(url: URL(string: "CLAUDEUSAGE://OPEN")!) == .open)
        #expect(DeepLink(url: URL(string: "claudeusage://delete")!) == nil)
        #expect(DeepLink(url: URL(string: "https://open")!) == nil)
    }
}

struct DiagnosticsReportTests {

    @Test func containsStateButNoSensitiveData() {
        let snapshot = UsageSnapshot(
            observedAt: Fixture.date("2026-10-20T13:54:00Z"),
            source: UsageSource.statusLine,
            limits: [UsageLimit(id: "session", title: "Current session", kind: .fiveHour, usedPercentage: 62, resetsAt: Fixture.date("2026-10-20T16:00:00Z"))]
        )
        let input = DiagnosticsReport.Input(
            appVersion: "1.0 (1)", macOSVersion: "27.0", providerName: "Claude Code status line",
            providerIdentifier: "status-line-file", folderAccessGranted: true, integrationInstalled: true,
            sharedStoreAvailable: true, watchingFiles: true, snapshot: snapshot,
            lastError: .malformedPayload(reason: "secret-looking detail sk-ant-123"),
            lastAttemptAt: Fixture.date("2026-10-20T14:00:00Z"),
            heartbeat: IntegrationHeartbeat(invokedAt: Fixture.date("2026-10-20T13:54:00Z"), result: .written, claudeCodeVersion: "2.1.309")
        )
        let report = DiagnosticsReport.make(input, now: Fixture.date("2026-10-20T14:01:00Z"))
        #expect(report.contains("Provider: Claude Code status line (status-line-file)"))
        #expect(report.contains("session [fiveHour]: 62.00%"))
        #expect(report.contains("Last error: malformedPayload"))
        #expect(report.contains("Claude Code version: 2.1.309"))
        // Error details and home paths are never included.
        #expect(!report.contains("sk-ant"))
        #expect(!report.contains(NSHomeDirectory()))
        #expect(!report.contains("/Users/"))
    }
}
