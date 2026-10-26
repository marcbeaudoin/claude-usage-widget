//
//  SetupGuideView.swift
//  ClaudeUsageWidget
//

import AppKit
import SwiftUI

/// In-app setup guide. The app is sandboxed and never edits Claude Code
/// settings itself; the user runs the bundled installer in Terminal, which
/// shows the proposed change and asks for confirmation.
struct SetupGuideView: View {
    @State private var copiedCommand: String?

    private var installCommand: String { command(for: "install-integration.sh") }
    private var uninstallCommand: String { command(for: "uninstall-integration.sh") }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Set up the Claude Code integration")
                    .font(.title2.weight(.semibold))

                Text("Claude Code passes subscription usage (`rate_limits`) to its status-line command. A small script records only those values in `~/Library/Application Support/ClaudeUsage/usage.json`, which this app and its widget read. Usage is reported only for Claude Pro and Max subscribers, after the first response in a session.")
                    .fixedSize(horizontal: false, vertical: true)

                step(1, "Run the installer in Terminal", detail: "It checks for Claude Code and jq, backs up `~/.claude/settings.json`, shows the exact change, and asks before writing. An existing status line is kept: the script runs it and shows its output unchanged.", command: installCommand)

                step(2, "Use Claude Code", detail: "Start or resume a session and send a message. The status line runs after each response and the menu-bar item updates within a few seconds.", command: nil)

                step(3, "Add the widget", detail: "Right-click the desktop → Edit Widgets… → search for “Claude Usage”.", command: nil)

                Divider()

                Text("Manual setup").font(.headline)
                Text("If you prefer to edit settings yourself, copy the script to `~/Library/Application Support/ClaudeUsage/bin/` and set:")
                codeBlock("""
                "statusLine": {
                  "type": "command",
                  "command": "\\"$HOME/Library/Application Support/ClaudeUsage/bin/claude-usage-statusline.sh\\""
                }
                """)
                Text("To keep an existing status line, put its command in `~/Library/Application Support/ClaudeUsage/wrapped-command`; the script pipes the same input to it and prints its output.")
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text("Uninstall").font(.headline)
                Text("Restores your previous status line from the installer's backup and asks whether to delete the local usage snapshot.")
                commandRow(uninstallCommand)
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 520)
    }

    private func command(for script: String) -> String {
        let path = Bundle.main.url(forResource: script, withExtension: nil)?.path ?? script
        return "bash '\(path)'"
    }

    private func step(_ number: Int, _ title: String, detail: String, command: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(number). \(title)").font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let command { commandRow(command) }
        }
    }

    private func commandRow(_ command: String) -> some View {
        HStack(alignment: .top) {
            codeBlock(command)
            Button(copiedCommand == command ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copiedCommand = command
            }
        }
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}
