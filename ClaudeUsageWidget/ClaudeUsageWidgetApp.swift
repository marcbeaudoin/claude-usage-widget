//
//  ClaudeUsageWidgetApp.swift
//  ClaudeUsageWidget
//
//  Created by Marc Beaudoin on 23/10/2026.
//

import SwiftUI

enum AppWindowID {
    static let details = "details"
    static let setupGuide = "setup-guide"
}

@main
struct ClaudeUsageWidgetApp: App {
    @State private var coordinator = UsageRefreshCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopoverView(coordinator: coordinator)
        } label: {
            MenuBarLabel(coordinator: coordinator)
                .task { coordinator.start() }
        }
        .menuBarExtraStyle(.window)

        // Opened by widget deep links (claudeusage://open, claudeusage://refresh).
        Window("Claude Usage", id: AppWindowID.details) {
            DetailsWindowView(coordinator: coordinator)
        }
        .handlesExternalEvents(matching: [DeepLink.scheme])
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentSize)

        Window("Setup Guide", id: AppWindowID.setupGuide) {
            SetupGuideView()
        }
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView(coordinator: coordinator)
        }
    }
}

/// Details window content; handles widget deep links.
struct DetailsWindowView: View {
    let coordinator: UsageRefreshCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            UsageDetailView(coordinator: coordinator)
            HStack {
                Button("Refresh Now") {
                    Task { await coordinator.refresh(force: true) }
                }
                .disabled(coordinator.isRefreshing)
                Spacer()
                SettingsLink { Text("Settings…") }
            }
        }
        .padding(16)
        .frame(width: 340)
        .onOpenURL { url in
            if DeepLink(url: url) == .refresh {
                Task { await coordinator.refresh(force: true) }
            }
        }
    }
}
