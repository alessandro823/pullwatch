import PullwatchCore
import SwiftUI

/// Hoe ver een branch voor en achter ligt ("↑3 ↓1"), voor ligt in groen; leeg zolang het niet
/// vergeleken is. Leest geen model uit de environment, want hij staat in een cel van een tabel.
struct BranchDistanceLabel: View {
    let comparison: BranchComparison?

    var body: some View {
        if let comparison {
            HStack(spacing: 6) {
                Text(verbatim: "↑\(comparison.ahead)")
                    .foregroundStyle(comparison.ahead > 0 ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                Text(verbatim: "↓\(comparison.behind)")
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(BranchDistanceText(comparison: comparison).text)
        }
    }
}

/// "2 voor, 1 achter" als zin, voor het inspectievenster en VoiceOver.
struct BranchDistanceText {
    let comparison: BranchComparison

    var text: Text {
        Text("\(comparison.ahead) voor, \(comparison.behind) achter", comment: "Commits voor en achter op een andere branch")
    }
}
