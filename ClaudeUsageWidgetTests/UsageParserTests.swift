//
//  UsageParserTests.swift
//  ClaudeUsageWidgetTests
//

import Foundation
import Testing
@testable import ClaudeUsageWidget

/// Builds snapshot-file JSON for tests. Values are synthetic test data.
enum Fixture {
    static func snapshotJSON(
        schemaVersion: Any = 1,
        observedAt: String = "2026-10-20T13:54:00Z",
        source: String = "claude-code-status-line",
        limits: String? = nil,
        extraTopLevel: String = ""
    ) -> Data {
        let limitsJSON = limits ?? """
        [
          {"id": "session", "title": "Current session", "kind": "fiveHour",
           "usedPercentage": 62, "resetsAt": "2026-10-20T16:00:00Z", "availability": "reported"},
          {"id": "weekly", "title": "Weekly limit", "kind": "sevenDay",
           "usedPercentage": 78.4, "resetsAt": "2026-10-26T07:00:00+00:00", "availability": "reported"}
        ]
        """
        return Data("""
        {
          \(extraTopLevel)
          "schemaVersion": \(schemaVersion),
          "observedAt": "\(observedAt)",
          "source": "\(source)",
          "limits": \(limitsJSON)
        }
        """.utf8)
    }

    static func limitJSON(kind: String = "fiveHour", percentage: String = "50", resetsAt: String? = "\"2026-10-20T16:00:00Z\"") -> String {
        let reset = resetsAt.map { ", \"resetsAt\": \($0)" } ?? ""
        return "[{\"id\": \"l\", \"title\": \"L\", \"kind\": \"\(kind)\", \"usedPercentage\": \(percentage)\(reset)}]"
    }

    static func date(_ iso: String) -> Date {
        UsageSnapshotParser.parseTimestamp(iso)!
    }
}

struct UsageParserTests {

    @Test func parsesValidPayload() throws {
        let snapshot = try UsageSnapshotParser.parse(Fixture.snapshotJSON())
        #expect(snapshot.schemaVersion == 1)
        #expect(snapshot.source == "claude-code-status-line")
        #expect(snapshot.observedAt == Fixture.date("2026-10-20T13:54:00Z"))
        #expect(snapshot.limits.map(\.id) == ["session", "weekly"])

        let session = try #require(snapshot.limit(kind: .fiveHour))
        #expect(session.usedPercentage == 62)
        #expect(session.resetsAt == Fixture.date("2026-10-20T16:00:00Z"))
        #expect(session.availability == .reported)

        let weekly = try #require(snapshot.limit(kind: .sevenDay))
        #expect(weekly.usedPercentage == 78.4)
        #expect(weekly.resetsAt == Fixture.date("2026-10-26T07:00:00Z"))
    }

    @Test func missingOptionalFieldsAreUnavailableNotZero() throws {
        let limits = """
        [{"id": "session", "kind": "fiveHour"},
         {"id": "weekly", "kind": "sevenDay", "usedPercentage": 10}]
        """
        let snapshot = try UsageSnapshotParser.parse(Fixture.snapshotJSON(limits: limits))
        let session = try #require(snapshot.limit(kind: .fiveHour))
        #expect(session.usedPercentage == nil)
        #expect(session.resetsAt == nil)
        #expect(session.availability == .notReported)
        #expect(session.remainingPercentage == nil)
        #expect(session.title == "session")

        let weekly = try #require(snapshot.limit(kind: .sevenDay))
        #expect(weekly.resetsAt == nil)
        #expect(weekly.availability == .reported)
    }

    @Test func notReportedLimitDropsAnyValues() throws {
        let limits = """
        [{"id": "session", "kind": "fiveHour", "usedPercentage": 40, "availability": "notReported"}]
        """
        let snapshot = try UsageSnapshotParser.parse(Fixture.snapshotJSON(limits: limits))
        #expect(snapshot.limits.first?.usedPercentage == nil)
    }

    @Test func reportedWithoutPercentageIsRejected() {
        let limits = #"[{"id": "session", "kind": "fiveHour", "availability": "reported"}]"#
        #expect(throws: UsageProviderError.self) {
            try UsageSnapshotParser.parse(Fixture.snapshotJSON(limits: limits))
        }
    }

    @Test func ignoresUnknownFieldsAndKinds() throws {
        let limits = """
        [{"id": "x", "kind": "someFutureWindow", "usedPercentage": 5, "color": "red"}]
        """
        let data = Fixture.snapshotJSON(limits: limits, extraTopLevel: #""futureField": {"a": 1},"#)
        let snapshot = try UsageSnapshotParser.parse(data)
        #expect(snapshot.limits.first?.kind == .other)
    }

    @Test(arguments: [0, 2, 99])
    func rejectsUnknownSchemaVersions(version: Int) {
        #expect(throws: UsageProviderError.unsupportedSchema(version: version)) {
            try UsageSnapshotParser.parse(Fixture.snapshotJSON(schemaVersion: version))
        }
    }

    @Test(arguments: ["", "not json", "{", "[]", #"{"schemaVersion": 1}"#])
    func rejectsInvalidJSON(text: String) {
        #expect(throws: UsageProviderError.self) {
            try UsageSnapshotParser.parse(Data(text.utf8))
        }
    }

    @Test func rejectsNonIntegerSchemaVersion() {
        #expect(throws: UsageProviderError.self) {
            try UsageSnapshotParser.parse(Fixture.snapshotJSON(schemaVersion: "\"1\""))
        }
    }

    @Test(arguments: [
        "2026-10-20 13:54:00",        // no T, no zone
        "2026-10-20T13:54:00",        // no time zone
        "1738425600",                 // epoch seconds belong to the raw payload, not this file
        "yesterday",
        "2026-13-40T99:00:00Z",
    ])
    func rejectsInvalidTimestamps(timestamp: String) {
        #expect(throws: UsageProviderError.self) {
            try UsageSnapshotParser.parse(Fixture.snapshotJSON(observedAt: timestamp))
        }
        let limits = Fixture.limitJSON(resetsAt: "\"\(timestamp)\"")
        #expect(throws: UsageProviderError.self) {
            try UsageSnapshotParser.parse(Fixture.snapshotJSON(limits: limits))
        }
    }

    @Test func acceptsFractionalSecondsAndOffsets() throws {
        #expect(UsageSnapshotParser.parseTimestamp("2026-10-20T13:54:00.123Z") != nil)
        #expect(UsageSnapshotParser.parseTimestamp("2026-10-20T15:54:00+02:00") == Fixture.date("2026-10-20T13:54:00Z"))
    }

    @Test(arguments: ["-1", "100.01", "250", "1e999", "\"50\"", "null"])
    func rejectsInvalidPercentagesInFile(percentage: String) throws {
        let data = Fixture.snapshotJSON(limits: Fixture.limitJSON(percentage: percentage))
        if percentage == "null" {
            // null is "not reported", which is valid.
            let snapshot = try UsageSnapshotParser.parse(data)
            #expect(snapshot.limits.first?.availability == .notReported)
        } else {
            #expect(throws: UsageProviderError.self) { try UsageSnapshotParser.parse(data) }
        }
    }

    @Test func percentageValidationRules() {
        #expect(!UsageSnapshotParser.isValidPercentage(.nan, kind: .fiveHour))
        #expect(!UsageSnapshotParser.isValidPercentage(.infinity, kind: .fiveHour))
        #expect(!UsageSnapshotParser.isValidPercentage(-.infinity, kind: .spendLimit))
        #expect(!UsageSnapshotParser.isValidPercentage(-0.5, kind: .sevenDay))
        #expect(!UsageSnapshotParser.isValidPercentage(100.5, kind: .sevenDay))
        #expect(UsageSnapshotParser.isValidPercentage(0, kind: .fiveHour))
        #expect(UsageSnapshotParser.isValidPercentage(100, kind: .fiveHour))
        // The gateway spend limit is documented to exceed 100%.
        #expect(UsageSnapshotParser.isValidPercentage(130, kind: .spendLimit))
        #expect(!UsageSnapshotParser.isValidPercentage(.nan, kind: .spendLimit))
    }

    @Test func boundaryPercentagesAccepted() throws {
        for value in ["0", "100", "0.0001", "99.9999"] {
            let data = Fixture.snapshotJSON(limits: Fixture.limitJSON(percentage: value))
            #expect(throws: Never.self) { try UsageSnapshotParser.parse(data) }
        }
    }

    @Test func rejectsDuplicateIDs() {
        let limits = """
        [{"id": "a", "kind": "fiveHour", "usedPercentage": 1},
         {"id": "a", "kind": "sevenDay", "usedPercentage": 2}]
        """
        #expect(throws: UsageProviderError.malformedPayload(reason: "Duplicate limit id.")) {
            try UsageSnapshotParser.parse(Fixture.snapshotJSON(limits: limits))
        }
    }

    @Test func rejectsEmptyIDAndSource() {
        #expect(throws: UsageProviderError.self) {
            try UsageSnapshotParser.parse(Fixture.snapshotJSON(limits: #"[{"id": "", "kind": "fiveHour"}]"#))
        }
        #expect(throws: UsageProviderError.self) {
            try UsageSnapshotParser.parse(Fixture.snapshotJSON(source: " "))
        }
    }

    @Test func roundTripsThroughEncoder() throws {
        let snapshot = try UsageSnapshotParser.parse(Fixture.snapshotJSON())
        let decoded = try UsageSnapshotParser.parse(try UsageSnapshotEncoder.encode(snapshot))
        #expect(decoded == snapshot)
    }

    @Test func errorMessagesAreActionableAndGeneric() {
        let errors: [UsageProviderError] = [
            .integrationNotInstalled, .sourceNotFound, .malformedPayload(reason: "x"),
            .unsupportedSchema(version: 9), .unsupportedUsageField, .permissionDenied, .appGroupUnavailable, .folderAccessRequired,
        ]
        for error in errors {
            #expect(!error.title.isEmpty)
            #expect(!error.recoveryMessage.isEmpty)
        }
        #expect(UsageProviderError.sourceNotFound.recoveryMessage == "Open Claude Code and start a session to provide usage data.")
    }
}
