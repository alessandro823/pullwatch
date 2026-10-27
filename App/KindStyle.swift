import PullwatchCore
import SwiftUI

extension ItemKind {
    var color: Color {
        switch self {
        case .pullRequest: .blue
        case .tag: .orange
        }
    }

    var symbol: String {
        switch self {
        case .pullRequest: "arrow.triangle.pull"
        case .tag: "tag"
        }
    }

    var pillText: String {
        switch self {
        case .pullRequest: "PR"
        case .tag: "TAG"
        }
    }
}

/// Kleine gekleurde pill met de soort van een item.
struct KindPill: View {
    let kind: ItemKind

    var body: some View {
        Text(kind.pillText)
            .font(.caption2.bold())
            .foregroundStyle(kind.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(kind.color.opacity(0.15), in: Capsule())
    }
}

extension PRState {
    var color: Color {
        switch self {
        case .open: .green
        case .merged: .purple
        case .closed: .gray
        }
    }

    var label: String {
        switch self {
        case .open: String(localized: "Open")
        case .merged: String(localized: "Gemerged")
        case .closed: String(localized: "Gesloten")
        }
    }
}

/// Kleine gekleurde pill met de status van een pull request.
struct StatePill: View {
    let state: PRState

    var body: some View {
        Text(state.label)
            .font(.caption2.bold())
            .foregroundStyle(state.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(state.color.opacity(0.15), in: Capsule())
    }
}
