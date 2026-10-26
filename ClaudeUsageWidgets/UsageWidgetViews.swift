//
//  UsageWidgetViews.swift
//  ClaudeUsageWidgets
//

import SwiftUI
import WidgetKit

/// Dispatches to the layout for the current family.
struct UsageWidgetEntryView: View {
    let entry: UsageWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch entry.state {
            case .placeholder:
                PlaceholderWidgetView(family: family)
                    .redacted(reason: .placeholder)
            case .unavailable(let error):
                SetupWidgetView(error: error, family: family)
            case .snapshot(let snapshot):
                switch family {
                case .systemSmall:
                    SmallUsageWidgetView(snapshot: snapshot, now: entry.date)
                case .systemLarge, .systemExtraLarge:
                    LargeUsageWidgetView(snapshot: snapshot, now: entry.date)
                default:
                    MediumUsageWidgetView(snapshot: snapshot, now: entry.date)
                }
            }
        }
        .widgetURL(DeepLink.open.url)
    }
}

// MARK: - Helpers

private extension UsageSnapshot {
    func isStale(at now: Date) -> Bool {
        Freshness.evaluate(observedAt: observedAt, now: now) == .stale
    }

    /// Session and weekly limits, substituting explicit "not reported" rows when missing.
    var coreLimits: [UsageLimit] {
        [
            limit(kind: .fiveHour) ?? UsageLimit(id: "session", title: "Current session", kind: .fiveHour, usedPercentage: nil, resetsAt: nil),
            limit(kind: .sevenDay) ?? UsageLimit(id: "weekly", title: "Weekly limit", kind: .sevenDay, usedPercentage: nil, resetsAt: nil),
        ]
    }

    var additionalLimits: [UsageLimit] {
        orderedLimits.filter { $0.kind != .fiveHour && $0.kind != .sevenDay }
    }
}

/// "Updated 3 min ago" with a stale cue that does not rely on color.
struct WidgetFreshnessLabel: View {
    let snapshot: UsageSnapshot
    let now: Date

    var body: some View {
        let stale = snapshot.isStale(at: now)
        HStack(spacing: 3) {
            Image(systemName: stale ? "exclamationmark.triangle.fill" : "clock")
            Text(stale ? "Stale · " + UsageFormatting.updatedText(observedAt: snapshot.observedAt, now: now)
                       : UsageFormatting.updatedText(observedAt: snapshot.observedAt, now: now))
        }
        .font(.caption2)
        .foregroundStyle(stale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stale ? "Data is stale, " + UsageFormatting.updatedText(observedAt: snapshot.observedAt, now: now)
                                  : UsageFormatting.updatedText(observedAt: snapshot.observedAt, now: now))
    }
}

// MARK: - Small

/// Most important limit: session, else weekly (§8.3).
struct SmallUsageWidgetView: View {
    let snapshot: UsageSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let limit = snapshot.primaryLimit, let used = limit.usedPercentage {
                Text(limit.kind == .fiveHour ? "Session" : limit.kind == .sevenDay ? "Weekly" : limit.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(UsageFormatting.percentText(used))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                    if let label = limit.isOverLimit ? "Over" : UsageSeverity.forPercentage(used).label {
                        Text(label)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(UsageSeverity.forPercentage(used).color)
                    }
                }
                UsageProgressBar(fraction: limit.progressFraction ?? 0, severity: .forPercentage(used))
                Text(UsageFormatting.countdownText(resetsAt: limit.resetsAt, now: now, short: true) ?? "No reset time")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                WidgetFreshnessLabel(snapshot: snapshot, now: now)
            } else {
                Text("Claude Usage").font(.caption.weight(.semibold))
                Text(UsageFormatting.notAvailableText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                WidgetFreshnessLabel(snapshot: snapshot, now: now)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snapshot.primaryLimit.map { UsageFormatting.accessibilityLabel(for: $0, now: now) } ?? "Claude usage, \(UsageFormatting.notAvailableText)")
    }
}

// MARK: - Medium

/// Session + weekly with remaining and countdown (§8.4).
struct MediumUsageWidgetView: View {
    let snapshot: UsageSnapshot
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Claude Usage").font(.caption.weight(.bold))
                Spacer()
                WidgetFreshnessLabel(snapshot: snapshot, now: now)
            }
            ForEach(snapshot.coreLimits) { limit in
                UsageLimitRowView(limit: limit, now: now, isStale: snapshot.isStale(at: now), compact: true)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Large

/// Core limits, any additional reported limits, and source status (§8.5).
struct LargeUsageWidgetView: View {
    let snapshot: UsageSnapshot
    let now: Date

    /// Keep text readable: show at most this many additional limits.
    private let maxAdditional = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Claude Usage").font(.headline)
                Spacer()
                WidgetFreshnessLabel(snapshot: snapshot, now: now)
            }
            ForEach(snapshot.coreLimits) { limit in
                UsageLimitRowView(limit: limit, now: now, isStale: snapshot.isStale(at: now))
            }
            let extra = snapshot.additionalLimits
            if !extra.isEmpty {
                Divider()
                ForEach(extra.prefix(maxAdditional)) { limit in
                    UsageLimitRowView(limit: limit, now: now, isStale: snapshot.isStale(at: now), compact: true)
                }
                if extra.count > maxAdditional {
                    Text("+\(extra.count - maxAdditional) more in the app")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text("Source: Claude Code status line")
                Spacer()
                // Opens the app and refreshes its data; WidgetKit decides when this widget reloads.
                Link(destination: DeepLink.refresh.url) {
                    Label("Refresh in app", systemImage: "arrow.clockwise")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Empty / placeholder

struct SetupWidgetView: View {
    let error: UsageProviderError
    let family: WidgetFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Claude Usage", systemImage: "gauge.with.dots.needle.0percent")
                .font(.caption.weight(.bold))
            Text(error == .sourceNotFound ? "No usage data yet" : error.title)
                .font(.subheadline.weight(.semibold))
            Text(family == .systemSmall ? "Open the app to set up." : "Open the Claude Usage app and follow the setup guide, then use Claude Code.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// Structure-only placeholder: titles and empty bars, no values.
struct PlaceholderWidgetView: View {
    let family: WidgetFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude Usage").font(.caption.weight(.bold))
            ForEach(0..<(family == .systemSmall ? 1 : 2), id: \.self) { _ in
                Text("Usage limit").font(.caption)
                UsageProgressBar(fraction: 0, severity: .normal)
                Text("Resets in --").font(.caption2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
