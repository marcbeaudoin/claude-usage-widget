//
//  UsageRefreshCoordinator.swift
//  ClaudeUsageWidget
//

import AppKit
import Foundation
import Observation
import WidgetKit

/// Owns the app's view of usage data and decides when to refresh.
///
/// Refresh triggers (FR-5): app launch, file-system changes in the integration
/// directory (debounced), manual refresh, wake from sleep, and a conservative
/// fallback poll used only while the directory cannot be watched.
///
/// When the user opts in to the usage API, it becomes the primary source
/// (it also covers Claude in Xcode and claude.ai) and is polled every few
/// minutes; the status-line file is used as a fallback whenever it fails.
@MainActor
@Observable
final class UsageRefreshCoordinator {

    /// Last snapshot that passed validation. Never cleared by a failed refresh.
    private(set) var snapshot: UsageSnapshot?
    /// Error from the most recent refresh attempt, if it failed.
    private(set) var lastError: UsageProviderError?
    /// Time of the most recent refresh attempt (successful or not). Diagnostics only;
    /// the UI's "Updated" time is always `snapshot.observedAt`.
    private(set) var lastAttemptAt: Date?
    /// Latest heartbeat written by the status-line script.
    private(set) var heartbeat: IntegrationHeartbeat?
    /// Whether the shared App Group store is usable.
    let sharedStoreAvailable: Bool
    private(set) var isWatchingFiles = false
    private(set) var isRefreshing = false
    private(set) var hasFolderAccess = false
    private(set) var integrationInstalled = false

    /// Whether the user opted in to the usage API (persisted in user defaults).
    private(set) var usageAPIEnabled: Bool
    /// Error from the most recent usage API attempt, if it failed.
    private(set) var usageAPIError: UsageProviderError?
    /// Time of the most recent usage API attempt.
    private(set) var lastUsageAPIAttemptAt: Date?

    /// Describes the provider of the displayed snapshot for the UI and diagnostics.
    var providerDisplayName: String {
        snapshot?.source == UsageSource.usageAPI ? UsageAPIProvider.displayNameValue : StatusLineFileProvider.displayNameValue
    }
    var providerIdentifier: String {
        snapshot?.source == UsageSource.usageAPI ? UsageAPIProvider.identifierValue : StatusLineFileProvider.identifierValue
    }

    @ObservationIgnored private let folderAccess: IntegrationFolderAccess
    @ObservationIgnored private let store: UsageStore?
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var fallbackPollTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var started = false
    @ObservationIgnored private let usageAPIProvider = UsageAPIProvider()
    @ObservationIgnored private var usageAPIPollTask: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults

    /// Debounce interval for file events. The script writes two files per run.
    static let debounceInterval: Duration = .seconds(1)
    /// Fallback polling interval, used only when file watching is unavailable.
    static let fallbackPollInterval: Duration = .seconds(5 * 60)
    /// Usage API polling interval while the feature is enabled.
    static let usageAPIPollInterval: Duration = .seconds(5 * 60)
    /// Minimum time between automatic usage API calls (file events can be frequent).
    static let usageAPIMinimumInterval: TimeInterval = 60
    /// Back-off after the server answered HTTP 429.
    static let usageAPIRateLimitBackoff: TimeInterval = 15 * 60
    static let usageAPIEnabledKey = "usageAPIEnabled"

    init(
        folderAccess: IntegrationFolderAccess? = nil,
        store: UsageStore? = try? UsageStore.shared(),
        defaults: UserDefaults = .standard
    ) {
        let folderAccess = folderAccess ?? IntegrationFolderAccess()
        self.folderAccess = folderAccess
        self.store = store
        self.sharedStoreAvailable = store != nil
        self.defaults = defaults
        self.usageAPIEnabled = defaults.bool(forKey: Self.usageAPIEnabledKey)
        self.hasFolderAccess = folderAccess.hasAccess
        // Show the last known-good snapshot immediately, before the first read.
        self.snapshot = try? store?.load()
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        if usageAPIEnabled { startUsageAPIPolling() }
        Task { await refresh() }
    }

    /// Turns the usage API on or off, then refreshes immediately.
    func setUsageAPIEnabled(_ enabled: Bool) async {
        guard enabled != usageAPIEnabled else { return }
        usageAPIEnabled = enabled
        defaults.set(enabled, forKey: Self.usageAPIEnabledKey)
        usageAPIError = nil
        lastUsageAPIAttemptAt = nil
        if enabled {
            startUsageAPIPolling()
        } else {
            usageAPIPollTask?.cancel()
            usageAPIPollTask = nil
            await usageAPIProvider.forgetCredentials()
        }
        await refresh(force: true)
    }

    /// Presents the folder picker. Returns a user-facing message when access was not granted.
    func requestFolderAccess() async -> String? {
        let result = folderAccess.requestAccess()
        hasFolderAccess = folderAccess.hasAccess
        await refresh()
        switch result {
        case .granted: return nil
        case .cancelled: return "Access was not granted."
        case .wrongFolder: return "Please select ~/Library/Application Support/ClaudeUsage."
        case .folderMissing: return "The ClaudeUsage folder does not exist yet. Run the installer first (see the Setup Guide)."
        case .failed: return "Access could not be saved. Try again."
        }
    }

    func revokeFolderAccess() async {
        folderAccess.revoke()
        hasFolderAccess = false
        watcher = nil
        isWatchingFiles = false
        await refresh()
    }

    // MARK: Refresh

    /// Re-reads the source, updates the shared store if the data is newer,
    /// and asks WidgetKit to reload. A failure keeps the previous snapshot.
    ///
    /// - Parameter force: `true` for user-initiated refreshes; bypasses the
    ///   usage API's minimum interval and back-off.
    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        lastAttemptAt = .now

        let usageAPIProvidedData = usageAPIEnabled ? await refreshFromUsageAPI(force: force) : false

        guard let folder = folderAccess.grantedURL else {
            hasFolderAccess = false
            integrationInstalled = false
            if !usageAPIProvidedData {
                lastError = usageAPIEnabled ? (usageAPIError ?? .folderAccessRequired) : .folderAccessRequired
                startFallbackPolling()
            }
            return
        }
        hasFolderAccess = true

        let provider = StatusLineFileProvider(directory: folder)
        integrationInstalled = FileManager.default.fileExists(atPath: provider.markerURL.path)
        heartbeat = (try? Data(contentsOf: provider.statusURL)).flatMap(IntegrationHeartbeat.parse)

        if !usageAPIProvidedData {
            apply(await sync(with: provider))
            // Surface why the usage API is not being used, if it is enabled.
            if lastError == nil { lastError = usageAPIError }
        }

        // (Re)start watching if the directory appeared, or was removed and recreated.
        if !isWatchingFiles || !FileManager.default.fileExists(atPath: folder.path) {
            startWatching(folder)
        }
    }

    /// Fetches from the usage API, rate-limited. Returns `true` when the API
    /// is currently providing the data (this call or a recent successful one).
    private func refreshFromUsageAPI(force: Bool) async -> Bool {
        if !force {
            // A denied Keychain prompt must not re-appear on every poll.
            if usageAPIError == .keychainAccessDenied { return false }
            if let last = lastUsageAPIAttemptAt {
                let minimum = usageAPIError == .rateLimited ? Self.usageAPIRateLimitBackoff : Self.usageAPIMinimumInterval
                if Date.now.timeIntervalSince(last) < minimum { return usageAPIError == nil }
            }
        }
        lastUsageAPIAttemptAt = .now
        let outcome = await sync(with: usageAPIProvider)
        if case .failed(let error, _) = outcome {
            usageAPIError = error
            return false
        }
        usageAPIError = nil
        apply(outcome)
        return true
    }

    /// Reads one provider into the shared store (or memory when the store is unavailable).
    private func sync(with provider: any UsageProvider) async -> UsageSyncOutcome {
        if let store {
            return await UsageSync(provider: provider, store: store).run()
        }
        // No shared store: still display validated data in the app.
        do {
            let incoming = try await provider.fetchUsage()
            return SnapshotMergePolicy.shouldReplace(stored: snapshot, with: incoming)
                ? .updated(incoming) : .unchanged(snapshot ?? incoming)
        } catch {
            return .failed(error, lastKnownGood: snapshot)
        }
    }

    private func apply(_ outcome: UsageSyncOutcome) {
        switch outcome {
        case .updated(let newSnapshot):
            snapshot = newSnapshot
            lastError = store == nil ? .appGroupUnavailable : nil
            if store != nil {
                // A request only; WidgetKit decides when to actually reload.
                WidgetCenter.shared.reloadAllTimelines()
            }
        case .unchanged(let current):
            snapshot = current
            lastError = store == nil ? .appGroupUnavailable : nil
        case .failed(let error, let lastKnownGood):
            if let lastKnownGood { snapshot = lastKnownGood }
            lastError = resolve(error)
        }
    }

    /// Refines "no data" errors using the script heartbeat: if Claude Code ran
    /// the script but the payload had no `rate_limits`, say so explicitly.
    private func resolve(_ error: UsageProviderError) -> UsageProviderError {
        if error == .sourceNotFound, heartbeat?.result == .noRateLimits {
            return .unsupportedUsageField
        }
        return error
    }

    // MARK: File observation

    private func startWatching(_ directory: URL) {
        watcher = nil
        if let watcher = DirectoryWatcher(url: directory, onChange: { [weak self] in
            Task { @MainActor in self?.scheduleDebouncedRefresh() }
        }) {
            self.watcher = watcher
            isWatchingFiles = true
            fallbackPollTask?.cancel()
            fallbackPollTask = nil
        } else {
            isWatchingFiles = false
            startFallbackPolling()
        }
    }

    private func scheduleDebouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func startUsageAPIPolling() {
        usageAPIPollTask?.cancel()
        usageAPIPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.usageAPIPollInterval)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    private func startFallbackPolling() {
        guard fallbackPollTask == nil else { return }
        fallbackPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.fallbackPollInterval)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }
}

/// Watches a directory for writes/renames using a kqueue-backed dispatch source.
///
/// The status-line script replaces files by renaming a temp file into the
/// directory, which produces a `.write` event on the directory itself.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping @Sendable () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: .global(qos: .utility)
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
