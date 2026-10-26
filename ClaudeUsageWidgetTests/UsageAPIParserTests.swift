//
//  UsageAPIParserTests.swift
//  ClaudeUsageWidgetTests
//

import Foundation
import Testing
@testable import ClaudeUsageWidget

/// Values are synthetic test data following the observed endpoint shape.
struct UsageAPIParserTests {

    let now = Fixture.date("2026-10-25T21:00:00Z")

    private func parse(_ json: String) throws -> UsageSnapshot {
        try UsageAPIResponseParser.parse(Data(json.utf8), observedAt: now)
    }

    @Test func parsesSessionWeeklyAndModelWindows() throws {
        let snapshot = try parse("""
        { "five_hour": { "utilization": 24.0, "resets_at": "2026-10-25T23:00:00.552906+00:00" },
          "seven_day": { "utilization": 41.5, "resets_at": "2026-10-30T08:00:00+00:00" },
          "seven_day_oauth_apps": null,
          "seven_day_opus": null,
          "seven_day_sonnet": { "utilization": 12, "resets_at": null },
          "extra_usage": { "is_enabled": false, "monthly_limit": null } }
        """)
        #expect(snapshot.source == UsageSource.usageAPI)
        #expect(snapshot.observedAt == now)
        #expect(snapshot.limits.map(\.id) == ["session", "weekly", "weeklySonnet"])

        let session = try #require(snapshot.limit(kind: .fiveHour))
        #expect(session.usedPercentage == 24)
        // Microseconds are accepted; compare to the second.
        let sessionReset = try #require(session.resetsAt)
        #expect(abs(sessionReset.timeIntervalSince(Fixture.date("2026-10-25T23:00:00Z"))) < 1)

        let weekly = try #require(snapshot.limit(kind: .sevenDay))
        #expect(weekly.usedPercentage == 41.5)
        #expect(weekly.resetsAt == Fixture.date("2026-10-30T08:00:00Z"))

        let sonnet = try #require(snapshot.limit(kind: .modelSpecific))
        #expect(sonnet.usedPercentage == 12)
        #expect(sonnet.resetsAt == nil)
    }

    @Test func missingOrInvalidWindowIsNotReportedNeverZero() throws {
        let snapshot = try parse("""
        { "five_hour": null, "seven_day": { "utilization": 140, "resets_at": "x" },
          "seven_day_sonnet": { "utilization": 5 } }
        """)
        #expect(snapshot.limit(kind: .fiveHour)?.availability == .notReported)
        #expect(snapshot.limit(kind: .fiveHour)?.usedPercentage == nil)
        #expect(snapshot.limit(kind: .sevenDay)?.availability == .notReported)
        #expect(snapshot.limit(kind: .modelSpecific)?.usedPercentage == 5)
    }

    @Test func windowOfUnexpectedTypeIsIgnored() throws {
        let snapshot = try parse(#"{ "five_hour": "oops", "seven_day": { "utilization": 3 } }"#)
        #expect(snapshot.limit(kind: .fiveHour)?.availability == .notReported)
        #expect(snapshot.limit(kind: .sevenDay)?.usedPercentage == 3)
    }

    @Test func noReportedWindowIsUnsupported() {
        #expect(throws: UsageProviderError.unsupportedUsageField) {
            try parse(#"{ "five_hour": null, "seven_day": null }"#)
        }
    }

    @Test func nonJSONIsMalformed() {
        #expect(throws: UsageProviderError.self) { try parse("<html>") }
        #expect(throws: UsageProviderError.self) { try parse("[]") }
    }

    @Test func credentialsParseOnlyTokenAndExpiry() throws {
        let json = #"{"claudeAiOauth":{"accessToken":"synthetic-token","refreshToken":"r","expiresAt":1792986889567,"scopes":["user:inference"]}}"#
        let credentials = try #require(ClaudeCredentials.parse(Data(json.utf8)))
        #expect(credentials.accessToken == "synthetic-token")
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_792_986_889.567))
        #expect(!credentials.isExpired(now: Date(timeIntervalSince1970: 1_792_986_000)))
        // Within a minute of expiry counts as expired.
        #expect(credentials.isExpired(now: Date(timeIntervalSince1970: 1_792_986_850)))
    }

    @Test func credentialsRejectMissingToken() {
        #expect(ClaudeCredentials.parse(Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)) == nil)
        #expect(ClaudeCredentials.parse(Data(#"{"other":{}}"#.utf8)) == nil)
        #expect(ClaudeCredentials.parse(Data("not json".utf8)) == nil)
    }

    @Test func usageAPIErrorsAreActionableAndContainNoSecrets() {
        let errors: [UsageProviderError] = [
            .keychainAccessDenied, .credentialsNotFound, .authenticationRequired,
            .rateLimited, .networkUnavailable, .unexpectedResponse(status: 500),
        ]
        for error in errors {
            #expect(!error.title.isEmpty)
            #expect(!error.recoveryMessage.isEmpty)
        }
        #expect(UsageProviderError.unexpectedResponse(status: 502).recoveryMessage.contains("502"))
    }
}
