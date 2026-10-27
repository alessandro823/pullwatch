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
                || repo.release?.tag.localizedCaseInsensitiveContains(query) == true
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
                    // Geen List: op macOS groeit een List-rij niet mee als de CVE-lijst openklapt.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(shown) { repo in
                                RepoVersionsRow(model: model, repo: repo)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                Divider()
                            }
                        }
                    }
                    .background(.background)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
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
        .onChange(of: model.versionsSearch, initial: true) { _, search in
            guard let search else { return }
            searchText = search
            model.versionsSearch = nil
        }
    }
}

private struct RepoVersionsRow: View {
    let model: AppModel
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
                if let tag = repo.release?.tag {
                    Label(tag, systemImage: "tag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Nieuwste tag; ook gecheckt, zodat je ziet wat er in de laatste release zit")
                }
                Spacer()
                // Een accountfout staat onder de accountnaam (zonder "/"); daar valt niets los te checken.
                if repo.repo.contains("/") {
                    if model.refreshingRepos.contains(repo.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button {
                            Task { await model.refreshVersions(of: repo) }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.versionCheck != nil)
                        .help("Check deze repo opnieuw")
                    }
                }
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
                        ComponentRow(
                            component: component,
                            release: repo.release.map { release in
                                (release.tag, release.components.first { $0.label == component.label })
                            }
                        )
                    }
                }
                if let release = repo.release, let error = release.error {
                    Text("Tag \(release.tag) niet te checken: \(error)").foregroundStyle(.orange)
                }
                if let vulnerabilityError = repo.vulnerabilityError {
                    Text(vulnerabilityError).foregroundStyle(.orange)
                }
                if !repo.vulnerabilities.isEmpty {
                    VulnerabilityList(repo: repo)
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
    /// Nieuwste tag en hetzelfde onderdeel daarin; nil als de repo geen tags heeft.
    let release: (tag: String, component: ComponentVersion?)?

    var body: some View {
        HStack(spacing: 6) {
            Text(component.label)
            Text(component.versionText).monospacedDigit().foregroundStyle(.secondary)
            VersionStatusPill(status: component.status)
            // Ter info, zonder status: wat op main al bijgewerkt is telt niet.
            if let release, let old = release.component, old.version != component.version {
                Text("· \(release.tag): \(old.version)").monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .help(component.sources.joined(separator: "\n"))
    }
}

extension ComponentVersion {
    var versionText: String {
        guard let latest, status != .current else { return version }
        return "\(version) → \(latest)"
    }
}

private struct VulnerabilityList: View {
    let repo: RepoVersions
    @State private var isExpanded = false


    private var vulnerabilities: [Vulnerability] { repo.vulnerabilities }

    private var title: String {
        let count = vulnerabilities.count
        let bySeverity = ["CRITICAL", "HIGH", "MODERATE", "LOW"].compactMap { severity -> String? in
            let n = vulnerabilities.filter { $0.severity == severity }.count
            return n > 0 ? "\(n) \(severity.lowercased())" : nil
        }
        let detail = bySeverity.isEmpty ? "" : " (\(bySeverity.joined(separator: ", ")))"
        var text = "\(count) \(count == 1 ? "kwetsbaarheid" : "kwetsbaarheden")\(detail)"
        if let release = repo.release, release.error == nil {
            let inRelease = vulnerabilities.filter { repo.isInRelease($0) == true }.count
            text += " · \(inRelease) ook in \(release.tag)"
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Label(title, systemImage: "exclamationmark.shield")
                        .foregroundStyle(VersionStatus.eol.color)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(vulnerabilities.enumerated()), id: \.offset) { _, vulnerability in
                        VulnerabilityRow(vulnerability: vulnerability, location: repo.location(of: vulnerability))
                    }
                }
                .padding(.leading, 16)
            }
        }
    }
}

private struct VulnerabilityRow: View {
    let vulnerability: Vulnerability
    let location: VulnerabilityLocation?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                SeverityPill(severity: vulnerability.severity)
                Link(vulnerability.cve ?? vulnerability.id, destination: vulnerability.url)
                Text(packageText).monospacedDigit().foregroundStyle(.secondary)
                if let location {
                    LocationPill(location: location)
                }
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

/// Of een kwetsbaarheid van main ook in de laatste release zit.
enum VulnerabilityLocation {
    case alsoInRelease(tag: String)
    case mainOnly

    var label: String {
        switch self {
        case .alsoInRelease(let tag): "ook in \(tag)"
        case .mainOnly: "alleen main"
        }
    }

    var help: String {
        switch self {
        case .alsoInRelease(let tag): "Zit ook in de laatste release (\(tag))"
        case .mainOnly: "Nieuw sinds de laatste release; nog niet uitgebracht"
        }
    }

    var color: Color {
        switch self {
        case .alsoInRelease: .red
        case .mainOnly: .orange
        }
    }
}

private struct LocationPill: View {
    let location: VulnerabilityLocation

    var body: some View {
        Text(location.label)
            .font(.caption2)
            .foregroundStyle(location.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(location.color.opacity(0.5)))
            .help(location.help)
    }
}

extension RepoVersions {
    /// nil als er geen release gecheckt is.
    func location(of vulnerability: Vulnerability) -> VulnerabilityLocation? {
        guard let release, let inRelease = isInRelease(vulnerability) else { return nil }
        return inRelease ? .alsoInRelease(tag: release.tag) : .mainOnly
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
            lines.append("\(component.label) \(component.versionText) (\(component.status.label))")
        }
        if let release {
            lines.append("Laatste tag \(release.tag):")
            if let error = release.error { lines.append("Fout: \(error)") }
            for component in release.components {
                lines.append("  \(component.label) \(component.versionText) (\(component.status.label))")
            }
        }
        if let vulnerabilityError { lines.append(vulnerabilityError) }
        if !vulnerabilities.isEmpty {
            lines.append("Kwetsbaarheden:")
            for v in vulnerabilities {
                var line = "- \(v.cve ?? v.id)"
                if let location = location(of: v) { line += " {\(location.label)}" }
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
