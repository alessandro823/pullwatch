import Testing
@testable import PullwatchCore

/// De ouder uit de geschiedenis: de kandidaat waar de branch de minste commits voor ligt.
@Suite struct BranchLineageTests {
    func c(_ ahead: Int, _ behind: Int) -> BranchComparison { BranchComparison(ahead: ahead, behind: behind) }

    @Test func `The candidate with the fewest commits ahead wins`() {
        let parent = BranchLineage.parent(among: ["main": c(4, 0), "feature/a": c(1, 0)], defaultBranch: "main")
        #expect(parent == "feature/a")
    }

    @Test func `The default branch wins a tie`() {
        let parent = BranchLineage.parent(among: ["main": c(0, 0), "feature/a": c(0, 0)], defaultBranch: "main")
        #expect(parent == "main")
    }

    @Test func `A candidate that already has the branch and more is a child, not a parent`() {
        // feature/a-child is van deze branch afgetakt en heeft eigen commits.
        let parent = BranchLineage.parent(among: ["main": c(3, 0), "feature/a-child": c(0, 2)], defaultBranch: "main")
        #expect(parent == "main")
    }

    @Test func `The default branch stays a candidate after it moved on`() {
        let parent = BranchLineage.parent(among: ["main": c(0, 7)], defaultBranch: "main")
        #expect(parent == "main")
    }

    @Test func `Fewer commits behind breaks a tie between other branches`() {
        let parent = BranchLineage.parent(among: ["main": c(5, 0), "a": c(1, 3), "b": c(1, 1)], defaultBranch: "main")
        #expect(parent == "b")
    }

    @Test func `No usable candidate gives no parent`() {
        #expect(BranchLineage.parent(among: ["a": c(0, 1)], defaultBranch: nil) == nil)
        #expect(BranchLineage.parent(among: [:], defaultBranch: "main") == nil)
    }
}
