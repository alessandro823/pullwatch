import Foundation
import Testing
@testable import PullwatchCore

@Suite struct NotificationPlannerTests {
    @Test func upToThreeNewPullRequestsGetIndividualNotifications() {
        let prs = (1...3).map { PullRequest.fixture(number: $0) }
        #expect(NotificationPlanner.plan(pullRequests: prs, tags: []) == prs.map { .pullRequest($0) })
    }

    @Test func moreThanThreeBecomesOneSummaryWithFirstThreeLines() {
        let prs = (1...5).map { PullRequest.fixture(repo: "p/r", number: $0, title: "T\($0)") }
        #expect(NotificationPlanner.plan(pullRequests: prs, tags: [])
            == [.summary(kind: .pullRequest, count: 5, lines: ["p/r: T1", "p/r: T2", "p/r: T3"])])
    }

    @Test func emptyInputPlansNothing() {
        #expect(NotificationPlanner.plan(pullRequests: [], tags: []).isEmpty)
    }

    @Test func mixedSmallBatchGivesSingles() {
        let prs = (1...2).map { PullRequest.fixture(number: $0) }
        let tags = (1...2).map { Tag.fixture(name: "v\($0)") }
        #expect(NotificationPlanner.plan(pullRequests: prs, tags: tags)
            == [.pullRequest(prs[0]), .pullRequest(prs[1]), .tag(tags[0]), .tag(tags[1])])
    }

    @Test func tagBurstSummarizesSeparately() {
        let pr = PullRequest.fixture(number: 1)
        let tags = (1...4).map { Tag.fixture(repo: "p/r", name: "v\($0)") }
        #expect(NotificationPlanner.plan(pullRequests: [pr], tags: tags)
            == [.pullRequest(pr), .summary(kind: .tag, count: 4, lines: ["p/r: v1", "p/r: v2", "p/r: v3"])])
    }

    @Test func completedComeLastAndSummarizeSeparately() {
        let pr = PullRequest.fixture(number: 1)
        let one = PullRequest.fixture(number: 2, state: .merged)
        #expect(NotificationPlanner.plan(pullRequests: [pr], tags: [], completed: [one]) == [.pullRequest(pr), .completed(one)])

        let many = (1...4).map { PullRequest.fixture(repo: "p/r", number: $0, title: "T\($0)", state: .merged) }
        #expect(NotificationPlanner.plan(pullRequests: [], tags: [], completed: many)
            == [.summary(kind: .completed, count: 4, lines: ["p/r: T1", "p/r: T2", "p/r: T3"])])
    }
}

@Suite struct SilentRepoTests {
    @Test func silencedKindsAreDroppedPerRepo() {
        let account = Account(
            id: fixedAccountId, kind: .gitHub, displayName: "a", organization: "p", authMethod: .pat,
            repoWatch: [
                "p/quiet": WatchSet(prs: true, tags: true, completed: true, notifyPRs: false, notifyCompleted: false),
                "p/loud": .both,
            ]
        )
        let prs = [PullRequest.fixture(repo: "p/quiet", number: 1), PullRequest.fixture(repo: "p/loud", number: 2)]
        let tags = [Tag.fixture(repo: "p/quiet", name: "v1")]

        let audible = NotificationPlanner.audible(pullRequests: prs, tags: tags, completed: prs, accounts: [account])

        #expect(audible.pullRequests.map(\.repo) == ["p/loud"])
        #expect(audible.tags.map(\.repo) == ["p/quiet"])
        #expect(audible.completed.map(\.repo) == ["p/loud"])
    }

    @Test func oldWatchSetJSONNotifiesEverything() throws {
        let watch = try JSONDecoder().decode(WatchSet.self, from: Data(#"{"prs":true,"tags":false}"#.utf8))
        #expect(watch.notifyPRs && watch.notifyTags && watch.notifyCompleted)
    }
}
