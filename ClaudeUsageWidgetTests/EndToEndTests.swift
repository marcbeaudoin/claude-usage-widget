//
//  EndToEndTests.swift
//  ClaudeUsageWidgetTests
//

import Foundation
import Testing
@testable import ClaudeUsageWidget

/// Status-line payload → normalized JSON → shared store → widget model.
///
/// `Fixtures/normalized-snapshot.json` is the output of
/// `Integration/claude-usage-statusline.sh` for the synthetic payload in
/// `Integration/fixtures/statusline-payload.sample.json` (observedAt pinned).
/// `Tests/integration/test-integration.sh` verifies the script still produces it.
struct EndToEndTests {

    private func fixtureData() throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        let url = try #require(bundle.url(forResource: "normalized-snapshot", withExtension: "json"))
        return try Data(contentsOf: url)
    }

    @Test func scriptOutputFlowsToWidgetModel() async throws {
        let dir = try TempDirectory()
        // The script's output file, as the provider sees it.
        try fixtureData().write(to: dir.file("usage.json"))
        try Data("{}".utf8).write(to: dir.file("integration.json"))

        let provider = StatusLineFileProvider(directory: dir.url)
        let store = UsageStore(fileURL: dir.file("group/usage-snapshot.json"))
        let outcome = await UsageSync(provider: provider, store: store).run()
        let synced = try #require(outcome.snapshot)
        #expect(outcome == .updated(synced))

        // What the widget extension loads from the shared store.
        let widgetSnapshot = try #require(try store.load())
        #expect(widgetSnapshot == synced)

        let session = try #require(widgetSnapshot.limit(kind: .fiveHour))
        #expect(session.usedPercentage == 23.5)
        #expect(session.resetsAt == Fixture.date("2026-10-20T16:00:00Z"))
        let weekly = try #require(widgetSnapshot.limit(kind: .sevenDay))
        #expect(weekly.usedPercentage == 41.2)
        #expect(weekly.resetsAt == Fixture.date("2026-10-25T16:00:00Z"))
        // Each limit keeps its own reset time.
        #expect(session.resetsAt != weekly.resetsAt)
        #expect(widgetSnapshot.primaryLimit?.id == "session")

        let now = Fixture.date("2026-10-20T14:00:00Z")
        let dates = WidgetTimelinePlanner.entryDates(now: now, snapshot: widgetSnapshot)
        #expect(dates.contains(Fixture.date("2026-10-20T16:00:00Z")))
        #expect(UsageFormatting.countdownText(resetsAt: session.resetsAt, now: now) == "Resets in 2h")
    }

    @Test func subsequentMalformedWriteKeepsWidgetData() async throws {
        let dir = try TempDirectory()
        try fixtureData().write(to: dir.file("usage.json"))
        let provider = StatusLineFileProvider(directory: dir.url)
        let store = UsageStore(fileURL: dir.file("group/usage-snapshot.json"))
        _ = await UsageSync(provider: provider, store: store).run()
        let good = try store.load()

        try Data("{\"schemaVersion\": 1, \"limits\": [".utf8).write(to: dir.file("usage.json"))
        let outcome = await UsageSync(provider: provider, store: store).run()
        #expect(outcome.snapshot == good)
        #expect(try store.load() == good)
    }
}

private final class BundleToken {}
