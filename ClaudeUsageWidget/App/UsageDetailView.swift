//
//  UsageDetailView.swift
//  ClaudeUsageWidget
//

import SwiftUI

/// All supported limits plus freshness, provider and error state.
/// Used by the menu-bar popover and the details window.
struct UsageDetailView: View {
    let coordinator: UsageRefreshCoordinator

    var body: some View {
        // Re-render once a minute so countdowns and "Updated …" stay current
        // while visible. Nothing runs while the view is not on screen.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = coordinator.snapshot {
                let stale = Freshness.evaluate(observedAt: snapshot.observedAt, now: now) == .stale
                ForEach(rows(for: snapshot)) { limit in
                    UsageLimitRowView(limit: limit, now: now, isStale: stale)
                }
                FreshnessView(snapshot: snapshot, now: now)
            } else {
                EmptyStateView(error: coordinator.lastError ?? .sourceNotFound)
            }

            if let error = coordinator.lastError, coordinator.snapshot != nil {
                ErrorBanner(error: error)
            }

            Text("Source: \(coordinator.providerDisplayName)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Session and weekly rows are always shown (as unavailable if missing),
    /// followed by any other reported limits.
    private func rows(for snapshot: UsageSnapshot) -> [UsageLimit] {
        var rows = snapshot.orderedLimits
        if snapshot.limit(kind: .fiveHour) == nil {
            rows.insert(UsageLimit(id: "session", title: "Current session", kind: .fiveHour, usedPercentage: nil, resetsAt: nil), at: 0)
        }
        if snapshot.limit(kind: .sevenDay) == nil {
            let index = rows.firstIndex { $0.kind.displayPriority > UsageWindowKind.sevenDay.displayPriority } ?? rows.endIndex
            rows.insert(UsageLimit(id: "weekly", title: "Weekly limit", kind: .sevenDay, usedPercentage: nil, resetsAt: nil), at: index)
        }
        return rows
    }
}

struct FreshnessView: View {
    let snapshot: UsageSnapshot
    let now: Date

    var body: some View {
        let stale = Freshness.evaluate(observedAt: snapshot.observedAt, now: now) == .stale
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(UsageFormatting.updatedText(observedAt: snapshot.observedAt, now: now))
            } icon: {
                Image(systemName: stale ? "exclamationmark.triangle.fill" : "checkmark.circle")
            }
            .foregroundStyle(stale ? .orange : .secondary)
            if stale {
                Text("Stale — " + UsageFormatting.staleText(observedAt: snapshot.observedAt, now: now))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}

struct EmptyStateView: View {
    let error: UsageProviderError

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(error.title, systemImage: "gauge.with.dots.needle.0percent")
                .font(.headline)
            Text(error.recoveryMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct ErrorBanner: View {
    let error: UsageProviderError

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Refresh failed: \(error.title)").fontWeight(.semibold)
                Text(error.recoveryMessage).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.circle")
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
