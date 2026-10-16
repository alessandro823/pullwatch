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

    private var items: [HistoryItem] {
        model.history.search(searchText, kind: filter.kind)
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
            .contextMenu(forSelectionType: HistoryItem.ID.self) { _ in
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
