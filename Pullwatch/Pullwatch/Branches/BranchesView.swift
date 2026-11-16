import PullwatchCore
import SwiftUI

/// Het onderdeel Branches: per gevolgde repo een boom vanaf de standaardbranch, elke branch onder
/// de branch waar hij van gemaakt is, met wie het laatst pushte, hoe ver hij voor en achter ligt
/// op zijn ouder en wanneer. Laad opnieuw, de filters op repo en persoon, "Alleen anderen",
/// verwijderde branches tonen en zoeken in de knoppenbalk, en wanneer de branches gecheckt zijn
/// als ondertitel. Het inspectievenster toont de gekozen branch en zijn pushes.
struct BranchesView: View {
    /// Het symbool van het onderdeel in de zijbalk en de lege staat: de Octicon git-branch, zoals
    /// GitHub branches toont (`branch.symbolset`, zie NOTICE).
    static let glyph: Glyph = .asset("branch")

    @Environment(BranchesModel.self) private var branches
    @Environment(HistoryModel.self) private var history
    @Environment(AppRouter.self) private var router
    @Environment(PollingModel.self) private var polling

    @State private var filter = BranchFilter()
    @State private var selection: BranchRow.ID?
    @State private var showsRemoved = false
    @State private var showsInspector = true
    /// Dichtgeklapte repo's (`RepoBranches.id`).
    @State private var collapsed: Set<String> = []
    /// De zichtbare rijen; opnieuw berekend als filter, boom of log verandert.
    @State private var rows: [BranchRow] = []

    private struct Query: Equatable {
        let filter: BranchFilter
        let showsRemoved: Bool
        let collapsed: Set<String>
        let trees: [RepoBranches]
        let pushes: [BranchPush]
    }

    private func recompute() {
        rows = BranchTree.rows(
            trees: branches.trees, filter: filter, showRemoved: showsRemoved, collapsed: collapsed,
            recentKinds: BranchTree.recentKinds(of: branches.log.pushes))
        if let selection, !rows.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    private var selected: BranchRow? {
        selection.flatMap { id in rows.first { $0.id == id } }
    }

    /// De repo's en personen in de boom, voor de filters in de knoppenbalk.
    private var repos: [String] {
        Set(branches.trees.map(\.repo)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var authors: [String] {
        Set(branches.trees.flatMap { $0.branches.values.compactMap(\.authorName) })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        BranchesTable(
            rows: rows, selection: $selection,
            toggle: toggle,
            open: { branches.open($0) },
            filterAuthor: { filter.author = $0 }
        )
        .overlay {
            if branches.trees.allSatisfy({ $0.branches.isEmpty }) {
                ContentUnavailableView {
                    Label {
                        Text("Nog geen branches")
                    } icon: {
                        Self.glyph.image
                    }
                } description: {
                    Text("Pullwatch toont hier de branches van repositories die je volgt.")
                } actions: {
                    Button("Branches volgen") { router.showSettings(.accounts) }
                }
            } else if rows.isEmpty {
                FilteredEmptyView(searchText: filter.searchText) { filter = BranchFilter() }
            }
        }
        .inspector(isPresented: $showsInspector) {
            BranchInspectorColumn(row: selected, trees: branches.trees, branches: branches, history: history)
                .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
        }
        .searchable(text: $filter.searchText, prompt: Text("Zoek op branch, repo of persoon…"))
        .searchShortcut()
        .navigationTitle(Text("Branches"))
        .navigationSubtitle(CheckedSubtitle.text(polling.branchesCheckedAt))
        .toolbar {
            ToolbarItem {
                Button {
                    polling.refresh()
                } label: {
                    Label("Laad opnieuw", systemImage: "arrow.clockwise")
                }
                .disabled(polling.isRefreshing)
                .help("Haal de branches nu op")
            }
            ToolbarItem {
                ValueFilterMenu(title: "Repo", allTitle: "Alle repo's", systemImage: "folder", values: repos, selection: $filter.repo)
                    .help("Toon alleen de branches van één repo")
            }
            ToolbarItem {
                ValueFilterMenu(title: "Persoon", allTitle: "Iedereen", systemImage: "person", values: authors, selection: $filter.author)
                    .help("Toon alleen de branches waar één persoon het laatst op pushte")
            }
            ToolbarItem {
                Toggle("Alleen anderen", systemImage: "person.2", isOn: $filter.othersOnly)
                    .help("Verberg de branches waar jij het laatst op pushte")
            }
            ToolbarItem {
                Toggle("Verwijderde branches", systemImage: "trash", isOn: $showsRemoved)
                    .help("Toon ook branches die gemerged of weggehaald zijn")
            }
            ToolbarItem {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Inspectievenster", systemImage: "sidebar.trailing")
                }
                .help("Toon of verberg het inspectievenster")
            }
        }
        .onChange(of: Query(
            filter: filter, showsRemoved: showsRemoved, collapsed: collapsed, trees: branches.trees, pushes: branches.log.pushes
        ), initial: true) {
            recompute()
        }
        .onChange(of: selection) { _, id in
            if id != nil { showsInspector = true }
        }
        .focusedSceneValue(\.browserTarget, selected?.info.map { .page($0.parentCompareURL ?? $0.webURL) })
    }

    private func toggle(_ treeId: String) {
        if collapsed.remove(treeId) == nil { collapsed.insert(treeId) }
    }
}

/// De inhoud van het inspectievenster: de gekozen branch, of wat er te kiezen valt.
private struct BranchInspectorColumn: View {
    let row: BranchRow?
    let trees: [RepoBranches]
    let branches: BranchesModel
    let history: HistoryModel

    var body: some View {
        if let row, let info = row.info, let tree = trees.first(where: { $0.id == row.treeId }) {
            BranchInspector(
                info: info, tree: tree,
                pushes: branches.pushes(accountId: row.accountId, repo: row.repo, branch: info.name),
                pullRequestTitle: info.pullRequest.flatMap { number in
                    let key = "\(row.accountId.uuidString):\(row.repo):\(number)"
                    guard case .pullRequest(let pr)? = history.history.items.first(where: { $0.id == key })?.entry else { return nil }
                    return pr.title
                },
                open: { branches.open($0) }
            )
        } else {
            ContentUnavailableView {
                Label("Niets gekozen", systemImage: "sidebar.trailing")
            } description: {
                Text("Kies een branch om te zien waar hij van gemaakt is en wie erop pushte.")
            }
        }
    }
}

/// De boom als tabel; een klik op een naam filtert op die persoon, een klik op een repo klapt hem
/// open of dicht.
private struct BranchesTable: View {
    let rows: [BranchRow]
    @Binding var selection: BranchRow.ID?
    let toggle: (String) -> Void
    let open: (URL) -> Void
    let filterAuthor: (String) -> Void

    private func row(_ id: BranchRow.ID?) -> BranchRow? {
        id.flatMap { id in rows.first { $0.id == id } }
    }

    // De ideale breedtes passen samen met het inspectievenster in het hoofdvenster op zijn
    // kleinste maat; een breder venster geeft de ruimte vooral aan de naam.
    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("Branch") { row in
                BranchNameCell(row: row) { toggle(row.treeId) }
            }
            .width(min: 160, ideal: 240)
            TableColumn("Wie") { row in
                if let info = row.info, let name = info.authorName {
                    Button {
                        filterAuthor(name)
                    } label: {
                        BranchAuthorLabel(name: name, avatarURL: info.authorAvatarURL)
                    }
                    .buttonStyle(.plain)
                    .opacity(info.removedAt == nil ? 1 : 0.5)
                    .help(Text("Toon alleen de branches van \(name)", comment: "Naam van een persoon"))
                    .accessibilityLabel(Text(verbatim: name))
                    .accessibilityHint(Text("Toon alleen de branches van \(name)", comment: "Naam van een persoon"))
                }
            }
            .width(min: 80, ideal: 100)
            TableColumn("Voor / achter") { row in
                if let info = row.info, !row.isDefault, info.removedAt == nil {
                    BranchDistanceLabel(comparison: info.againstParent)
                }
            }
            .width(min: 70, ideal: 80)
            TableColumn("Laatste push") { row in
                if let date = row.info?.lastPushAt {
                    HStack(spacing: 5) {
                        if row.pushedRecently {
                            Circle().fill(.tint).frame(width: 6, height: 6)
                                .accessibilityLabel(Text("In het afgelopen uur"))
                        }
                        RelativeDateText(date: date)
                    }
                    .foregroundStyle(.secondary)
                    .help(date.formatted(date: .complete, time: .standard))
                }
            }
            .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: BranchRow.ID.self) { ids in
            if let row = row(ids.first), let info = row.info {
                if let url = info.parentCompareURL, info.parent != nil {
                    Button("Vergelijk met ouder") { open(url) }
                }
                Button("Open in browser") { open(info.webURL) }
                Button("Kopieer branchnaam") { Pasteboard.copy(info.name) }
            }
        } primaryAction: { ids in
            guard let row = row(ids.first) else { return }
            if let info = row.info {
                open(info.parentCompareURL ?? info.webURL)
            } else {
                toggle(row.treeId)
            }
        }
    }
}
