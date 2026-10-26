//
//  DeepLink.swift
//  Shared between the Claude Usage app and widget extension.
//

import Foundation

/// Stable, documented deep links (README.md "Deep links").
///
/// - `claudeusage://open` — open the usage details window.
/// - `claudeusage://refresh` — open the details window and re-read the source.
///   This refreshes the app's data; it cannot force WidgetKit to reload immediately.
nonisolated enum DeepLink: String, CaseIterable, Sendable {
    case open
    case refresh

    static let scheme = "claudeusage"

    var url: URL {
        URL(string: "\(DeepLink.scheme)://\(rawValue)")!
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == DeepLink.scheme,
              let host = url.host()?.lowercased(),
              let link = DeepLink(rawValue: host)
        else { return nil }
        self = link
    }
}
