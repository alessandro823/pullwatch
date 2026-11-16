import PullwatchCore
import SwiftUI

/// De pushes naar één branch die Pullwatch zag, nieuwste eerst: wie, wat (commits, force-push,
/// nieuwe branch) en wanneer; een klik opent de vergelijking (of de branch).
struct BranchActivitySection: View {
    let pushes: [BranchPush]
    let open: (URL) -> Void

    var body: some View {
        Section("Activiteit") {
            if pushes.isEmpty {
                Text("Nog geen pushes gezien")
                    .foregroundStyle(.secondary)
            }
            ForEach(pushes) { push in
                Button {
                    open(push.webURL)
                } label: {
                    BranchActivityRow(push: push)
                }
                .buttonStyle(.plain)
                .help(Text("Open de vergelijking in de browser"))
            }
        }
    }
}

/// Eén push in de activiteit.
private struct BranchActivityRow: View {
    let push: BranchPush

    private var name: String { push.authorName ?? String(localized: "Iemand") }

    var body: some View {
        HStack(spacing: 8) {
            PersonAvatar(url: push.authorAvatarURL, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                summary.lineLimit(2)
                Text(verbatim: shas)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            RelativeDateText(date: push.pushedAt)
                .font(.callout)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.forward")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(.rect)
    }

    private var summary: Text {
        switch push.kind {
        case .push:
            if let commits = push.commits {
                Text("\(name) pushte \(commits) commits", comment: "Persoon, aantal commits")
            } else {
                Text("\(name) pushte", comment: "Persoon; aantal commits onbekend")
            }
        case .forcePush:
            Text("\(name) deed een force-push", comment: "Persoon")
        case .newBranch:
            Text("\(name) maakte de branch", comment: "Persoon")
        case .recent:
            Text("Laatste commit van \(name)", comment: "Persoon; de eerste keer dat Pullwatch de branch zag")
        }
    }

    private var shas: String {
        let new = String(push.newSha.prefix(7))
        guard let old = push.oldSha else { return new }
        return "\(old.prefix(7)) → \(new)"
    }
}
