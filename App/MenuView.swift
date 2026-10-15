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

            if model.recent.items.isEmpty {
                Text("Nog geen nieuwe PR's").foregroundStyle(.secondary)
            } else {
                ForEach(model.recent.items.prefix(10)) { item in
                    RecentRow(item: item) { model.open(item) }
                }
            }

            if !model.config.accounts.isEmpty {
                Divider()
                ForEach(model.config.accounts) { account in
                    AccountStatusRow(account: account, state: model.statuses[account.id] ?? .idle)
                }
            }

            Divider()

            HStack {
                Button("Alles gelezen") { model.markAllRead() }
                    .disabled(model.recent.unreadCount == 0)
                Spacer()
                SettingsButton()
                Button("Stop") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 360)
    }
}

struct SettingsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Instellingen…") {
            openWindow(id: "settings")
            NSApp.activate()
        }
    }
}

private struct RecentRow: View {
    let item: RecentItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(item.isRead ? Color.clear : Color.accentColor)
                    .frame(width: 6, height: 6)
                    .padding(.top, 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.pullRequest.title).lineLimit(1)
                    HStack(spacing: 4) {
                        Text("\(item.pullRequest.repo) · \(item.pullRequest.authorName) ·")
                        Text(item.pullRequest.createdAt, format: .relative(presentation: .named))
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

    var body: some View {
        HStack(spacing: 4) {
            Text(account.displayName).font(.caption.bold())
            switch state {
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
