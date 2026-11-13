import PullwatchCore
import SwiftUI

/// Onderdelen van het hoofdvenster, in de volgorde van de zijbalk en van ⌘1 tot ⌘7.
enum MainSection: String, CaseIterable, Identifiable {
    // `dependencies` heette vroeger Versies; de rawValue blijft "versions", zodat een bewaard
    // laatste onderdeel en meldingen (`userInfo["section"]`) blijven werken.
    case pullRequests, tags
    /// Pushes naar branches van gevolgde repo's; los van de geschiedenis, zonder teller.
    case branches
    case stats, repos
    case dependencies = "versions"
    /// Wat de gevolgde repo's zelf publiceren (npm, images, NuGet); niet wat ze gebruiken.
    case packages

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .pullRequests: "PR's"
        case .tags: "Tags en releases"
        case .branches: "Branches"
        case .stats: "Statistieken"
        case .repos: "Repo's"
        case .dependencies: "Afhankelijkheden"
        case .packages: "Packages"
        }
    }

    var glyph: Glyph {
        switch self {
        case .pullRequests: ItemKind.pullRequest.glyph
        case .tags: ItemKind.tag.glyph
        case .branches: BranchesView.glyph
        case .stats: .system("chart.bar")
        case .repos: .system("folder")
        case .dependencies: .system("shippingbox")
        case .packages: .system(PublishedPackagesView.symbol)
        }
    }
}

/// De tabbladen van de repo-pagina, in de knoppenbalk: overzicht, de controle (runtimes en
/// kwetsbaarheden), de afhankelijkheden en de beveiliging van de dienst zelf.
enum RepoTab: String, CaseIterable, Identifiable {
    case overview, check
    // Heette Packages; de rawValue blijft "packages", zodat het bewaarde tabblad blijft werken.
    // "Packages" is nu alleen wat een repo publiceert (het onderdeel Packages).
    case dependencies = "packages"
    case security

    /// Of de tellers (kwetsbaarheden, verouderd, bij te werken, geblokkeerd) bij dit tabblad horen.
    var showsCheckSummary: Bool { self == .check || self == .dependencies }

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .overview: "Overzicht"
        case .check: "Controle"
        case .dependencies: "Afhankelijkheden"
        case .security: "Beveiliging"
        }
    }

    /// Of het tabblad een tabel met een inspectievenster heeft.
    var hasTable: Bool { self != .overview }
}

/// Een verzoek aan de repo-pagina om een rij te kiezen en het inspectievenster te openen
/// (de fototour, of een sprong vanaf een andere plek).
struct RepoSelectionRequest: Equatable {
    let tab: RepoTab
    /// De id van de rij (`VulnerabilityTableRow.id`, `RepoPackageTableRow.id`, `SecurityFindingRow.id`);
    /// nil toont het tabblad met het inspectievenster dicht.
    var rowId: String? = nil
}

/// Wat het onderdeel Packages bij openen toont: alleen wat één repo publiceert, of een zoektekst.
struct PublishedPackagesRequest: Equatable {
    var repo: HistoryRepo?
    var search: String?
    /// Een package om te kiezen, met het inspectievenster open (`PublishedPackageSummary.id`).
    var selection: String?
}

/// Selectie in de zijbalk: een onderdeel, of één project onder PR's, Tags of Repo's.
enum SidebarItem: Hashable {
    case section(MainSection)
    case group(ItemKind, HistoryGroup.ID)
    case repoGroup(HistoryGroup.ID)

    /// Het onderdeel waar deze selectie bij hoort.
    var section: MainSection {
        switch self {
        case .section(let section): section
        case .group(.pullRequest, _): .pullRequests
        case .group(.tag, _): .tags
        case .repoGroup: .repos
        }
    }
}

/// Een pagina die op de `NavigationStack` van het zichtbare onderdeel komt; de terugknop van het
/// systeem (en ⌘[) haalt hem er weer af.
enum Route: Hashable {
    /// De pagina van één repo (`RepoSummary.id`).
    case repo(String)
    /// Statistieken van één repo (`RepoSummary.id`).
    case stats(repoId: String)
}

/// Filter op PR's of Tags dat vanaf een andere plek komt (een auteur uit Statistieken, een repo-pagina);
/// staat als token in het zoekveld en gaat weg zoals elke token.
enum HistoryToken: Hashable, Identifiable {
    case author(String)
    case repo(HistoryRepo)

    var id: Self { self }
}

/// Wat de zijbalk toont: de projecten per onderdeel en de tellers. Het model houdt het bij als
/// geschiedenis, config of repo-overzicht verandert, zodat de zijbalk niets hoeft te rekenen.
struct SidebarContent: Equatable {
    var pullRequestGroups: [HistoryGroup] = []
    var tagGroups: [HistoryGroup] = []
    var repoGroups: [HistoryGroup] = []
    var badges: [MainSection: Int] = [:]

    func groups(_ section: MainSection) -> [HistoryGroup] {
        switch section {
        case .pullRequests: pullRequestGroups
        case .tags: tagGroups
        case .repos: repoGroups
        case .branches, .stats, .dependencies, .packages: []
        }
    }

    /// Naam van een project uit de zijbalk, voor de titel van de lijst.
    func name(of item: SidebarItem) -> String? {
        switch item {
        case .section: nil
        case .group(let kind, let id): groups(kind == .pullRequest ? .pullRequests : .tags).first { $0.id == id }?.name
        case .repoGroup(let id): repoGroups.first { $0.id == id }?.name
        }
    }
}
