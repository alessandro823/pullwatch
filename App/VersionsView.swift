import AppKit
import PullwatchCore
import SwiftUI

struct VersionsView: View {
    let model: AppModel

    private enum SortOrder: String {
        case status, name
    }

    @State private var searchText = ""
    @AppStorage("versionsSortOrder") private var sortOrder: SortOrder = .status

    /// Zoekt op repo, onderdeel (bv. "Node"), versie, kwetsbaar package en CVE/OSV-id;
    /// de report-volgorde is al slechtste status eerst.
    private func repos(in report: VersionReport) -> [RepoVersions] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? report.repos : report.repos.filter { repo in
            repo.repo.localizedCaseInsensitiveContains(query)
                || repo.components.contains {
                    $0.label.localizedCaseInsensitiveContains(query) || $0.version.hasPrefix(query)
                }
                || repo.vulnerabilities.contains {
                    $0.package.localizedCaseInsensitiveContains(query)
                        || $0.id.localizedCaseInsensitiveContains(query)
                        || ($0.cve?.localizedCaseInsensitiveContains(query) ?? false)
                }
        }
        switch sortOrder {
        case .status: return matching
        case .name: return matching.sorted { $0.repo.localizedCaseInsensitiveCompare($1.repo) == .orderedAscending }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Zoek op repo, taal, versie of CVE…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Picker("Sorteren", selection: $sortOrder) {
                    Text("Status").tag(SortOrder.status)
                    Text("Naam").tag(SortOrder.name)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
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
                    .help("Leest per gevolgde repo de taal- en frameworkversies en vergelijkt ze met endoflife.date; packages gaan langs OSV.dev voor bekende CVE's")
                }
            }

            if let report = model.versionReport {
                let shown = repos(in: report)
                if shown.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(shown) { repo in
                        RepoVersionsRow(repo: repo)
                    }
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
    @State private var copied = false

    private var dotColor: Color {
        repo.vulnerabilities.isEmpty ? (repo.worstStatus?.color ?? .secondary.opacity(0.4)) : VersionStatus.eol.color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                Text(repo.repo).fontWeight(.semibold)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(repo.clipboardText, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Kopieer de versies van deze repo naar het klembord")
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
                if let vulnerabilityError = repo.vulnerabilityError {
                    Text(vulnerabilityError).foregroundStyle(.orange)
                }
                if !repo.vulnerabilities.isEmpty {
                    VulnerabilityList(vulnerabilities: repo.vulnerabilities)
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

private struct VulnerabilityList: View {
    let vulnerabilities: [Vulnerability]
    @State private var isExpanded = false

    private var title: String {
        let count = vulnerabilities.count
        let bySeverity = ["CRITICAL", "HIGH", "MODERATE", "LOW"].compactMap { severity -> String? in
            let n = vulnerabilities.filter { $0.severity == severity }.count
            return n > 0 ? "\(n) \(severity.lowercased())" : nil
        }
        let detail = bySeverity.isEmpty ? "" : " (\(bySeverity.joined(separator: ", ")))"
        return "\(count) \(count == 1 ? "kwetsbaarheid" : "kwetsbaarheden")\(detail)"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(vulnerabilities, id: \.self) { vulnerability in
                    VulnerabilityRow(vulnerability: vulnerability)
                }
            }
        } label: {
            // In een List reageert alleen het pijltje; zo klapt de hele regel open.
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                Label(title, systemImage: "exclamationmark.shield")
                    .foregroundStyle(VersionStatus.eol.color)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

private struct VulnerabilityRow: View {
    let vulnerability: Vulnerability

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                SeverityPill(severity: vulnerability.severity)
                Link(vulnerability.cve ?? vulnerability.id, destination: vulnerability.url)
                Text(packageText).monospacedDigit().foregroundStyle(.secondary)
            }
            if let summary = vulnerability.summary {
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .help("\(vulnerability.id) — \(vulnerability.source)")
    }

    private var packageText: String {
        let base = "\(vulnerability.package) \(vulnerability.version)"
        return vulnerability.fixedIn.map { "\(base) → \($0)" } ?? base
    }
}

private struct SeverityPill: View {
    let severity: String?

    private var color: Color {
        switch severity {
        case "CRITICAL": .red
        case "HIGH": .orange
        case "MODERATE", "MEDIUM": .yellow
        default: .gray
        }
    }

    var body: some View {
        Text((severity ?? "?").capitalized)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
    }
}

extension RepoVersions {
    /// Platte tekst voor het klembord: repo, onderdelen en kwetsbaarheden.
    var clipboardText: String {
        var lines = [repo]
        if let error { lines.append("Fout: \(error)") }
        for component in components {
            var line = "\(component.label) \(component.version)"
            if let latest = component.latest, component.status != .current { line += " → \(latest)" }
            lines.append("\(line) (\(component.status.label))")
        }
        if let vulnerabilityError { lines.append(vulnerabilityError) }
        if !vulnerabilities.isEmpty {
            lines.append("Kwetsbaarheden:")
            for v in vulnerabilities {
                var line = "- \(v.cve ?? v.id)"
                if let severity = v.severity { line += " [\(severity)]" }
                line += " \(v.package) \(v.version)"
                if let fixedIn = v.fixedIn { line += " → \(fixedIn)" }
                if let summary = v.summary { line += ": \(summary)" }
                line += " (\(v.url.absoluteString))"
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
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
