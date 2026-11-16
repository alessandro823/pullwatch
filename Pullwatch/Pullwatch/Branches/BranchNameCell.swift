import PullwatchCore
import SwiftUI

/// De kolom Branch van de boom: bij een repo de naam met het klapje en hoeveel branches vandaag
/// een push kregen; bij een branch het symbool op zijn diepte, de naam en de pills (standaard,
/// PR, nieuw of force-push, gemerged of weggehaald). Leest geen model uit de environment, want
/// hij staat in een cel van een tabel.
struct BranchNameCell: View {
    let row: BranchRow
    let toggle: () -> Void

    var body: some View {
        switch row.kind {
        case .repo(let activeToday, let isCollapsed):
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    Text(verbatim: row.repo)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if activeToday > 0 {
                        Text("\(activeToday) actief vandaag", comment: "Branches van een repo met een push vandaag")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: row.repo))
            .accessibilityLabel(Text(verbatim: row.repo))
            .accessibilityHint(isCollapsed ? Text("Klap de branches van deze repo open") : Text("Klap de branches van deze repo dicht"))
        case .branch(let info):
            HStack(spacing: 5) {
                Group {
                    if row.isDefault {
                        Image(systemName: "smallcircle.filled.circle").foregroundStyle(.tint)
                    } else {
                        BranchesView.glyph.image.foregroundStyle(.secondary)
                    }
                }
                .frame(width: 14)
                Text(verbatim: info.name)
                    .fontWeight(row.isDefault ? .semibold : .regular)
                    .strikethrough(info.removedAt != nil)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(info.name)
                BranchPills(row: row, info: info)
            }
            .padding(.leading, CGFloat(row.depth) * 16)
            .opacity(info.removedAt == nil ? 1 : 0.5)
        }
    }
}

/// De pills achter de naam van een branch.
private struct BranchPills: View {
    let row: BranchRow
    let info: BranchInfo

    var body: some View {
        if row.isDefault {
            Pill(text: "standaard", tint: .secondary)
        }
        if let number = info.pullRequest {
            Pill(text: "#\(number)", tint: .purple)
                .accessibilityLabel(Text("Pull request \(number)", comment: "Nummer van een open PR vanaf deze branch"))
        }
        if info.removedAt != nil {
            Pill(text: info.merged ? "gemerged" : "weggehaald", tint: .secondary)
        } else if row.recentKind == .newBranch {
            Pill(text: "Nieuwe branch", tint: .green)
        } else if row.recentKind == .forcePush {
            Pill(text: "Force-push", tint: .orange)
        }
    }
}
