import PullwatchCore
import SwiftUI

/// De status van een PR zoals GitHub hem toont, met een open draft en een open PR in een merge
/// queue of merge train (Queued) apart van een gewone open PR; met alleen auto-merge of
/// auto-complete aan is hij gewoon open. Bepaalt op één plek het icoon, de
/// kleur en de tekst.
nonisolated enum PRStatus: CaseIterable, Hashable, Sendable {
    case open, draft, queued, merged, closed

    init(_ pr: PullRequest) {
        switch pr.state {
        case .open: self = pr.isDraft ? .draft : (pr.isQueued ? .queued : .open)
        case .merged: self = .merged
        case .closed: self = .closed
        }
    }

    /// De Octicons van GitHub (MIT, zie NOTICE), op 16 px getekend: git-pull-request,
    /// git-pull-request-draft, git-merge-queue, git-merge en git-pull-request-closed.
    var glyph: Glyph {
        switch self {
        case .open: .asset("pr.open")
        case .draft: .asset("pr.draft")
        case .queued: .asset("pr.queued")
        case .merged: .asset("pr.merged")
        case .closed: .asset("pr.closed")
        }
    }

    /// Zoals GitHub: een draft is grijs, queued amber, de rest de kleur van zijn `PRState`.
    /// Queued is het amber van de StateLabel `pullQueued` van Primer React (38.44.0). Licht
    /// #9A6700 (`bgColor-attention-emphasis`, @primer/primitives 11.10.0); donker #D29922
    /// (`fgColor-attention`), omdat de donkere achtergrondkleur #9E6A03 als symbool op een
    /// donkere achtergrond bijna wegvalt. Dezelfde amber als lopende checks (kleurenset PRQueued).
    var color: Color {
        switch self {
        case .open: PRState.open.color
        case .draft: .gray
        case .queued: Color("PRQueued")
        case .merged: PRState.merged.color
        case .closed: PRState.closed.color
        }
    }

    /// Soort en status in woorden, voor de tooltip en VoiceOver waar alleen het icoon staat.
    var spokenName: LocalizedStringResource {
        switch self {
        case .open: "Pull request, open"
        case .draft: "Pull request, draft"
        case .queued: "Pull request, in de wachtrij"
        case .merged: "Pull request, gemerged"
        case .closed: "Pull request, gesloten"
        }
    }

    /// Status, nummer en titel als één zin, voor VoiceOver op de repo-pagina waar alleen het icoon
    /// staat: "Gemergde pull request 1570: Fix the build". Het nummer als cijfers, zonder teken.
    func spokenSentence(number: Int, title: String) -> LocalizedStringResource {
        let number = String(number)
        return switch self {
        case .open: "Open pull request \(number): \(title)"
        case .draft: "Concept-pull request \(number): \(title)"
        case .queued: "Pull request \(number) in de wachtrij: \(title)"
        case .merged: "Gemergde pull request \(number): \(title)"
        case .closed: "Gesloten pull request \(number): \(title)"
        }
    }
}
