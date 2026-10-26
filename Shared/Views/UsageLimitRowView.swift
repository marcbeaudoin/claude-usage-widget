//
//  UsageLimitRowView.swift
//  Shared between the Claude Usage app and widget extension.
//

import SwiftUI
import WidgetKit

extension UsageSeverity {
    /// Semantic color. Always paired with a text cue (`label`) — never color alone.
    var color: Color {
        switch self {
        case .normal: .accentColor
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// Horizontal bar representing usage (not remaining capacity), clamped to 0…100%.
struct UsageProgressBar: View {
    let fraction: Double
    let severity: UsageSeverity
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(severity.color)
                    .frame(width: max(proxy.size.width * fraction, fraction > 0 ? height : 0))
                    .widgetAccentable()
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// One limit row: title, used %, bar, remaining %, reset time and countdown,
/// with explicit unavailable / over-limit / reset-passed states (§8.2).
struct UsageLimitRowView: View {
    let limit: UsageLimit
    let now: Date
    var isStale = false
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let used = limit.usedPercentage, limit.availability == .reported {
                    if let label = limit.isOverLimit ? "Over limit" : UsageSeverity.forPercentage(used).label {
                        Text(label)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(UsageSeverity.forPercentage(used).color)
                    }
                    Text(UsageFormatting.percentText(used))
                        .font(compact ? .callout.weight(.bold) : .title3.weight(.bold))
                        .monospacedDigit()
                }
            }

            if let used = limit.usedPercentage, let fraction = limit.progressFraction, limit.availability == .reported {
                UsageProgressBar(fraction: fraction, severity: .forPercentage(used), height: compact ? 5 : 6)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let remaining = UsageFormatting.remainingText(for: limit) {
                        Text(remaining)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    resetView
                }
                .font(.caption)
            } else {
                Text(UsageFormatting.notAvailableText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(isStale ? 0.75 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var resetView: some View {
        if let resetsAt = limit.resetsAt {
            if resetsAt <= now {
                Text(compact ? UsageFormatting.resetPassedShortText : UsageFormatting.resetPassedText)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            } else {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(UsageFormatting.countdownText(resetsAt: resetsAt, now: now) ?? "")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                    if !compact {
                        Text(UsageFormatting.absoluteResetText(resetsAt))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            }
        } else {
            Text("No reset time reported")
                .foregroundStyle(.secondary)
        }
    }

    private var accessibilityText: String {
        var text = UsageFormatting.accessibilityLabel(for: limit, now: now)
        if isStale { text += ", data may be out of date" }
        return text
    }
}
