import Testing
import PullwatchCore

/// De repo-naam zonder groep, voor de kolom Repo onder het filter van een organisatie of project.
@Suite struct RepoNameTests {
    @Test(arguments: [
        ("openEHR/specifications", "specifications"),
        ("My Project/api", "api"),
        ("group/sub/project", "sub/project"),
        ("standalone", "standalone"),
    ])
    func `The owner before the first slash is left out`(repo: String, name: String) {
        #expect(HistoryGroup.repoName(repo) == name)
    }
}
