import AppKit
import PullwatchCore
import PullwatchGitHub
import SwiftUI
import Testing

@testable import Pullwatch

/// Views die in een cel van een `Table` of een rij van een `List` staan, lezen zelf geen model uit
/// de environment: AppKit tekent zo'n cel soms buiten de environment van het venster, en dan stopt
/// SwiftUI de app ("No Observable object of type AccountsModel found"). Zo crashte Pullwatch bij
/// scrollen in de PR-lijst door `ChecksBadge`. Deze tests tekenen die views zonder één model in de
/// environment; leest er weer een een model, dan stopt de testrun hier en niet bij de gebruiker.
@MainActor @Suite struct CellEnvironmentTests {
    private static let pullRequest = PullRequest(
        accountId: UUID(), repo: "octo/app", number: 7, title: "Fix the crash while scrolling",
        authorId: "mona", authorName: "mona", isDraft: false, createdAt: Date(timeIntervalSince1970: 1_790_000_000),
        webURL: URL(string: "https://github.com/octo/app/pull/7")!,
        checks: .counts(CheckCounts(passed: 3, failed: 1, pending: 1))
    )

    private static let item = HistoryItem(entry: .pullRequest(pullRequest), detectedAt: Date(timeIntervalSince1970: 1_790_000_100), isRead: false)

    /// Tekent de view zonder environment en geeft terug of er iets getekend werd.
    private func draws(_ view: some View) -> Bool {
        let renderer = ImageRenderer(content: view.frame(width: 320, height: 24))
        return renderer.nsImage != nil
    }

    @Test(arguments: [true, false])
    func `ChecksBadge draws without a model in the environment`(isEnabled: Bool) {
        #expect(draws(ChecksBadge(checks: Self.pullRequest.checks, isEnabled: isEnabled)))
    }

    @Test(arguments: [true, false])
    func `PullRequestRow draws without a model in the environment`(showsChecks: Bool) {
        #expect(draws(PullRequestRow(item: Self.item, kind: .gitHub, showsChecks: showsChecks)))
    }

    @Test(arguments: ProviderKind.allCases)
    func `RepoReferenceLabel draws without a model in the environment`(kind: ProviderKind) {
        #expect(draws(RepoReferenceLabel(entry: Self.item.entry, kind: kind)))
    }

    @Test func `RepoReferenceLabel without the owner draws without a model in the environment`() {
        #expect(draws(RepoReferenceLabel(entry: Self.item.entry, kind: .gitHub, showsOwner: false)))
    }

    /// Het In-house-teken staat in de cellen van Afhankelijkheden en van het tabblad Packages, met
    /// en zonder link (een Azure-project zonder repository en zonder pagina).
    @Test(arguments: [
        (URL(string: "https://github.com/octo/ui"), InHousePackage.Status.checked),
        (nil, .sourceOff),
        (nil, .needsPermission(reason: "read:packages")),
        (URL(string: "https://github.com/octo/ui"), .readFailed),
        (URL(string: "https://github.com/octo/ui"), .unconfirmed),
    ])
    func `InHouseBadge draws without a model in the environment`(link: URL?, status: InHousePackage.Status) {
        let inHouse = InHousePackage(
            accountId: UUID(), name: "ui", type: .npm, owner: "octo", repository: link == nil ? nil : "octo/ui",
            repositoryURL: link, status: status
        )
        #expect(draws(InHouseBadge(inHouse: inHouse)))
        #expect(draws(HStack { Text(verbatim: "@octo/ui"); InHouseBadge(inHouse: inHouse) }))
    }

    private func language(_ code: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: code, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    /// De tooltip van In-house volgt de stand (#231): alleen `.checked` zegt dat de nieuwste versie
    /// uit je eigen register komt, de andere standen zeggen wie het publiceert en waarom het niet
    /// gecontroleerd is.
    @Test(arguments: [
        (InHousePackage.Status.checked,
         "Gepubliceerd door octo/ui: de nieuwste versie komt uit je eigen register.",
         "Published by octo/ui: the latest version comes from your own registry."),
        (.sourceOff,
         "Gepubliceerd door octo/ui, niet gecontroleerd: bron Packageregisters van je accounts staat uit.",
         "Published by octo/ui, not checked: source Package registries of your accounts is off."),
        (.needsPermission(reason: "read:packages"),
         "Gepubliceerd door octo/ui, niet gecontroleerd: geen toegang tot het packageregister van dit account.",
         "Published by octo/ui, not checked: no access to this account's package registry."),
        (.readFailed,
         "Gepubliceerd door octo/ui, niet gecontroleerd: het packageregister van dit account gaf geen nieuwste versie.",
         "Published by octo/ui, not checked: this account's package registry gave no latest version."),
        (.unconfirmed,
         "Gepubliceerd door octo/ui, niet gecontroleerd: het lockbestand haalt dit package uit je eigen register, maar dat register noemde het niet.",
         "Published by octo/ui, not checked: the lockfile gets this package from your own registry, but that registry did not list it."),
    ])
    func `The InHouseBadge tooltip follows the status`(status: InHousePackage.Status, dutch: String, english: String) throws {
        let inHouse = InHousePackage(accountId: UUID(), name: "ui", type: .npm, owner: "octo", repository: "octo/ui", status: status)

        #expect(InHouseBadge.help(inHouse, bundle: try language("nl")) == dutch)
        #expect(InHouseBadge.help(inHouse, bundle: try language("en")) == english)
        #expect(InHouseBadge.help(inHouse, bundle: try language("en")).contains("your own registry.") == (status == .checked))
    }

    /// De schakelaar Packages lezen met de GitHub CLI in de account-editor (#206), in elke stand
    /// van `gh`, ook met een ander `gh`-account dan wie er met de app inlogde.
    @Test(arguments: [
        (GhCLIStatus?.none, String?.some("mona")), (.notInstalled, "mona"), (.notLoggedIn, "mona"),
        (.loggedIn("mona"), "mona"), (.loggedIn("octo"), "mona"), (.loggedIn("octo"), nil),
    ])
    func `PackagesCLIRow draws without a model in the environment`(status: GhCLIStatus?, login: String?) {
        #expect(draws(Form { PackagesCLIRow(isOn: .constant(true), status: status, login: login, host: "github.com") }))
        #expect(draws(Form { PackagesCLIRow(isOn: .constant(false), status: status, login: login, host: "github.example.com") }))
    }

    @Test func `RelativeDateText draws without a model in the environment`() {
        #expect(draws(RelativeDateText(date: Self.item.detectedAt)))
        #expect(draws(Text("Gepubliceerd \(.currentDate, format: RelativeDateText.style(for: Self.item.detectedAt))", comment: "Relatieve datum")))
    }

    /// De tekst van een relatieve datum hangt af van het moment waarop hij getekend wordt (#238):
    /// 59 seconden na de datum zegt hij iets anders dan 61 seconden erna, en een dag later zegt hij
    /// "gisteren", zoals `.relative(presentation: .named)`.
    @Test(arguments: [
        ("nl", "59 seconden geleden", "1 minuut geleden", "gisteren"),
        ("en", "59 seconds ago", "1 minute ago", "yesterday"),
        ("de", "vor 59 Sekunden", "vor 1 Minute", "gestern"),
        ("fr", "il y a 59 secondes", "il y a 1 minute", "hier"),
    ])
    func `RelativeDateText follows the time it is drawn at`(code: String, early: String, later: String, dayLater: String) throws {
        let date = Self.item.detectedAt
        let locale = Locale(identifier: code)
        let nextDay = try #require(Calendar.current.date(byAdding: .day, value: 1, to: date))

        #expect(RelativeDateText.text(for: date, at: date.addingTimeInterval(59), locale: locale) == early)
        #expect(RelativeDateText.text(for: date, at: date.addingTimeInterval(61), locale: locale) == later)
        #expect(RelativeDateText.text(for: date, at: nextDay, locale: locale) == dayLater)
    }

    /// Het teken van elke soort package in de tabel van Packages: een logo uit Simple Icons of het
    /// SF Symbol, ook voor een soort die Pullwatch niet kent.
    @Test(arguments: PublishedPackageType.known + [PublishedPackageType(rawValue: "something-new")])
    func `PublishedPackageTypeIcon draws without a model in the environment`(type: PublishedPackageType) {
        #expect(draws(PublishedPackageTypeIcon(type: type)))
        #expect(draws(PublishedPackageNameCell(name: "ui", type: type, visibility: .private)))
    }

    @Test func `AcknowledgementRow draws without a model in the environment`() {
        let component = Acknowledgement(
            id: "sparkle", name: "Sparkle", version: "2.10.1", license: "MIT AND BSD-2-Clause AND Zlib",
            homepage: URL(string: "https://sparkle-project.org")!, file: "sparkle-LICENSE.txt", notice: nil, package: "sparkle"
        )
        #expect(draws(AcknowledgementRow(component: component)))
    }
}
