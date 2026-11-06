import PullwatchCore
import SwiftUI

/// Alle PR's of tags uit de geschiedenis in een tabel: zoeken, sorteren, filters als tokens.
struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @Environment(AccountsModel.self) private var accounts
    @Environment(HistoryModel.self) private var historyModel
    @Environment(PollingModel.self) private var polling
    @Environment(OverviewModel.self) private var overview
    @Environment(AppRouter.self) private var router
    let kind: ItemKind
    /// Alleen dit project (uit de zijbalk); nil voor alles.
    let group: HistoryGroup.ID?
    let groupName: String?

    @State private var searchText = ""
    /// Filters als tokens in het zoekveld: eerst die van de sprong hierheen, daarna wat de persoon
    /// weghaalt of uit het contextmenu toevoegt. Van deze lijst, net als de zoektekst.
    @State private var tokens: [HistoryToken]
    @State private var selection = Set<HistoryItem.ID>()
    @State private var sortOrder = [KeyPathComparator(\HistoryItem.detectedAt, order: .reverse)]
    /// Gefilterd en gesorteerd; opnieuw berekend als zoektekst, tokens, volgorde of geschiedenis verandert.
    @State private var rows: [HistoryItem] = []
    /// Auteurs die bij de zoektekst passen, als voorstel voor een token.
    @State private var suggestedAuthors: [String] = []
    /// Alleen bij tags: alles, alleen releases of alleen tags zonder release.
    @State private var tagFilter = TagFilter.all

    init(kind: ItemKind, group: HistoryGroup.ID? = nil, groupName: String? = nil, initialTokens: [HistoryToken] = []) {
        self.kind = kind
        self.group = group
        self.groupName = groupName
        _tokens = State(initialValue: initialTokens)
    }

    private struct Query: Equatable {
        let text: String
        let tokens: [HistoryToken]
        let sortOrder: [KeyPathComparator<HistoryItem>]
        let tagFilter: TagFilter
    }

    private var query: Query {
        Query(text: searchText, tokens: tokens, sortOrder: sortOrder, tagFilter: kind == .tag ? tagFilter : .all)
    }

    private func recompute() {
        let authors = Set(tokens.compactMap { if case .author(let name) = $0 { name } else { nil } })
        let repos = tokens.compactMap { if case .repo(let repo) = $0 { repo } else { nil } }
        let found = historyModel.history.search(searchText, kind: kind, group: group, providerKinds: accounts.config.providerKinds).filter { item in
            (authors.isEmpty || item.entry.author.map(authors.contains) == true)
                && (repos.isEmpty || repos.contains {
                    $0.accountId == item.entry.accountId && $0.repo.caseInsensitiveCompare(item.entry.repo) == .orderedSame
                })
                && query.tagFilter.includes(item.entry)
        }
        rows = found.sorted(using: sortOrder)

        let text = searchText.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            suggestedAuthors = []
        } else {
            let names = Set(historyModel.history.items.compactMap(\.entry.author)
                .filter { $0.localizedCaseInsensitiveContains(text) && !authors.contains($0) })
            suggestedAuthors = Array(names.sorted().prefix(5))
        }
    }

    /// Account en repo van deze items, als ze allemaal over één repo gaan.
    private func repo(of ids: Set<HistoryItem.ID>) -> HistoryRepo? {
        let entries = rows.filter { ids.contains($0.id) }.map(\.entry)
        guard let first = entries.first,
              entries.allSatisfy({ $0.accountId == first.accountId && $0.repo == first.repo }) else { return nil }
        return HistoryRepo(accountId: first.accountId, repo: first.repo)
    }

    /// De dienst van het account van dit item, voor de foto's bij de auteur en het teken van het
    /// PR-nummer.
    private func kind(of item: HistoryItem) -> ProviderKind {
        accounts.config.accounts.first { $0.id == item.entry.accountId }?.kind ?? .azureDevOps
    }

    /// De server van het account (github.com of GitHub Enterprise), voor de foto's bij de auteur.
    private func web(of item: HistoryItem) -> URL? {
        accounts.config.accounts.first { $0.id == item.entry.accountId }?.effectiveInstanceURL
    }

    private func open(_ ids: Set<HistoryItem.ID>) {
        historyModel.open(.history(Array(ids)))
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            // Zoals de PR-lijst van GitHub: alleen een icoon, zonder tekst. De vorm verschilt per
            // soort en status, dus de betekenis hangt niet aan de kleur; tooltip en VoiceOver
            // zeggen het in woorden.
            TableColumn(Text(verbatim: ""), value: \.glyphSortKey) { item in
                item.entry.glyph.image
                    .foregroundStyle(item.entry.glyphColor)
                    .frame(maxWidth: .infinity)
                    .help(Text(item.entry.glyphLabel))
                    .accessibilityLabel(Text(item.entry.glyphLabel))
            }
            .width(24)
            // De checks (CI) naast de status, ook als GitHub: een icoon in de kleur van de stand
            // en "4/8". Alleen bij PR's, en niet als de bron CI-checks uit staat; zonder checks een lege cel.
            if kind == .pullRequest, accounts.config.isEnabled(.ciChecks) {
                TableColumn(Text(verbatim: ""), value: \.checksSortKey) { item in
                    // De kolom staat er alleen als de bron aan staat.
                    ChecksBadge(checks: item.entry.checks, isEnabled: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .width(min: 48, ideal: 58, max: 76)
            }
            TableColumn("Titel", value: \.entry.title) { item in
                // Zoals Mail en het menupaneel: een blauwe stip voor ongelezen, op een vaste plek.
                HStack(spacing: 6) {
                    Circle()
                        .fill(item.isRead ? AnyShapeStyle(.clear) : AnyShapeStyle(.tint))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(verbatim: item.entry.title)
                        .fontWeight(item.isRead ? .regular : .semibold)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .help(item.entry.title)
                    // Bij een release een pill (Release of Pre-release) en de titel ervan naast
                    // de tagnaam.
                    if let release = item.entry.release {
                        Pill(text: release.label, tint: release.color)
                    }
                    if let release = item.entry.releaseTitle {
                        Text(verbatim: release)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(release)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(item.isRead ? Text(verbatim: "") : Text("Ongelezen"))
            }
            .width(min: 180, ideal: 300)
            // Bij een PR de naam met het nummer (`FerroHEALTH/FerroFED #1570`), zoals GitHub; sorteren
            // houdt een repo bij elkaar en zet zijn PR's op nummer (`RepoSortKey`).
            TableColumn("Repo", value: \.entry.repoSortKey) { item in
                // Onder het filter van een organisatie of project staat die naam al in de
                // zijbalk en de titel: de repo dan zonder.
                RepoReferenceLabel(entry: item.entry, kind: kind(of: item), showsOwner: group == nil)
            }
            .width(min: 100, ideal: 180)
            TableColumn("Auteur", value: \.authorSortKey) { item in
                if let author = item.entry.author {
                    ContributorsLabel(
                        author: author, coAuthors: item.entry.coAuthors, kind: kind(of: item),
                        web: web(of: item), avatarURL: item.entry.authorAvatarURL
                    )
                } else {
                    Text("onbekend").foregroundStyle(.secondary)
                }
            }
            .width(min: 100, ideal: 190)
            TableColumn("Wanneer", value: \.detectedAt) { item in
                RelativeDateText(date: item.detectedAt)
                    .help(item.detectedAt.formatted(date: .complete, time: .standard))
            }
            .width(min: 110, ideal: 150)
        }
        .contextMenu(forSelectionType: HistoryItem.ID.self) { ids in
            HistoryContextMenu(
                count: ids.count,
                hasUnread: rows.contains { ids.contains($0.id) && !$0.isRead },
                visibleHasUnread: rows.contains { !$0.isRead },
                setRead: { historyModel.setRead(ids, $0) },
                markAllRead: { historyModel.setRead(Set(rows.map(\.id)), true) },
                repo: repo(of: ids),
                author: rows.first { ids.contains($0.id) }?.entry.author,
                open: { open(ids) },
                showRepo: { app.showRepo(accountId: $0.accountId, repo: $0.repo) },
                filterAuthor: { name in
                    if !tokens.contains(.author(name)) { tokens.append(.author(name)) }
                }
            )
        } primaryAction: { ids in
            open(ids)
        }
        .overlay {
            if rows.isEmpty {
                if searchText.trimmingCharacters(in: .whitespaces).isEmpty && tokens.isEmpty
                    && polling.isFillingHistory {
                    // De voortgang staat in de balk onderin; hier alleen wat er gebeurt.
                    ContentUnavailableView {
                        Label {
                            Text(kind == .pullRequest ? "PR's ophalen…" : "Tags ophalen…")
                        } icon: {
                            kind.glyph.image
                        }
                    } description: {
                        fillingDescription
                    }
                } else if kind == .tag && tagFilter != .all {
                    ContentUnavailableView(
                        tagFilter == .releases ? "Geen releases" : "Geen tags zonder release",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Kies Alles om alle tags te zien.")
                    )
                } else if searchText.trimmingCharacters(in: .whitespaces).isEmpty && tokens.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text(kind == .pullRequest ? "Nog geen PR's" : "Nog geen tags")
                        } icon: {
                            kind.glyph.image
                        }
                    } description: {
                        Text(kind == .pullRequest
                             ? "Nieuwe pull requests in de repo's die je volgt komen hier te staan."
                             : "Nieuwe tags in de repo's die je volgt komen hier te staan.")
                    }
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .searchable(
            text: $searchText,
            tokens: $tokens,
            prompt: groupName.map { Text("Zoek in \($0)…", comment: "Projectnaam") } ?? Text(kind == .pullRequest ? "Zoek op titel, nummer, auteur, repo…" : "Zoek op titel, auteur, repo…")
        ) { token in
            HistoryTokenLabel(token: token)
        }
        .searchShortcut()
        .searchSuggestions {
            ForEach(suggestedAuthors, id: \.self) { name in
                Label(name, systemImage: "person")
                    .searchCompletion(HistoryToken.author(name))
            }
        }
        .navigationTitle(groupName.map { Text(verbatim: $0) } ?? Text(kind == .pullRequest ? "PR's" : "Tags en releases"))
        .navigationSubtitle(subtitle)
        .toolbar {
            if kind == .tag {
                ToolbarItem {
                    Picker("Tonen", selection: $tagFilter) {
                        ForEach(TagFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.menu)
                    .help("Alle tags, alleen releases of alleen tags zonder release")
                }
            }
            HistoryToolbar(
                selectedRepo: repo(of: selection),
                markAllRead: { historyModel.setRead(Set(rows.map(\.id)), true) },
                hasUnread: rows.contains { !$0.isRead }
            )
        }
        .onChange(of: query, initial: true) { recompute() }
        .onChange(of: historyModel.history) { recompute() }
        .focusedSceneValue(\.browserTarget, .history(rows.filter { selection.contains($0.id) }.map(\.id)))
        .focusedSceneValue(\.readTarget, ReadTarget(
            selected: Set(rows.filter { selection.contains($0.id) }.map(\.id)),
            visible: Set(rows.map(\.id)),
            selectionHasUnread: rows.contains { selection.contains($0.id) && !$0.isRead },
            visibleHasUnread: rows.contains { !$0.isRead }
        ))
        .focusedSceneValue(\.repoTarget, repo(of: selection).map {
            RepoTarget(id: overview.repoId(accountId: $0.accountId, repo: $0.repo), isOpen: false)
        })
    }

    /// Onder "PR's ophalen…": van welk account, als dat bekend is.
    private var fillingDescription: Text {
        guard let account = polling.fillingAccountName else {
            return Text(kind == .pullRequest
                        ? "Pullwatch haalt de PR's op van de repo's die je volgt."
                        : "Pullwatch haalt de tags op van de repo's die je volgt.")
        }
        return kind == .pullRequest
            ? Text("Pullwatch haalt de PR's op van \(account).", comment: "Accountnaam, bv. @octocat op GitHub")
            : Text("Pullwatch haalt de tags op van \(account).", comment: "Accountnaam, bv. @octocat op GitHub")
    }

    private var subtitle: Text {
        let unread = rows.count(where: { !$0.isRead })
        return unread == 0 ? Text("Niets ongelezen") : Text("\(unread) ongelezen")
    }
}
