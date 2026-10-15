import Foundation
import Testing
@testable import PullwatchCore

@Suite struct SystemProcessRunnerTests {
    @Test func returnsStatusAndStdout() async throws {
        let output = try await SystemProcessRunner().run(URL(filePath: "/bin/echo"), ["hello"])
        #expect(output == ProcessOutput(status: 0, stdout: "hello\n", stderr: ""))
    }

    @Test func timeoutTerminatesAndThrowsNetworkError() async {
        let runner = SystemProcessRunner(timeout: .milliseconds(300))
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: ProviderError.network("sh reageert niet (timeout)")) {
            try await runner.run(URL(filePath: "/bin/sh"), ["-c", "sleep 5"])
        }
        #expect(clock.now - start < .seconds(1))
    }

    @Test func drainsLargeOutputWithoutDeadlock() async throws {
        let output = try await SystemProcessRunner().run(
            URL(filePath: "/bin/sh"),
            ["-c", "head -c 200000 /dev/zero | tr '\\0' a"]
        )
        #expect(output.stdout.utf8.count == 200_000)
    }

    @Test func cancellationTerminatesProcess() async {
        let runner = SystemProcessRunner(timeout: .seconds(20))
        let task = Task { try await runner.run(URL(filePath: "/bin/sh"), ["-c", "sleep 5"]) }
        try? await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.now - start < .seconds(1))
    }
}
