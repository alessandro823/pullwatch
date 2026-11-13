/// Welke branch de ouder van een branch is, uit de geschiedenis. Git en de diensten slaan dat
/// niet op; tools als Graphite en git-town houden het zelf bij, lokaal. Pullwatch kiest daarom
/// zoals git zelf voorstelt (`get_branch_base_for_tip`): de kandidaat waar de branch de minste
/// commits voor ligt. Een PR met een doelbranch gaat voor; dat beslist `PollEngine`.
enum BranchLineage {
    /// De ouder uit `comparisons`: per kandidaat de vergelijking van die kandidaat met de branch
    /// (`ahead`: commits van de branch die de kandidaat niet heeft; `behind`: andersom).
    ///
    /// Een kandidaat die alles van de branch heeft en verder is (`ahead` 0, `behind` meer dan 0)
    /// is eerder een kind dan een ouder, en valt af; behalve de standaardbranch, die na het
    /// aftakken gewoon doorloopt. Bij gelijke `ahead` wint de standaardbranch, dan de kleinste
    /// `behind`, dan de naam (zodat de uitkomst vast ligt). nil zonder bruikbare kandidaat.
    static func parent(among comparisons: [String: BranchComparison], defaultBranch: String?) -> String? {
        let usable = comparisons.filter { name, comparison in
            name == defaultBranch || !(comparison.ahead == 0 && comparison.behind > 0)
        }
        return usable.min { a, b in
            if a.value.ahead != b.value.ahead { return a.value.ahead < b.value.ahead }
            let (aDefault, bDefault) = (a.key == defaultBranch, b.key == defaultBranch)
            if aDefault != bDefault { return aDefault }
            if a.value.behind != b.value.behind { return a.value.behind < b.value.behind }
            return a.key < b.key
        }?.key
    }
}
