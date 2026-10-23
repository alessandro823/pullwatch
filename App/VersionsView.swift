import PullwatchCore
import SwiftUI

struct VersionsView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let report = model.versionReport {
                    Text("Gecheckt \(report.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let progress = model.versionCheck {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .frame(width: 100)
                    Text("Checken… \(progress.done)/\(progress.total) repo's")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Button(model.versionReport == nil ? "Versies checken" : "Opnieuw checken") {
                        Task { await model.checkVersions() }
                    }
                    .help("Leest per gevolgde repo de taal- en frameworkversies en vergelijkt ze met endoflife.date")
                }
            }

            if let report = model.versionReport {
                List(report.repos) { repo in
                    RepoVersionsRow(repo: repo)
                }
            } else {
                ContentUnavailableView(
                    "Nog niet gecheckt",
                    systemImage: "shippingbox",
                    description: Text("Check welke gevolgde repo's achterlopen op taal- of frameworkversie.")
                )
            }
        }
        .padding(12)
        .frame(minWidth: 520, minHeight: 420)
    }
}

private struct RepoVersionsRow: View {
    let repo: RepoVersions

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(repo.worstStatus?.color ?? .secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text(repo.repo).fontWeight(.semibold)
            }
            Group {
                if let error = repo.error {
                    Text(error).foregroundStyle(.red)
                } else if repo.components.isEmpty {
                    Text("Niets herkend").foregroundStyle(.secondary)
                } else {
                    ForEach(repo.components, id: \.label) { component in
                        ComponentRow(component: component)
                    }
                }
            }
            .font(.callout)
            .padding(.leading, 14)
        }
        .padding(.vertical, 2)
    }
}

private struct ComponentRow: View {
    let component: ComponentVersion

    var body: some View {
        HStack(spacing: 6) {
            Text(component.label)
            Text(versionText).monospacedDigit().foregroundStyle(.secondary)
            VersionStatusPill(status: component.status)
        }
        .help(component.sources.joined(separator: "\n"))
    }

    private var versionText: String {
        guard let latest = component.latest, component.status != .current else { return component.version }
        return "\(component.version) → \(latest)"
    }
}

extension VersionStatus {
    var color: Color {
        switch self {
        case .current: .green
        case .behind: .orange
        case .eol: .red
        case .unknown: .gray
        }
    }

    var label: String {
        switch self {
        case .current: "Actueel"
        case .behind: "Achter"
        case .eol: "EOL"
        case .unknown: "Onbekend"
        }
    }
}

/// Kleine gekleurde pill met de versiestatus van een onderdeel.
struct VersionStatusPill: View {
    let status: VersionStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.bold())
            .foregroundStyle(status.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(status.color.opacity(0.15), in: Capsule())
    }
}
