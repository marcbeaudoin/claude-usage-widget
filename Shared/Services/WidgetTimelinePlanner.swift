//
//  WidgetTimelinePlanner.swift
//  Shared between the Claude Usage app and widget extension.
//

import Foundation

/// Chooses widget timeline entry dates (§12 "Countdown behavior").
///
/// Entries only change presentation (countdown text, stale marker, reset-passed
/// state). They never change values: every entry renders the same snapshot.
nonisolated enum WidgetTimelinePlanner {

    /// Spacing between regular entries. Countdown text is precise to the minute
    /// only at render time; WidgetKit may render later than requested.
    static let interval: TimeInterval = 15 * 60
    /// How far ahead the timeline extends before WidgetKit asks for a new one.
    static let horizon: TimeInterval = 3 * 60 * 60

    static func entryDates(now: Date, snapshot: UsageSnapshot?, staleThreshold: TimeInterval = Freshness.defaultThreshold) -> [Date] {
        let end = now.addingTimeInterval(horizon)
        var dates: Set<Date> = [now]

        var next = now.addingTimeInterval(interval)
        while next <= end {
            dates.insert(next)
            next = next.addingTimeInterval(interval)
        }

        if let snapshot {
            // Switch to "Awaiting updated data" right when a window's reset passes.
            for reset in snapshot.limits.compactMap(\.resetsAt) where reset > now && reset <= end {
                dates.insert(reset)
            }
            // Show the stale marker as soon as the snapshot becomes stale.
            let staleAt = snapshot.observedAt.addingTimeInterval(staleThreshold + 1)
            if staleAt > now && staleAt <= end {
                dates.insert(staleAt)
            }
        }
        return dates.sorted()
    }
}
