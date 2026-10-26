//
//  SettingsView.swift
//  ClaudeUsageWidget
//

import AppKit
import SwiftUI

/// Settings and diagnostics (FR-7).
struct SettingsView: View {
    let coordinator: UsageRefreshCoordinator
    @Environment(\.openWindow) private var openWindow
    @State private var copied = false
    @State private var accessMessage: String?

    var body: some View {
        Form {
            Section("Data source") {
                LabeledContent("Provider", value: coordinator.providerDisplayName)
                LabeledContent("Folder access") {
                    HStack {
                        Text(coordinator.hasFolderAccess ? "Granted (read-only)" : "Not granted")
                        if coordinator.hasFolderAccess {
                            Button("Revoke") { Task { await coordinator.revokeFolderAccess() } }
                        } else {
                            Button("Grant Access…") {
                                Task { accessMessage = await coordinator.requestFolderAccess() }
                            }
                        }
                    }
                }
                if let accessMessage {
                    Text(accessMessage).font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("Integration", value: coordinator.hasFolderAccess ? (coordinator.integrationInstalled ? "Installed" : "Not installed") : "Unknown (no folder access)")
                LabeledContent("Last status-line run") {
                    Text(coordinator.heartbeat.map { UsageFormatting.updatedText(observedAt: $0.invokedAt, now: .now).replacingOccurrences(of: "Updated ", with: "") } ?? "Never recorded")
                }
                LabeledContent("Last successful update") {
                    Text(coordinator.snapshot.map { UsageFormatting.updatedText(observedAt: $0.observedAt, now: .now) } ?? "None")
                }
                LabeledContent("Shared storage", value: coordinator.sharedStoreAvailable ? "Available" : "Unavailable")
                if let error = coordinator.lastError {
                    LabeledContent("Last refresh") {
                        Text(error.title).foregroundStyle(.orange)
                    }
                    Text(error.recoveryMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Claude usage API (optional)") {
                Toggle("Fetch usage from Anthropic", isOn: Binding(
                    get: { coordinator.usageAPIEnabled },
                    set: { enabled in Task { await coordinator.setUsageAPIEnabled(enabled) } }
                ))
                Text("Updates while you use Claude in Xcode or claude.ai, not only Claude Code in the terminal. Reads your Claude Code login from the Keychain (macOS asks first; choose Always Allow) and calls an unofficial Anthropic endpoint at most every 5 minutes. The token stays in memory, is sent only to api.anthropic.com, and is never stored or logged. The status line is still used as a fallback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if coordinator.usageAPIEnabled {
                    LabeledContent("Last API check") {
                        if let error = coordinator.usageAPIError {
                            Text(error.title).foregroundStyle(.orange)
                        } else {
                            Text(coordinator.lastUsageAPIAttemptAt.map { UsageFormatting.updatedText(observedAt: $0, now: .now).replacingOccurrences(of: "Updated ", with: "") } ?? "Not yet")
                        }
                    }
                    if let error = coordinator.usageAPIError {
                        Text(error.recoveryMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Actions") {
                HStack {
                    Button("Refresh Now") {
                        Task { await coordinator.refresh(force: true) }
                    }
                    .disabled(coordinator.isRefreshing)
                    Button("Open Setup Guide") {
                        openWindow(id: AppWindowID.setupGuide)
                    }
                    Button("Show Integration Folder in Finder") {
                        revealIntegrationFolder()
                    }
                }
                HStack {
                    Button(copied ? "Copied" : "Copy Diagnostics") {
                        copyDiagnostics()
                    }
                    Text("Sanitized: no payloads, prompts, tokens or file contents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("About") {
                Text("\(coordinator.usageAPIEnabled ? "Usage data stays on this Mac. The only network request is the opt-in usage API call to api.anthropic.com." : "Usage data stays on this Mac. Claude Usage sends nothing over the network.") No analytics. Warning (70%) and critical (90%) colors are display conventions, not Claude-defined thresholds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func copyDiagnostics() {
        let info = Bundle.main.infoDictionary
        let input = DiagnosticsReport.Input(
            appVersion: "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            providerName: coordinator.providerDisplayName,
            providerIdentifier: coordinator.providerIdentifier,
            folderAccessGranted: coordinator.hasFolderAccess,
            integrationInstalled: coordinator.integrationInstalled,
            sharedStoreAvailable: coordinator.sharedStoreAvailable,
            watchingFiles: coordinator.isWatchingFiles,
            snapshot: coordinator.snapshot,
            lastError: coordinator.lastError,
            lastAttemptAt: coordinator.lastAttemptAt,
            heartbeat: coordinator.heartbeat,
            usageAPIEnabled: coordinator.usageAPIEnabled,
            usageAPIError: coordinator.usageAPIError,
            lastUsageAPIAttemptAt: coordinator.lastUsageAPIAttemptAt
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DiagnosticsReport.make(input, now: .now), forType: .string)
        copied = true
    }

    private func revealIntegrationFolder() {
        let url = SharedPaths.integrationDirectory
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }
}
