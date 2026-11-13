import AppKit
import PullwatchCore
import SwiftUI

/// Het onderdeel Packages: wat de gevolgde repo's zelf publiceren in het register van hun dienst
/// (GitHub Packages, de registers van GitLab, Azure Artifacts), één rij per package, per eigenaar
/// gegroepeerd zoals Repo's. Niet wat ze gebruiken: dat is Afhankelijkheden. Het inspectievenster
/// toont de recente versies en wie op welke versie zit; ⌘O opent het package bij het register.
struct PublishedPackagesView: View {
    /// Een doos die vertrekt: wat je repo's publiceren (het symbool van het onderdeel).
    static let symbol = "shippingbox.and.arrow.backward"

    @Environment(AccountsModel.self) private var accounts
    @Environment(VersionsModel.self) private var versions
    @Environment(OverviewModel.self) private var overview
    @Environment(AppRouter.self) private var router

    @State private var searchText = ""
    @State private var typeFilter: PublishedPackageType?
    /// Alleen wat deze repo publiceert (vanaf zijn Overzicht).
    @State private var repoFilter: HistoryRepo?
    @State private var selection: PublishedPackageSummary.ID?
    @State private var sortOrder = [KeyPathComparator(\PublishedPackageSummary.nameSortKey)]
    @State private var groups: [PublishedPackageGroup] = []
    @State private var showsInspector = false
    /// Of de kolom Gepubliceerd past; alleen dat, zodat de tabel niet bij elke pixel opnieuw tekent.
    @State private var showsDate = true

    private struct Query: Equatable {
        let text: String
        let type: PublishedPackageType?
        let repo: HistoryRepo?
        let sortOrder: [KeyPathComparator<PublishedPackageSummary>]
        let packages: [PublishedPackageSummary]
    }

    private func recompute() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let found = versions.publishedPackages.filter { summary in
            let package = summary.package
            if let typeFilter, package.type != typeFilter { return false }
            if let repoFilter, package.accountId != repoFilter.accountId
                || package.repository?.caseInsensitiveCompare(repoFilter.repo) != .orderedSame { return false }
            return query.isEmpty
                || package.name.localizedCaseInsensitiveContains(query)
                || summary.publisher.localizedCaseInsensitiveContains(query)
                || summary.users.contains { $0.repo.localizedCaseInsensitiveContains(query) }
        }
        groups = PublishedPackageGroup.groups(found.sorted(using: sortOrder))
        if let selection, !found.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    private var selected: PublishedPackageSummary? {
        selection.flatMap { id in versions.publishedPackages.first { $0.id == id } }
    }

    /// De accounts waarvan het register niet te lezen is, met de reden.
    private var needsPermission: [PublishedPackagesPermission] {
        (versions.versionReport?.publishedPackages ?? []).compactMap { result in
            guard case .needsPermission(let reason) = result.result else { return nil }
            let name = accounts.config.accounts.first { $0.id == result.accountId }?.displayName
            return PublishedPackagesPermission(accountId: result.accountId, accountName: name, reason: reason)
        }
    }

    private var isSourceOff: Bool { accounts.config.disabledSources.contains(.packageRegistries) }

    var body: some View {
        let permissions = needsPermission
        VStack(spacing: 0) {
            if !isSourceOff, !versions.publishedPackages.isEmpty {
                PublishedPackagesNotices(permissions: permissions, repoFilter: repoFilter) { repoFilter = nil }
            }
            PublishedPackagesTable(
                groups: groups, selection: $selection, sortOrder: $sortOrder, showsDate: showsDate,
                openPage: { id in
                    if let url = versions.publishedPackages.first(where: { $0.id == id })?.package.webURL { NSWorkspace.shared.open(url) }
                }
            )
            .id(showsDate)
            .onGeometryChange(for: Bool.self) { $0.size.width >= 620 } action: { showsDate = $0 }
            .overlay {
                PublishedPackagesEmptyState(
                    hasReport: versions.versionReport != nil, isChecking: versions.versionCheck != nil,
                    isSourceOff: isSourceOff, hasPackages: !versions.publishedPackages.isEmpty,
                    isFiltered: groups.isEmpty, searchText: searchText, permissions: permissions,
                    openSources: { router.showSettings(.sources) },
                    clearFilters: {
                        searchText = ""
                        typeFilter = nil
                        repoFilter = nil
                    }
                )
            }
        }
        .inspector(isPresented: $showsInspector) {
            Group {
                if let selected {
                    PublishedPackageInspector(
                        summary: selected,
                        accountName: accounts.config.accounts.count > 1
                            ? accounts.config.accounts.first { $0.id == selected.package.accountId }?.displayName : nil,
                        openRepo: { repoId in
                            let user = selected.users.first { $0.repoId == repoId }
                            router.showRepo(id: user.map { overview.repoId(accountId: $0.accountId, repo: $0.repo) } ?? repoId)
                        },
                        showTags: selected.package.repository.map { repo in
                            { router.showHistory(.tag, repo: HistoryRepo(accountId: selected.package.accountId, repo: repo)) }
                        }
                    )
                } else {
                    ContentUnavailableView {
                        Label("Niets gekozen", systemImage: "sidebar.trailing")
                    } description: {
                        Text("Kies een package om de versies te zien en wie het gebruikt.")
                    }
                }
            }
            .inspectorColumnWidth(min: 240, ideal: 290, max: 420)
        }
        .searchable(text: $searchText, prompt: Text("Zoek op package of repo…"))
        .searchShortcut()
        .navigationTitle(Text("Packages"))
        .navigationSubtitle(CheckedSubtitle.text(versions.versionReport?.checkedAt))
        .toolbar {
            ToolbarItem {
                // Het filter op soort: alle soorten, of één die voorkomt.
                ValueFilterMenu(
                    title: "Soort", allTitle: "Alle soorten", systemImage: "line.3.horizontal.decrease.circle",
                    values: Set(versions.publishedPackages.map(\.package.type)).sorted { $0.rawValue < $1.rawValue },
                    selection: $typeFilter
                ) { type in
                    Label { type.text } icon: { Image(systemName: type.symbol) }
                }
                .help("Toon alleen packages van één soort")
            }
            ToolbarItem {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Inspectievenster", systemImage: "sidebar.trailing")
                }
                .help("Toon of verberg het inspectievenster")
            }
            CheckAllToolbarItem()
        }
        .onChange(of: selection) { _, id in
            if id != nil { showsInspector = true }
        }
        .onChange(of: router.publishedPackagesRequest, initial: true) { _, request in
            guard let request else { return }
            repoFilter = request.repo
            searchText = request.search ?? ""
            if let id = request.selection {
                selection = id
                showsInspector = true
            }
            router.publishedPackagesRequest = nil
        }
        .onChange(
            of: Query(text: searchText, type: typeFilter, repo: repoFilter, sortOrder: sortOrder, packages: versions.publishedPackages),
            initial: true
        ) {
            recompute()
        }
        .focusedSceneValue(\.browserTarget, selected?.package.webURL.map(BrowserTarget.page))
    }
}

/// De packages van één eigenaar (gebruiker, organisatie, groep of Azure-project), een sectie van de tabel.
struct PublishedPackageGroup: Identifiable, Equatable {
    let id: String
    let owner: String
    let packages: [PublishedPackageSummary]

    /// Per eigenaar in de volgorde van de eerste package, zodat de sortering van de tabel blijft.
    static func groups(_ sorted: [PublishedPackageSummary]) -> [PublishedPackageGroup] {
        var order: [String] = []
        var byOwner: [String: [PublishedPackageSummary]] = [:]
        for summary in sorted {
            let key = "\(summary.package.accountId.uuidString)/\(summary.package.owner.lowercased())"
            if byOwner[key] == nil { order.append(key) }
            byOwner[key, default: []].append(summary)
        }
        return order
            .map { PublishedPackageGroup(id: $0, owner: byOwner[$0]?.first?.package.owner ?? "", packages: byOwner[$0] ?? []) }
            .sorted { $0.owner.lowercased() < $1.owner.lowercased() }
    }
}

/// Een account waarvan Pullwatch het register niet mag lezen.
struct PublishedPackagesPermission: Identifiable, Equatable {
    var id: UUID { accountId }
    let accountId: UUID
    let accountName: String?
    let reason: String
}

/// De tabel, per eigenaar een sectie; dubbelklik opent het package bij het register.
private struct PublishedPackagesTable: View {
    let groups: [PublishedPackageGroup]
    @Binding var selection: PublishedPackageSummary.ID?
    @Binding var sortOrder: [KeyPathComparator<PublishedPackageSummary>]
    let showsDate: Bool
    let openPage: (PublishedPackageSummary.ID) -> Void

    var body: some View {
        Table(of: PublishedPackageSummary.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Package", value: \.nameSortKey) { summary in
                PublishedPackageNameCell(name: summary.package.name, type: summary.package.type, visibility: summary.package.visibility)
            }
            .width(min: 140, ideal: 200)
            TableColumn("Repository", value: \.publisherSortKey) { summary in
                PublishedPackagePublisherCell(repository: summary.package.repository, owner: summary.package.owner)
            }
            .width(min: 120, ideal: 200)
            TableColumn("Nieuwste versie", value: \.latestSortKey) { summary in
                PublishedPackageVersionCell(
                    version: summary.package.releasedVersion ?? summary.package.latestVersion, publishedAt: summary.package.releasedAt,
                    showsDateInHelp: !showsDate, kind: summary.package.latestKind, latestTag: summary.package.latestTag,
                    newerPrerelease: summary.package.newestPrerelease
                )
            }
            .width(min: 70, ideal: 100)
            if showsDate {
                TableColumn("Gepubliceerd", value: \.publishedSortKey) { summary in
                    PublishedPackageDateCell(publishedAt: summary.package.releasedAt)
                }
                .width(min: 80, ideal: 110)
            }
            TableColumn("Gebruikt door", value: \.usedBySortKey) { summary in
                PublishedPackageUsersCell(count: summary.users.count, isMatchable: summary.isMatchable)
            }
            .width(min: 60, ideal: 90)
        } rows: {
            ForEach(groups) { group in
                Section {
                    ForEach(group.packages) { summary in
                        TableRow(summary)
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text(verbatim: group.owner)
                        Text(verbatim: "(\(group.packages.count))")
                    }
                }
            }
        }
        .contextMenu(forSelectionType: PublishedPackageSummary.ID.self) { ids in
            if let id = ids.first {
                Button("Open in het register") { openPage(id) }
            }
        } primaryAction: { ids in
            if let id = ids.first { openPage(id) }
        }
    }
}

/// Boven de tabel: een account zonder recht op zijn register, en het filter op één repo.
private struct PublishedPackagesNotices: View {
    let permissions: [PublishedPackagesPermission]
    let repoFilter: HistoryRepo?
    let clearRepoFilter: () -> Void

    var body: some View {
        if !permissions.isEmpty || repoFilter != nil {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(permissions) { permission in
                    HStack(alignment: .firstTextBaseline) {
                        Label {
                            if let name = permission.accountName {
                                Text("Geen toegang tot het packageregister van \(name)", comment: "Accountnaam, zoals \"github op GitHub\"")
                            } else {
                                Text("Geen toegang tot het packageregister van een account")
                            }
                        } icon: {
                            Image(systemName: "lock")
                        }
                        .foregroundStyle(.orange)
                        .help(Text(verbatim: permission.reason))
                        Spacer()
                        Link("Over de rechten", destination: HelpLinks.permissions)
                    }
                }
                if let repoFilter {
                    HStack {
                        Label {
                            Text("Alleen wat \(repoFilter.repo) publiceert", comment: "Volledige naam van een repository")
                        } icon: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                        Spacer()
                        Button("Toon alles", action: clearRepoFilter)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
        }
    }
}

/// Wat er staat als de tabel leeg is: nog niet gecheckt, de bron uit, geen recht, niets gepubliceerd,
/// of niets met dit filter.
private struct PublishedPackagesEmptyState: View {
    let hasReport: Bool
    let isChecking: Bool
    let isSourceOff: Bool
    let hasPackages: Bool
    let isFiltered: Bool
    let searchText: String
    let permissions: [PublishedPackagesPermission]
    let openSources: () -> Void
    let clearFilters: () -> Void

    var body: some View {
        if isSourceOff {
            ContentUnavailableView {
                Label("Niet gecontroleerd", systemImage: "slash.circle")
            } description: {
                Text(verbatim: SourceOff.notChecked(.packageRegistries))
            } actions: {
                Button("Open Bronnen", action: openSources)
            }
        } else if !hasReport && isChecking {
            ContentUnavailableView(
                "Packages ophalen…",
                systemImage: PublishedPackagesView.symbol,
                description: Text("Pullwatch leest wat je repo's publiceren in het register van hun dienst.")
            )
        } else if !hasReport {
            ContentUnavailableView(
                "Nog niet gecheckt",
                systemImage: PublishedPackagesView.symbol,
                description: Text("Zie wat je repo's publiceren (npm, container-images, NuGet en meer) en welke repo's het gebruiken.")
            )
        } else if !hasPackages && !permissions.isEmpty {
            ContentUnavailableView {
                Label("Geen toegang tot het register", systemImage: "lock")
            } description: {
                VStack(spacing: 8) {
                    ForEach(permissions) { permission in
                        VStack(spacing: 2) {
                            if let name = permission.accountName {
                                Text(verbatim: name).fontWeight(.semibold)
                            }
                            Text(verbatim: permission.reason)
                        }
                    }
                }
            } actions: {
                Link("Over de rechten", destination: HelpLinks.permissions)
            }
        } else if !hasPackages {
            ContentUnavailableView(
                "Geen packages",
                systemImage: PublishedPackagesView.symbol,
                description: Text("De repo's die je volgt publiceren geen packages in het register van hun dienst.")
            )
        } else if isFiltered {
            FilteredEmptyView(searchText: searchText, clear: clearFilters)
        }
    }
}
