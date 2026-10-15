import Foundation
@testable import PullwatchCore

final class MockProcessRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var _output = ProcessOutput(status: 0, stdout: "", stderr: "")
    private var _calls: [(URL, [String])] = []

    var output: ProcessOutput {
        get { lock.withLock { _output } }
        set { lock.withLock { _output = newValue } }
    }

    var calls: [(URL, [String])] { lock.withLock { _calls } }

    func run(_ executable: URL, _ arguments: [String]) async throws -> ProcessOutput {
        lock.withLock {
            _calls.append((executable, arguments))
            return _output
        }
    }
}
