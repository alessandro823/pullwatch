import PullwatchCore
import SwiftUI

/// Het onderdeel Branches: de pushes naar branches van de repo's die je volgt, nieuwste eerst, in
/// een tabel zoals die van PR's en Tags. Zoeken, filters op repo en persoon en "Alleen anderen" in
/// de knoppenbalk; dubbelklik opent de vergelijking (of de branch) in de browser.
struct BranchesView: View {
    /// Het symbool van het onderdeel in de zijbalk en de lege staat: de Octicon git-branch, zoals
    /// GitHub branches toont (`branch.symbolset`, zie NOTICE).
    static let glyph: Glyph = .asset("branch")

    @Environment(BranchesModel.self) private var branches
    @Environment(AppRouter.self) private var router

    @State private var filter = BranchFilter()
    @State private var selection: BranchPush.ID?
    @State private var sortOrder = [KeyPathComparator(\BranchPush.pushedAt, order: .reverse)]
    /// Gefilterd en gesorteerd; opnieuw berekend als filter, volgorde of log verandert.
    @State private var rows: [BranchPush] = []

    private struct Query: Equatable {
        let filter: BranchFilter
        let sortOrder: [KeyPathComparator<BranchPush>]
        let pushes: [BranchPush]
    }

    private func recompute() {
        // De nieuwste push eerst bij gelijke waarden, zodat de volgorde vast ligt.
        rows = filter.apply(branches.log.pushes).sorted(using: sortOrder + [KeyPathComparator(\BranchPush.pushedAt, order: .reverse)])
        if let selection, !rows.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    private var selected: BranchPush? {
        selection.flatMap { id in rows.first { $0.id == id } }
    }

    /// De repo's en personen in de log, voor de filters in de knoppenbalk.
    private var repos: [String] {
        Set(branches.log.pushes.map(\.repo)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var authors: [String] {
        Set(branches.log.pushes.compactMap(\.authorName)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        BranchesTable(
            rows: rows, selection: $selection, sortOrder: $sortOrder,
            open: { push in branches.open(push) },
            filterAuthor: { name in filter.author = name }
        )
        .overlay {
            if branches.log.pushes.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("Nog geen branches")
                    } icon: {
                        Self.glyph.image
                    }
                } description: {
                    Text("Pullwatch toont hier pushes naar branches van repositories die je volgt.")
                } actions: {
                    Button("Branches volgen") { router.showSettings(.accounts) }
                }
            } else if rows.isEmpty {
                FilteredEmptyView(searchText: filter.searchText) { filter = BranchFilter() }
            }
        }
        .searchable(text: $filter.searchText, prompt: Text("Zoek op branch, repo of persoon…"))
        .searchShortcut()
        .navigationTitle(Text("Branches"))
        .toolbar {
            ToolbarItem {
                BranchFilterMenu(
                    title: "Repo", allTitle: "Alle repo's", systemImage: "folder", values: repos, selection: $filter.repo
                )
                .help("Toon alleen pushes naar één repo")
            }
            ToolbarItem {
                BranchFilterMenu(
                    title: "Persoon", allTitle: "Iedereen", systemImage: "person", values: authors, selection: $filter.author
                )
                .help("Toon alleen pushes van één persoon")
            }
            ToolbarItem {
                Toggle("Alleen anderen", systemImage: "person.2", isOn: $filter.othersOnly)
                    .help("Verberg je eigen pushes")
            }
        }
        .onChange(of: Query(filter: filter, sortOrder: sortOrder, pushes: branches.log.pushes), initial: true) {
            recompute()
        }
        .focusedSceneValue(\.browserTarget, selected.map { .page($0.webURL) })
    }
}

/// De tabel; een klik op een naam filtert op die persoon.
private struct BranchesTable: View {
    let rows: [BranchPush]
    @Binding var selection: BranchPush.ID?
    @Binding var sortOrder: [KeyPathComparator<BranchPush>]
    let open: (BranchPush) -> Void
    let filterAuthor: (String) -> Void

    private func push(_ id: BranchPush.ID?) -> BranchPush? {
        id.flatMap { id in rows.first { $0.id == id } }
    }

    // De ideale breedtes passen samen in het hoofdvenster op zijn kleinste maat, zodat geen kolom
    // buiten beeld valt; een breder venster verdeelt de ruimte naar verhouding.
    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Branch", value: \.branchSortKey) { push in
                // In het midden afgekapt: het eind van een lange naam zegt het meest
                // (`dependabot/…/lodash-4.17.21`).
                Text(verbatim: push.branch)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(push.branch)
            }
            .width(min: 100, ideal: 118)
            TableColumn("Repo", value: \.repoSortKey) { push in
                Text(verbatim: push.repo)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(push.repo)
            }
            .width(min: 90, ideal: 130)
            TableColumn("Wie", value: \.authorSortKey) { push in
                if let name = push.authorName {
                    Button {
                        filterAuthor(name)
                    } label: {
                        BranchAuthorLabel(name: name, avatarURL: push.authorAvatarURL)
                    }
                    .buttonStyle(.plain)
                    .help(Text("Toon alleen pushes van \(name)", comment: "Naam van een persoon"))
                    .accessibilityLabel(Text(verbatim: name))
                    .accessibilityHint(Text("Toon alleen pushes van \(name)", comment: "Naam van een persoon"))
                } else {
                    Text("onbekend").foregroundStyle(.secondary)
                }
            }
            .width(min: 90, ideal: 95)
            TableColumn("Commits", value: \.commitsSortKey) { push in
                BranchKindLabel(kind: push.kind, commits: push.commits)
            }
            // Breed genoeg voor de langste pill ("Nouvelle branche").
            .width(min: 105, ideal: 105)
            TableColumn("Laatste push", value: \.pushedAt) { push in
                RelativeDateText(date: push.pushedAt)
                    .help(push.pushedAt.formatted(date: .complete, time: .standard))
            }
            .width(min: 90, ideal: 112)
        }
        .contextMenu(forSelectionType: BranchPush.ID.self) { ids in
            if let push = push(ids.first) {
                Button("Open in browser") { open(push) }
                Button("Kopieer branchnaam") { Pasteboard.copy(push.branch) }
            }
        } primaryAction: { ids in
            if let push = push(ids.first) { open(push) }
        }
    }
}

/// Een filter in de knoppenbalk: alles, of één waarde die in de log voorkomt.
private struct BranchFilterMenu: View {
    let title: LocalizedStringResource
    let allTitle: LocalizedStringResource
    let systemImage: String
    let values: [String]
    @Binding var selection: String?

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                Text(allTitle).tag(String?.none)
                ForEach(values, id: \.self) { value in
                    Text(verbatim: value).tag(Optional(value))
                }
            } label: {
                Text(title)
            }
            .pickerStyle(.inline)
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: selection == nil ? systemImage : "\(systemImage).fill")
            }
        }
    }
}
