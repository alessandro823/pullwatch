import PullwatchCore
import SwiftUI

/// Het inspectievenster van één branch: de naam met het pad vanaf de standaardbranch en de
/// knoppen, dan waar hij van gemaakt is en hoe ver hij daarvan en van de standaardbranch af
/// staat, zijn PR en de laatste push, en daaronder de pushes die Pullwatch zag.
struct BranchInspector: View {
    let info: BranchInfo
    let tree: RepoBranches
    let pushes: [BranchPush]
    /// De titel van de open PR, als die in de geschiedenis staat.
    let pullRequestTitle: String?
    let open: (URL) -> Void

    /// De ouders tot en met de standaardbranch, van boven naar beneden, en de branch zelf.
    private var path: [String] {
        var names = [info.name]
        var seen: Set<String> = [info.name]
        var current = info.parent
        while let name = current, seen.insert(name).inserted {
            names.insert(name, at: 0)
            current = tree.branches[name]?.parent
        }
        return names
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: info.name)
                        .font(.title3.bold())
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text(verbatim: ([tree.repo] + path).joined(separator: " › "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    HStack {
                        if let url = info.parentCompareURL, info.parent != nil {
                            Button("Vergelijk met ouder") { open(url) }
                                .buttonStyle(.borderedProminent)
                                .help("Open de vergelijking met de branch waar deze van gemaakt is")
                        }
                        Button("Open in browser") { open(info.webURL) }
                        Button {
                            Pasteboard.copy(info.name)
                        } label: {
                            Label("Kopieer branchnaam", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                        }
                        .help("Kopieer branchnaam")
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
                .padding(.vertical, 2)
            }
            BranchDetailsSection(info: info, defaultBranch: tree.defaultBranch, pullRequestTitle: pullRequestTitle)
            BranchActivitySection(pushes: pushes, open: open)
        }
        .formStyle(.grouped)
    }
}

/// Waar de branch van gemaakt is, hoe ver hij af staat, zijn PR en de laatste push.
private struct BranchDetailsSection: View {
    let info: BranchInfo
    let defaultBranch: String?
    let pullRequestTitle: String?

    var body: some View {
        Section("Branch") {
            if info.name == defaultBranch {
                LabeledContent("Soort", value: String(localized: "De standaardbranch"))
            } else if let parent = info.parent {
                LabeledContent("Gemaakt van") {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(verbatim: parent)
                        BranchParentSourceText(info: info)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let againstParent = info.againstParent {
                    LabeledContent {
                        BranchDistanceText(comparison: againstParent).text
                    } label: {
                        Text("Tegen \(parent)", comment: "Voor en achter op deze branch")
                    }
                }
            }
            if let defaultBranch, info.name != defaultBranch, info.parent != defaultBranch,
               let againstDefault = info.againstDefault {
                LabeledContent {
                    BranchDistanceText(comparison: againstDefault).text
                } label: {
                    Text("Tegen \(defaultBranch)", comment: "Voor en achter op deze branch")
                }
            }
            if let number = info.pullRequest {
                LabeledContent("Pull request") {
                    Text(verbatim: pullRequestTitle.map { "#\(number) \($0)" } ?? "#\(number)")
                        .lineLimit(2)
                }
            }
            if let removedAt = info.removedAt {
                LabeledContent(info.merged ? "Gemerged" : "Weggehaald") {
                    RelativeDateText(date: removedAt)
                }
            }
            if let date = info.lastPushAt {
                LabeledContent("Laatste push") {
                    HStack(spacing: 5) {
                        if let name = info.authorName {
                            PersonAvatar(url: info.authorAvatarURL)
                            Text(verbatim: name)
                        }
                        RelativeDateText(date: date).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// Waar de ouder vandaan komt: de PR, de geschiedenis of niets beters dan de standaardbranch.
private struct BranchParentSourceText: View {
    let info: BranchInfo

    var body: some View {
        switch info.parentSource {
        case .pullRequest:
            if let number = info.pullRequest {
                Text("doelbranch van PR #\(number)", comment: "Waar de ouder van een branch vandaan komt")
            } else {
                Text("doelbranch van de PR")
            }
        case .history:
            Text("uit de geschiedenis", comment: "Waar de ouder van een branch vandaan komt")
        case .defaultBranch:
            Text("de standaardbranch", comment: "Waar de ouder van een branch vandaan komt")
        case nil:
            Text("nog niet bepaald", comment: "Waar de ouder van een branch vandaan komt")
        }
    }
}
