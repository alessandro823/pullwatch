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
}
