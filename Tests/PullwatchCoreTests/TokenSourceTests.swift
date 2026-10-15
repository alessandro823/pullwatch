import Foundation
import Testing
@testable import PullwatchCore

@Suite struct TokenSourceTests {
    let homebrew = CLILocator(isExecutable: { $0.hasPrefix("/opt/homebrew/bin/") })
    let nothing = CLILocator(isExecutable: { _ in false })

    @Test func locatorFindsFirstExecutableInSearchPaths() {
        let locator = CLILocator(isExecutable: { $0 == "/usr/local/bin/gh" })
        #expect(locator.locate("gh") == URL(filePath: "/usr/local/bin/gh"))
        #expect(locator.locate("az") == nil)
    }

    @Test func azParsesTokenAndCallsCorrectCommand() async throws {
        let clock = TestClock()
        let runner = MockProcessRunner()
        let expires = Int(clock.now.timeIntervalSince1970) + 3600
        runner.output = ProcessOutput(status: 0, stdout: #"{"accessToken":"tok1","expires_on":\#(expires)}"#, stderr: "")
        let source = AzCLISource(runner: runner, locator: homebrew, now: { clock.now })

        #expect(try await source.token() == "tok1")
        let call = try #require(runner.calls.first)
        #expect(call.0 == URL(filePath: "/opt/homebrew/bin/az"))
        #expect(call.1 == ["account", "get-access-token", "--resource", "499b84ac-1321-427f-aa17-267ca6975798", "--output", "json"])
    }

    @Test func azCachesUntilFiveMinutesBeforeExpiry() async throws {
        let clock = TestClock()
        let runner = MockProcessRunner()
        let expires = Int(clock.now.timeIntervalSince1970) + 3600
        runner.output = ProcessOutput(status: 0, stdout: #"{"accessToken":"tok1","expires_on":\#(expires)}"#, stderr: "")
        let source = AzCLISource(runner: runner, locator: homebrew, now: { clock.now })

        _ = try await source.token()
        clock.advance(3000)
        _ = try await source.token()
        #expect(runner.calls.count == 1)

        clock.advance(400) // nu binnen 5 minuten van expiry
        _ = try await source.token()
        #expect(runner.calls.count == 2)
    }

    @Test func azInvalidateForcesRefetch() async throws {
        let runner = MockProcessRunner()
        runner.output = ProcessOutput(status: 0, stdout: #"{"accessToken":"tok1"}"#, stderr: "")
        let source = AzCLISource(runner: runner, locator: homebrew)
        _ = try await source.token()
        await source.invalidate()
        _ = try await source.token()
        #expect(runner.calls.count == 2)
    }

    @Test func azNotFound() async {
        let source = AzCLISource(runner: MockProcessRunner(), locator: nothing)
        await #expect(throws: ProviderError.cliNotFound("az")) { try await source.token() }
    }

    @Test func azNonZeroExitMeansNotLoggedIn() async {
        let runner = MockProcessRunner()
        runner.output = ProcessOutput(status: 1, stdout: "", stderr: "Please run 'az login'")
        let source = AzCLISource(runner: runner, locator: homebrew)
        await #expect(throws: ProviderError.cliNotLoggedIn("az")) { try await source.token() }
    }

    @Test func ghTrimsTokenAndCaches() async throws {
        let runner = MockProcessRunner()
        runner.output = ProcessOutput(status: 0, stdout: "gho_abc\n", stderr: "")
        let source = GhCLISource(runner: runner, locator: homebrew)
        #expect(try await source.token() == "gho_abc")
        #expect(try await source.token() == "gho_abc")
        #expect(runner.calls.count == 1)
        #expect(runner.calls.first?.1 == ["auth", "token"])
    }

    @Test func ghEmptyOutputMeansNotLoggedIn() async {
        let runner = MockProcessRunner()
        runner.output = ProcessOutput(status: 0, stdout: "\n", stderr: "")
        let source = GhCLISource(runner: runner, locator: homebrew)
        await #expect(throws: ProviderError.cliNotLoggedIn("gh")) { try await source.token() }
    }

    @Test func staticTokenSource() async throws {
        #expect(try await StaticTokenSource(token: "x").token() == "x")
    }
}
