//
//  UsageProviderError.swift
//  Shared between the Claude Usage app and widget extension.
//

import Foundation

/// Non-sensitive error categories reported by providers and storage.
///
/// Associated values never contain payload contents, tokens, or file data —
/// only short, developer-authored descriptions safe to show and copy.
nonisolated enum UsageProviderError: Error, Equatable, Sendable {
    /// The integration has not been installed (no marker or script found).
    case integrationNotInstalled
    /// The integration is installed but no snapshot file exists yet.
    case sourceNotFound
    /// The snapshot file could not be parsed or failed validation.
    case malformedPayload(reason: String)
    /// The snapshot file uses a schema version this build does not understand.
    case unsupportedSchema(version: Int)
    /// Claude Code ran but its payload did not include subscription usage.
    case unsupportedUsageField
    /// A file exists but could not be read.
    case permissionDenied
    /// The App Group shared container is not accessible (signing/entitlements).
    case appGroupUnavailable
    /// The sandboxed app has not been granted read access to the integration folder.
    case folderAccessRequired
    /// Usage API: the user denied (or cancelled) Keychain access to the Claude Code login.
    case keychainAccessDenied
    /// Usage API: no Claude Code login was found in the Keychain.
    case credentialsNotFound
    /// Usage API: every stored login token has expired, or the server rejected it.
    case authenticationRequired
    /// Usage API: the server answered HTTP 429.
    case rateLimited
    /// Usage API: the server could not be reached.
    case networkUnavailable
    /// Usage API: the server answered with an unexpected HTTP status.
    case unexpectedResponse(status: Int)

    /// Short title for UI.
    var title: String {
        switch self {
        case .integrationNotInstalled: "Integration not installed"
        case .sourceNotFound: "No data yet"
        case .malformedPayload: "Usage data could not be read"
        case .unsupportedSchema: "Unsupported data format"
        case .unsupportedUsageField: "Usage not provided"
        case .permissionDenied: "Permission denied"
        case .appGroupUnavailable: "Shared storage unavailable"
        case .folderAccessRequired: "Folder access needed"
        case .keychainAccessDenied: "Keychain access denied"
        case .credentialsNotFound: "Claude login not found"
        case .authenticationRequired: "Claude login expired"
        case .rateLimited: "Rate limited"
        case .networkUnavailable: "Network unavailable"
        case .unexpectedResponse: "Usage service error"
        }
    }

    /// Actionable explanation with the next step (FR-6, §13).
    var recoveryMessage: String {
        switch self {
        case .integrationNotInstalled:
            "Set up the Claude Code status-line integration. See the setup guide."
        case .sourceNotFound:
            "Open Claude Code and start a session to provide usage data."
        case .malformedPayload:
            "Usage data could not be read. The last valid snapshot is being kept."
        case .unsupportedSchema(let version):
            "The usage file uses format version \(version), which this app does not support. Update the app or reinstall the integration. The last valid snapshot is being kept."
        case .unsupportedUsageField:
            "Claude Code did not report subscription usage. It is only provided to Claude Pro and Max subscribers, after the first response in a session."
        case .permissionDenied:
            "The usage file could not be read. Check its permissions, then refresh."
        case .appGroupUnavailable:
            "The app and widget cannot share data. Check that both targets are signed with the same App Group."
        case .folderAccessRequired:
            "Grant Claude Usage read access to the ClaudeUsage folder in Settings."
        case .keychainAccessDenied:
            "Claude Usage was not allowed to read your Claude Code login. Choose Refresh Now and click Always Allow, or turn off the usage API in Settings."
        case .credentialsNotFound:
            "No Claude Code login was found in the Keychain. Sign in to Claude Code or Claude in Xcode, then refresh."
        case .authenticationRequired:
            "Your Claude login token has expired. Send a message in Claude Code or Claude in Xcode to renew it; Claude Usage picks it up automatically."
        case .rateLimited:
            "Anthropic asked Claude Usage to slow down. It will retry in a few minutes. The last snapshot is being kept."
        case .networkUnavailable:
            "Anthropic could not be reached. Check your connection. The last snapshot is being kept."
        case .unexpectedResponse(let status):
            "The usage service answered HTTP \(status). This endpoint is unofficial and may have changed. The last snapshot is being kept."
        }
    }
}
