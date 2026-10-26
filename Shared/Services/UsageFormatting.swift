//
//  UsageFormatting.swift
//  Shared between the Claude Usage app and widget extension.
//

import Foundation

/// Data freshness relative to the last successful update (FR-4).
nonisolated enum Freshness: Equatable, Sendable {
    case fresh
    case stale

    /// Default freshness threshold: 15 minutes.
    static let defaultThreshold: TimeInterval = 15 * 60

    static func evaluate(observedAt: Date, now: Date, threshold: TimeInterval = defaultThreshold) -> Freshness {
        now.timeIntervalSince(observedAt) > threshold ? .stale : .fresh
    }
}

/// UI severity for a usage percentage (§8.2). These are display conventions,
/// not Claude-defined thresholds.
nonisolated enum UsageSeverity: Equatable, Sendable {
    case normal
    case warning
    case critical

    static func forPercentage(_ percentage: Double) -> UsageSeverity {
        switch percentage {
        case ..<70: .normal
        case ..<90: .warning
        default: .critical
        }
    }

    /// Text cue so state is never conveyed by color alone (FR-8).
    var label: String? {
        switch self {
        case .normal: nil
        case .warning: "High"
        case .critical: "Critical"
        }
    }
}

/// Pure formatting helpers. Every function takes `now`, `locale` and
/// `timeZone` explicitly so it is deterministic and testable; reset dates
/// are absolute instants converted to local time only at display time.
nonisolated enum UsageFormatting {

    static let notAvailableText = "Not available from this data source"
    static let resetPassedText = "Reset time passed — waiting for updated usage data"
    static let resetPassedShortText = "Awaiting updated data"

    /// Rounded whole percentage, e.g. `62%`.
    static func percentText(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// e.g. `38% left`.
    static func remainingText(for limit: UsageLimit) -> String? {
        guard let remaining = limit.remainingPercentage else { return nil }
        return "\(percentText(remaining)) left"
    }

    /// Compact duration: `45s`, `14m`, `2h 14m`, `3d 4h`.
    static func durationText(_ interval: TimeInterval) -> String {
        let total = max(Int(interval.rounded(.up)), 0)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    /// `Resets in 2h 14m`, or the reset-passed message. `nil` when no reset time is known.
    static func countdownText(resetsAt: Date?, now: Date, short: Bool = false) -> String? {
        guard let resetsAt else { return nil }
        guard resetsAt > now else { return short ? resetPassedShortText : resetPassedText }
        return "Resets in \(durationText(resetsAt.timeIntervalSince(now)))"
    }

    /// Absolute local reset time, e.g. `Mon 26 Oct, 09:00` (locale dependent).
    static func absoluteResetText(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar(locale: locale, timeZone: timeZone), timeZone: timeZone)
        style = style.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
        return date.formatted(style)
    }

    /// `Updated just now`, `Updated 2 min ago`, `Updated 3 h ago`, `Updated <date>`.
    static func updatedText(observedAt: Date, now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let elapsed = max(now.timeIntervalSince(observedAt), 0)
        switch elapsed {
        case ..<60:
            return "Updated just now"
        case ..<3_600:
            return "Updated \(Int(elapsed / 60)) min ago"
        case ..<86_400:
            return "Updated \(Int(elapsed / 3_600)) h ago"
        default:
            return "Updated \(absoluteResetText(observedAt, locale: locale, timeZone: timeZone))"
        }
    }

    /// Stale-data message (§13).
    static func staleText(observedAt: Date, now: Date) -> String {
        let minutes = Int(max(now.timeIntervalSince(observedAt), 0) / 60)
        let age = minutes < 60 ? "\(minutes) minutes" : durationText(Double(minutes) * 60)
        return "Last updated \(age) ago. Open Claude Code or refresh the source."
    }

    /// VoiceOver label, e.g. "Weekly limit, 78 percent used, 22 percent remaining, resets Mon 26 Oct at 09:00".
    static func accessibilityLabel(for limit: UsageLimit, now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard limit.availability == .reported, let used = limit.usedPercentage else {
            return "\(limit.title), \(notAvailableText)"
        }
        var parts = ["\(limit.title)", "\(Int(used.rounded())) percent used"]
        if limit.isOverLimit {
            parts.append("over limit")
        } else if let remaining = limit.remainingPercentage {
            parts.append("\(Int(remaining.rounded())) percent remaining")
        }
        if let label = UsageSeverity.forPercentage(used).label {
            parts.append(label.lowercased() + " usage")
        }
        if let resetsAt = limit.resetsAt {
            if resetsAt > now {
                parts.append("resets \(absoluteResetText(resetsAt, locale: locale, timeZone: timeZone)), in \(durationText(resetsAt.timeIntervalSince(now)))")
            } else {
                parts.append(resetPassedText)
            }
        }
        return parts.joined(separator: ", ")
    }

    private static func calendar(locale: Locale, timeZone: TimeZone) -> Calendar {
        var calendar = locale.calendar
        calendar.locale = locale
        calendar.timeZone = timeZone
        return calendar
    }
}
