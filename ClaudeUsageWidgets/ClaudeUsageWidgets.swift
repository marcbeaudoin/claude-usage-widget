//
//  ClaudeUsageWidgets.swift
//  ClaudeUsageWidgets
//
//  Created by Marc Beaudoin on 24/10/2026.
//

import SwiftUI
import WidgetKit

struct ClaudeUsageWidgets: Widget {
    let kind: String = "ClaudeUsageWidgets"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageWidgetProvider()) { entry in
            UsageWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Claude Usage")
        .description("Claude Code session and weekly usage limits with their reset times.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// Previews use synthetic test data, clearly not real usage.
private enum PreviewData {
    static let now = Date.now
    static let snapshot = UsageSnapshot(
        observedAt: now.addingTimeInterval(-120),
        source: UsageSource.statusLine,
        limits: [
            UsageLimit(id: "session", title: "Current session", kind: .fiveHour, usedPercentage: 62, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)),
            UsageLimit(id: "weekly", title: "Weekly limit", kind: .sevenDay, usedPercentage: 91, resetsAt: now.addingTimeInterval(3 * 86_400)),
        ]
    )
    static let stale = UsageSnapshot(
        observedAt: now.addingTimeInterval(-40 * 60),
        source: UsageSource.statusLine,
        limits: [
            UsageLimit(id: "session", title: "Current session", kind: .fiveHour, usedPercentage: nil, resetsAt: nil),
            UsageLimit(id: "weekly", title: "Weekly limit", kind: .sevenDay, usedPercentage: 40, resetsAt: now.addingTimeInterval(-60)),
        ]
    )
}

#Preview("Small", as: .systemSmall) {
    ClaudeUsageWidgets()
} timeline: {
    UsageWidgetEntry(date: .now, state: .snapshot(PreviewData.snapshot))
    UsageWidgetEntry(date: .now, state: .snapshot(PreviewData.stale))
    UsageWidgetEntry(date: .now, state: .unavailable(.sourceNotFound))
    UsageWidgetEntry(date: .now, state: .placeholder)
}

#Preview("Medium", as: .systemMedium) {
    ClaudeUsageWidgets()
} timeline: {
    UsageWidgetEntry(date: .now, state: .snapshot(PreviewData.snapshot))
    UsageWidgetEntry(date: .now, state: .snapshot(PreviewData.stale))
}

#Preview("Large", as: .systemLarge) {
    ClaudeUsageWidgets()
} timeline: {
    UsageWidgetEntry(date: .now, state: .snapshot(PreviewData.snapshot))
}
