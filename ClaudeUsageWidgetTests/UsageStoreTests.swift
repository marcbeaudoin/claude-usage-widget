//
//  UsageStoreTests.swift
//  ClaudeUsageWidgetTests
//

import Foundation
import Testing
@testable import ClaudeUsageWidget

/// A temporary directory removed when the test finishes.
final class TempDirectory {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeUsageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

/// Provider double returning a fixed result.
struct StubProvider: UsageProvider {
    let identifier = "stub"
    let displayName = "Stub"
    let result: Result<UsageSnapshot, UsageProviderError>
    func fetchUsage() async throws(UsageProviderError) -> UsageSnapshot { try result.get() }
}

struct UsageStoreTests {

    @Test func appGroupIdentifierComesFromBuildConfiguration() throws {
        // Expanded from APP_GROUP_IDENTIFIER (Config/*.xcconfig) into Info.plist.
        let identifier = try #require(SharedPaths.appGroupIdentifier)
        #expect(identifier.hasPrefix("group."))
        #expect(!identifier.contains("$("))
        #expect(SharedPaths.sharedContainerURL() != nil)
    }

    private func snapshot(at iso: String, pct: Double) -> UsageSnapshot {
        UsageSnapshot(
            observedAt: Fixture.date(iso),
            source: UsageSource.statusLine,
            sourceVersion: "2.1.309",
            limits: [
                UsageLimit(id: "session", title: "Current session", kind: .fiveHour, usedPercentage: pct, resetsAt: Fixture.date("2026-10-20T16:00:00Z")),
                UsageLimit(id: "weekly", title: "Weekly limit", kind: .sevenDay, usedPercentage: nil, resetsAt: nil),
            ]
        )
    }

    // MARK: Store

    @Test func missingFileLoadsAsNil() throws {
        let dir = try TempDirectory()
        #expect(try UsageStore(fileURL: dir.file("none.json")).load() == nil)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let dir = try TempDirectory()
        let store = UsageStore(fileURL: dir.file("nested/usage-snapshot.json"))
        let value = snapshot(at: "2026-10-20T13:54:00Z", pct: 62)
        try store.save(value)
        #expect(try store.load() == value)
    }

    @Test func savedFileIsOwnerOnly() throws {
        let dir = try TempDirectory()
        let url = dir.file("usage-snapshot.json")
        try UsageStore(fileURL: url).save(snapshot(at: "2026-10-20T13:54:00Z", pct: 1))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func malformedStoredFileThrows() throws {
        let dir = try TempDirectory()
        let url = dir.file("usage-snapshot.json")
        try Data("{garbage".utf8).write(to: url)
        #expect(throws: UsageProviderError.self) { try UsageStore(fileURL: url).load() }
    }

    // MARK: Atomic writer

    @Test func atomicWriteReplacesAndLeavesNoTempFiles() throws {
        let dir = try TempDirectory()
        let url = dir.file("target.json")
        try AtomicFileWriter.write(Data("first".utf8), to: url)
        try AtomicFileWriter.write(Data("second".utf8), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "second")
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.url.path)
        #expect(contents == ["target.json"])
    }

    @Test func concurrentReadersNeverSeePartialFiles() async throws {
        let dir = try TempDirectory()
        let store = UsageStore(fileURL: dir.file("usage-snapshot.json"))
        try store.save(snapshot(at: "2026-10-20T13:00:00Z", pct: 0))

        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for i in 1...200 {
                    try? store.save(snapshot(at: "2026-10-20T13:00:00Z", pct: Double(i % 100)))
                }
                return true
            }
            for _ in 0..<4 {
                group.addTask {
                    for _ in 0..<200 {
                        // Every read must decode a complete, valid snapshot.
                        guard (try? store.load()) != nil else { return false }
                    }
                    return true
                }
            }
            for await ok in group {
                #expect(ok)
            }
        }
    }

    // MARK: Sync / last known-good preservation

    @Test func syncStoresNewSnapshot() async throws {
        let dir = try TempDirectory()
        let store = UsageStore(fileURL: dir.file("s.json"))
        let value = snapshot(at: "2026-10-20T13:54:00Z", pct: 62)
        let outcome = await UsageSync(provider: StubProvider(result: .success(value)), store: store).run()
        #expect(outcome == .updated(value))
        #expect(try store.load() == value)
    }

    @Test func failedReadKeepsLastKnownGood() async throws {
        let dir = try TempDirectory()
        let store = UsageStore(fileURL: dir.file("s.json"))
        let good = snapshot(at: "2026-10-20T13:54:00Z", pct: 62)
        try store.save(good)

        for error in [UsageProviderError.malformedPayload(reason: "x"), .unsupportedSchema(version: 2), .sourceNotFound] {
            let outcome = await UsageSync(provider: StubProvider(result: .failure(error)), store: store).run()
            #expect(outcome == .failed(error, lastKnownGood: good))
            #expect(outcome.snapshot == good)
            #expect(try store.load() == good)
        }
    }

    @Test func olderSnapshotDoesNotOverwriteNewer() async throws {
        let dir = try TempDirectory()
        let store = UsageStore(fileURL: dir.file("s.json"))
        let newer = snapshot(at: "2026-10-20T14:00:00Z", pct: 70)
        try store.save(newer)
        let older = snapshot(at: "2026-10-20T13:00:00Z", pct: 10)
        let outcome = await UsageSync(provider: StubProvider(result: .success(older)), store: store).run()
        #expect(outcome == .unchanged(newer))
        #expect(try store.load() == newer)
    }

    // MARK: File provider

    @Test func fileProviderReportsMissingIntegrationAndMissingData() async throws {
        let dir = try TempDirectory()
        let provider = StatusLineFileProvider(snapshotURL: dir.file("usage.json"), markerURL: dir.file("integration.json"))
        await #expect(throws: UsageProviderError.integrationNotInstalled) { try await provider.fetchUsage() }

        try Data("{}".utf8).write(to: dir.file("integration.json"))
        await #expect(throws: UsageProviderError.sourceNotFound) { try await provider.fetchUsage() }
    }

    @Test func fileProviderParsesAndValidates() async throws {
        let dir = try TempDirectory()
        let provider = StatusLineFileProvider(snapshotURL: dir.file("usage.json"), markerURL: dir.file("integration.json"))
        try Fixture.snapshotJSON().write(to: dir.file("usage.json"))
        let snapshot = try await provider.fetchUsage()
        #expect(snapshot.limits.count == 2)

        try Fixture.snapshotJSON(schemaVersion: 7).write(to: dir.file("usage.json"))
        await #expect(throws: UsageProviderError.unsupportedSchema(version: 7)) { try await provider.fetchUsage() }
    }

    @Test func fileProviderRejectsSnapshotWithoutAnyReportedLimit() async throws {
        let dir = try TempDirectory()
        let provider = StatusLineFileProvider(snapshotURL: dir.file("usage.json"), markerURL: dir.file("integration.json"))
        try Fixture.snapshotJSON(limits: #"[{"id": "session", "kind": "fiveHour"}]"#).write(to: dir.file("usage.json"))
        await #expect(throws: UsageProviderError.unsupportedUsageField) { try await provider.fetchUsage() }
    }

    @Test func unreadableSourceFileIsPermissionDenied() async throws {
        let dir = try TempDirectory()
        let url = dir.file("usage.json")
        try Fixture.snapshotJSON().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        let provider = StatusLineFileProvider(snapshotURL: url, markerURL: dir.file("integration.json"))
        await #expect(throws: UsageProviderError.permissionDenied) { try await provider.fetchUsage() }
    }

    // MARK: Heartbeat

    @Test func parsesHeartbeat() {
        let data = Data(#"{"schemaVersion":1,"invokedAt":"2026-10-20T13:54:00Z","result":"noRateLimits","claudeCodeVersion":"2.1.309","extra":true}"#.utf8)
        let heartbeat = IntegrationHeartbeat.parse(data)
        #expect(heartbeat?.result == .noRateLimits)
        #expect(heartbeat?.claudeCodeVersion == "2.1.309")
        #expect(IntegrationHeartbeat.parse(Data(#"{"schemaVersion":2,"invokedAt":"2026-10-20T13:54:00Z"}"#.utf8)) == nil)
        #expect(IntegrationHeartbeat.parse(Data("nope".utf8)) == nil)
    }
}
