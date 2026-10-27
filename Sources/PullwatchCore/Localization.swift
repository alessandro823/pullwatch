import Foundation

extension Bundle {
    /// De teksten van PullwatchCore in de taal die de app gekozen heeft. Zonder dit kiest
    /// de package-bundle zelf, en valt bij een niet-ondersteunde taal terug op Nederlands
    /// terwijl de app Engels toont.
    static let localizedCore: Bundle = core(for: Bundle.main.preferredLocalizations.first)

    static func core(for language: String?) -> Bundle {
        language.flatMap { Bundle.module.path(forResource: $0, ofType: "lproj") }.flatMap(Bundle.init(path:)) ?? .module
    }
}
