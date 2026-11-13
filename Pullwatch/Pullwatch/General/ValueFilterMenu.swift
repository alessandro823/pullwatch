import SwiftUI

/// Een filter in de knoppenbalk: alles, of één waarde uit de lijst. Het symbool krijgt zijn
/// gevulde vorm (`.fill`) zolang er gefilterd wordt. Branches (repo, persoon) en Packages (soort)
/// gebruiken hem.
struct ValueFilterMenu<Value: Hashable, ItemLabel: View>: View {
    let title: LocalizedStringResource
    let allTitle: LocalizedStringResource
    let systemImage: String
    let values: [Value]
    @Binding var selection: Value?
    @ViewBuilder let itemLabel: (Value) -> ItemLabel

    var body: some View {
        Menu {
            Picker(selection: $selection) {
                Text(allTitle).tag(Value?.none)
                ForEach(values, id: \.self) { value in
                    itemLabel(value).tag(Optional(value))
                }
            } label: {
                Text(title)
            }
            .pickerStyle(.inline)
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: selection == nil ? systemImage : "\(systemImage).fill")
            }
        }
    }
}

extension ValueFilterMenu where Value == String, ItemLabel == Text {
    /// Voor namen zoals ze zijn (repo's, personen): niet vertaald.
    init(
        title: LocalizedStringResource, allTitle: LocalizedStringResource, systemImage: String, values: [String],
        selection: Binding<String?>
    ) {
        self.init(title: title, allTitle: allTitle, systemImage: systemImage, values: values, selection: selection) {
            Text(verbatim: $0)
        }
    }
}
