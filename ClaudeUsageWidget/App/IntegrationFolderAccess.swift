//
//  IntegrationFolderAccess.swift
//  ClaudeUsageWidget
//

import AppKit
import Foundation

/// Read-only, user-granted access to `~/Library/Application Support/ClaudeUsage/`.
///
/// The app keeps the App Sandbox. The user selects the folder once in an open
/// panel; the app stores a read-only, app-scoped security-scoped bookmark in
/// its own (sandboxed) defaults and resolves it at launch.
@MainActor
final class IntegrationFolderAccess {

    enum GrantResult: Equatable {
        case granted
        case cancelled
        /// The user picked a folder other than the documented integration folder.
        case wrongFolder
        /// The folder does not exist yet — run the installer first.
        case folderMissing
        case failed
    }

    private static let bookmarkKey = "integrationFolderBookmark"
    private let defaults: UserDefaults
    private let expectedURL: URL

    /// Security-scoped URL currently being accessed, if access was granted.
    private(set) var grantedURL: URL?

    init(defaults: UserDefaults = .standard, expectedURL: URL = SharedPaths.integrationDirectory) {
        self.defaults = defaults
        self.expectedURL = expectedURL
        restore()
    }

    var hasAccess: Bool { grantedURL != nil }

    /// Whether the documented folder exists (checked via the parent, which
    /// `stat` can see without a grant).
    var folderExists: Bool {
        FileManager.default.fileExists(atPath: expectedURL.path)
    }

    /// Resolves the stored bookmark and starts accessing it.
    @discardableResult
    func restore() -> Bool {
        guard grantedURL == nil, let data = defaults.data(forKey: Self.bookmarkKey) else {
            return grantedURL != nil
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), isExpectedFolder(url), url.startAccessingSecurityScopedResource() else {
            defaults.removeObject(forKey: Self.bookmarkKey)
            return false
        }
        grantedURL = url
        if stale, let fresh = try? Self.makeBookmark(for: url) {
            defaults.set(fresh, forKey: Self.bookmarkKey)
        }
        return true
    }

    /// Shows an open panel pointed at the integration folder.
    func requestAccess() -> GrantResult {
        guard folderExists else { return .folderMissing }

        let panel = NSOpenPanel()
        panel.message = "Select the “ClaudeUsage” folder so Claude Usage can read the usage file written by the Claude Code status line. Access is read-only."
        panel.prompt = "Grant Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = expectedURL

        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        guard isExpectedFolder(url) else { return .wrongFolder }

        do {
            let bookmark = try Self.makeBookmark(for: url)
            revoke()
            defaults.set(bookmark, forKey: Self.bookmarkKey)
        } catch {
            return .failed
        }
        return restore() ? .granted : .failed
    }

    /// Stops accessing and forgets the bookmark.
    func revoke() {
        grantedURL?.stopAccessingSecurityScopedResource()
        grantedURL = nil
        defaults.removeObject(forKey: Self.bookmarkKey)
    }

    private func isExpectedFolder(_ url: URL) -> Bool {
        url.standardizedFileURL.resolvingSymlinksInPath().path
            == expectedURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
}
