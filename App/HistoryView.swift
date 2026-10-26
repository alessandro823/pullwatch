import AppKit
import PullwatchCore
import SwiftUI

struct HistoryView: View {
    let model: AppModel

    private enum Filter: Hashable {
        case all, pullRequests, tags

        var kind: ItemKind? {
            switch self {
            case .all: nil
            case .pullRequests: .pullRequest
            case .tags: .tag
            }
        }
    }

    @State private var searchText = ""
    @State private var filter: Filter = .all
    // Zonder selectie-binding vuurt de primaryAction (dubbelklik) van contextMenu niet.
    @State private var selection = Set<HistoryItem.ID>()
    @Environment(\.openWindow) private var openWindow

    private var items: [HistoryItem] {
        model.history.search(searchText, kind: filter.kind)
    }

    /// Repo van de selectie, als die over één repo gaat.
    private var selectedRepo: String? {
        let repos = Set(model.history.items.filter { selection.contains($0.id) }.map(\.entry.repo))
        return repos.count == 1 ? repos.first : nil
    }

    /// Opent het Versies-venster, gefilterd op `repo` als die er is.
    private func showVersions(of repo: String?) {
        model.versionsSearch = repo ?? ""
        openWindow(id: "versions")
        NSApp.activate()
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("Zoek op titel, auteur, repo…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Picker("Soort", selection: $filter) {
                    Text("Alles").tag(Filter.all)
                    Text("PR's").tag(Filter.pullRequests)
                    Text("Tags").tag(Filter.tags)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if let progress = model.refetch {
                    ProgressView(value: Double(progress.done), total: Double(progress.total))
                        .frame(width: 100)
                    Text("Ophalen… \(progress.done)/\(progress.total) accounts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Button("Opnieuw ophalen") {
                        Task { await model.refetchHistory() }
                    }
                    .help("Haalt de PR's van alle accounts opnieuw op binnen de bewaartermijn, één account tegelijk (zonder meldingen)")
                }
                Button {
                    showVersions(of: selectedRepo)
                } label: {
                    Label("Versies", systemImage: "shippingbox")
                }
                .help(selectedRepo.map { "Toon de versies van \($0)" } ?? "Open het versie-overzicht")
            }

            Table(items, selection: $selection) {
                TableColumn("Type") { item in
                    KindPill(kind: item.entry.kind)
                }
                .width(50)
                TableColumn("Status") { item in
                    if let state = item.entry.prState {
                        StatePill(state: state)
                    }
                }
                .width(80)
                TableColumn("Titel") { item in
                    Text(item.entry.title)
                        .fontWeight(item.isRead ? .regular : .bold)
                        .lineLimit(1)
                }
                TableColumn("Repo") { item in
                    Text(item.entry.repo).lineLimit(1)
                }
                TableColumn("Auteur") { item in
                    Text(item.entry.author ?? "—").lineLimit(1)
                }
                .width(min: 80, ideal: 120)
                TableColumn("Wanneer") { item in
                    Text(item.detectedAt, format: .relative(presentation: .named))
                        .help(item.detectedAt.formatted(date: .complete, time: .standard))
                }
                .width(min: 90, ideal: 130)
            }
            .contextMenu(forSelectionType: HistoryItem.ID.self) { ids in
                let repos = Set(model.history.items.filter { ids.contains($0.id) }.map(\.entry.repo))
                if repos.count == 1, let repo = repos.first {
                    Button("Toon versies van \(repo)") { showVersions(of: repo) }
                }
            } primaryAction: { ids in
                for id in ids {
                    if let item = model.history.items.first(where: { $0.id == id }) {
                        model.open(item)
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 720, minHeight: 420)
    }
}
