//
//  UsageWidgetProvider.swift
//  ClaudeUsageWidgets
//

import SwiftUI
import WidgetKit

/// One rendered moment of the widget.
struct UsageWidgetEntry: TimelineEntry {
    enum State: Equatable {
        /// Layout-only placeholder; contains no usage values.
        case placeholder
        /// A validated snapshot read from the shared store.
        case snapshot(UsageSnapshot)
        /// Nothing to show yet, with the reason.
        case unavailable(UsageProviderError)
    }

    let date: Date
    let state: State
}

/// Reads the last validated snapshot from the App Group store. No network access.
struct UsageWidgetProvider: TimelineProvider {

    func placeholder(in context: Context) -> UsageWidgetEntry {
        UsageWidgetEntry(date: .now, state: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageWidgetEntry) -> Void) {
        // The gallery shows the user's real data when available, otherwise
        // setup guidance — never invented numbers.
        completion(UsageWidgetEntry(date: .now, state: loadState()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageWidgetEntry>) -> Void) {
        let now = Date.now
        let state = loadState()
        let snapshot: UsageSnapshot? = if case .snapshot(let value) = state { value } else { nil }
        let entries = WidgetTimelinePlanner.entryDates(now: now, snapshot: snapshot)
            .map { UsageWidgetEntry(date: $0, state: state) }
        // The app also calls reloadAllTimelines() when new data arrives.
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func loadState() -> UsageWidgetEntry.State {
        do {
            let store = try UsageStore.shared()
            guard let snapshot = try store.load() else {
                return .unavailable(.sourceNotFound)
            }
            return .snapshot(snapshot)
        } catch {
            return .unavailable(error)
        }
    }
}
