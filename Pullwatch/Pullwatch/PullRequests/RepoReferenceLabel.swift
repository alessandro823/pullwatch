import PullwatchCore
import SwiftUI

/// De kolom Repo van de lijst: bij een PR de repo voluit, met de gebruiker of organisatie, en het
/// nummer erachter (`FerroHEALTH/FerroFED #1570`), bij een tag de repo voluit. Het nummer is ingetogen zoals de telling van
/// de checks (`ChecksBadge`): secundair en met cijfers van gelijke breedte. De tooltip geeft de
/// verwijzing voluit (`FerroHEALTH/FerroFED#1570`); VoiceOver leest "pull request 1570" in plaats
/// van het teken. In een lijst die al op één gebruiker, organisatie of project filtert staat de
/// repo zonder die naam ervoor (`FerroFED #1570`); tooltip en VoiceOver houden hem voluit. Leest
/// zelf geen model uit de environment (zie `ChecksBadge`).
struct RepoReferenceLabel: View {
    let entry: HistoryEntry
    /// De dienst van het account, voor het teken (`#` of `!`).
    let kind: ProviderKind
    /// Met de gebruiker, organisatie of het project voor de repo-naam; uit als de lijst daar al
    /// op filtert.
    var showsOwner = true

    private func shown(_ repo: String) -> String {
        showsOwner ? repo : HistoryGroup.repoName(repo)
    }

    var body: some View {
        switch entry {
        case .pullRequest(let pr):
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: shown(pr.repo))
                    .lineLimit(1)
                Text(verbatim: pr.numberText(kind))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
            .help(pr.reference(kind))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PullRequestNumberText.spoken(repo: pr.repo, number: pr.number))
        case .tag(let tag):
            Text(verbatim: shown(tag.repo))
                .lineLimit(1)
                .help(tag.repo)
        }
    }
}
