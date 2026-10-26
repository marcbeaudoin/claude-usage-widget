//
//  MenuBarPopoverView.swift
//  ClaudeUsageWidget
//

import SwiftUI

/// Content of the menu-bar popover (§8.6).
struct MenuBarPopoverView: View {
    let coordinator: UsageRefreshCoordinator
    @Environment(\.openWindow) private var openWindow
    @State private var accessMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude Usage")
                .font(.headline)
            UsageDetailView(coordinator: coordinator)
            if !coordinator.hasFolderAccess {
                Button("Grant Folder Access…") {
                    Task { accessMessage = await coordinator.requestFolderAccess() }
                }
                if let accessMessage {
                    Text(accessMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            HStack {
                Button {
                    Task { await coordinator.refresh(force: true) }
                } label: {
                    Label("Refresh Now", systemImage: "arrow.clockwise")
                }
                .disabled(coordinator.isRefreshing)
                .keyboardShortcut("r")
                Spacer()
                SettingsLink {
                    Text("Settings…")
                }
                .keyboardShortcut(",")
            }
            HStack {
                Button("Open Setup Guide") {
                    openWindow(id: AppWindowID.setupGuide)
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// Short text shown next to the menu-bar icon: the primary limit's percentage.
struct MenuBarLabel: View {
    let coordinator: UsageRefreshCoordinator

    var body: some View {
        if let limit = coordinator.snapshot?.primaryLimit, let used = limit.usedPercentage {
            Label(UsageFormatting.percentText(used), systemImage: "gauge.with.dots.needle.50percent")
                .labelStyle(.titleAndIcon)
                .accessibilityLabel("Claude usage, \(limit.title), \(Int(used.rounded())) percent used")
        } else {
            Image(systemName: "gauge.with.dots.needle.0percent")
                .accessibilityLabel("Claude usage, no data")
        }
    }
}
