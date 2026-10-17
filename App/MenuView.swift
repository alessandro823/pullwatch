import AppKit
import PullwatchCore
import SwiftUI

struct MenuView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pullwatch").font(.headline)
                Spacer()
                Button {
                    Task { await model.refreshNow() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Nu verversen")
            }

            if !model.notificationsAllowed {
                Label("Meldingen staan uit in Systeeminstellingen", systemImage: "bell.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            SectionHeader(title: "Pull requests")
            let pullRequests = model.history.latest(.pullRequest, limit: 5)
            if pullRequests.isEmpty {
                Text("Nog geen nieuwe PR's").foregroundStyle(.secondary)
            } else {
                ForEach(pullRequests) { item in
                    RecentRow(item: item) { model.open(item) }
                }
            }

            let tags = model.history.latest(.tag, limit: 5)
            if model.history.items.contains(where: { $0.entry.kind == .tag }) {
                SectionHeader(title: "Tags")
                ForEach(tags) { item in
                    RecentRow(item: item) { model.open(item) }
                }
            }

            if !model.config.accounts.isEmpty {
                Divider()
                ForEach(model.config.accounts) { account in
                    AccountStatusRow(
                        account: account,
                        state: model.statuses[account.id] ?? .idle,
                        isConfigured: model.config.pollableAccounts.contains { $0.id == account.id }
                    )
                }
            }

            Divider()

            HStack {
                Button("Alles gelezen") { model.markAllRead() }
                    .disabled(model.history.unreadCount == 0)
                Spacer()
                HistoryButton()
                SettingsButton()
                Button("Stop") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 460)
    }
}

struct SettingsButton: View {
    var body: some View {
        OpenWindowButton(title: "Instellingen…", windowId: "settings")
    }
}

struct HistoryButton: View {
    var body: some View {
        OpenWindowButton(title: "Geschiedenis…", windowId: "history")
    }
}

/// Opent een venster vanuit het menu: sluit eerst het menu-paneel (anders blijft het erboven
/// hangen) en haalt het venster daarna naar voren.
private struct OpenWindowButton: View {
    let title: String
    let windowId: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            let menuPanel = NSApp.keyWindow
            openWindow(id: windowId)
            menuPanel?.orderOut(nil)
            NSApp.activate()
            DispatchQueue.main.async {
                NSApp.windows
                    .first { $0.identifier?.rawValue.hasPrefix(windowId) == true }?
                    .makeKeyAndOrderFront(nil)
            }
        }
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title).font(.caption.bold()).foregroundStyle(.secondary)
    }
}

private struct RecentRow: View {
    let item: HistoryItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(item.isRead ? Color.clear : Color.accentColor)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                Image(systemName: item.entry.kind.symbol)
                    .foregroundStyle(item.entry.kind.color)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.entry.title).lineLimit(1)
                    HStack(spacing: 4) {
                        Text("\(item.entry.repo) · \(item.entry.author ?? "onbekend") ·")
                        Text(item.detectedAt, format: .relative(presentation: .named))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AccountStatusRow: View {
    let account: Account
    let state: AccountState
    let isConfigured: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(account.displayName).font(.caption.bold())
            switch state {
            case .idle where !isConfigured:
                Text("niet geconfigureerd").font(.caption).foregroundStyle(.secondary)
            case .idle:
                Text("wacht op eerste poll").font(.caption).foregroundStyle(.secondary)
            case .ok(let lastPoll):
                Text("✓").font(.caption).foregroundStyle(.green)
                Text(lastPoll, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
            case .failed(let error, _):
                Text(error.userMessage).font(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
    }
}
