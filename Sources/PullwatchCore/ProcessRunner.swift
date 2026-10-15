import Foundation

public struct ProcessOutput: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunner: Sendable {
    func run(_ executable: URL, _ arguments: [String]) async throws -> ProcessOutput
}

public struct SystemProcessRunner: ProcessRunner {
    private let timeout: Duration

    public init(timeout: Duration = .seconds(20)) {
        self.timeout = timeout
    }

    public func run(_ executable: URL, _ arguments: [String]) async throws -> ProcessOutput {
        let run = ProcessRun(executable: executable, arguments: arguments, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                run.start(continuation)
            }
        } onCancel: {
            run.stop(.failure(CancellationError()))
        }
    }
}

/// Eén uitvoering van een proces. De continuation wordt precies één keer hervat:
/// bij normale afronding, timeout of annulering. Alle toestand zit achter `lock`.
private final class ProcessRun: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let readers = DispatchGroup()
    private let executable: URL
    private let arguments: [String]
    private let timeout: Duration

    private var stdoutData = Data()
    private var stderrData = Data()
    private var continuation: CheckedContinuation<ProcessOutput, Error>?
    private var pendingResult: Result<ProcessOutput, Error>?
    private var finished = false
    private var timer: Task<Void, Never>?

    init(executable: URL, arguments: [String], timeout: Duration) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
    }

    func start(_ continuation: CheckedContinuation<ProcessOutput, Error>) {
        lock.withLock {
            if let pendingResult {
                continuation.resume(with: pendingResult)
                return
            }
            self.continuation = continuation

            process.executableURL = executable
            process.arguments = arguments
            // GUI-apps erven geen shell-PATH; az/gh hebben zelf ook tools uit Homebrew nodig.
            var environment = ProcessInfo.processInfo.environment
            let inherited = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            environment["PATH"] = (CLILocator.defaultSearchPaths + inherited).joined(separator: ":")
            process.environment = environment
            // Een CLI die op stdin wacht (interactieve prompt) mag niet blokkeren.
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            process.terminationHandler = { [self] finishedProcess in
                didTerminate(finishedProcess.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                finishLocked(.failure(error))
                return
            }

            // Pipes concurrent leegtrekken, anders blokkeert een grote output het proces.
            readers.enter()
            DispatchQueue.global().async { [self] in
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                lock.withLock { stdoutData = data }
                readers.leave()
            }
            readers.enter()
            DispatchQueue.global().async { [self] in
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                lock.withLock { stderrData = data }
                readers.leave()
            }

            timer = Task { [self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                stop(.failure(ProviderError.network("\(executable.lastPathComponent) reageert niet (timeout)")))
            }
        }
    }

    /// Beëindigt het proces (indien nog actief) en hervat met `result`, tenzij al afgerond.
    func stop(_ result: Result<ProcessOutput, Error>) {
        lock.withLock {
            guard !finished else { return }
            if process.isRunning {
                process.terminate()
            }
            finishLocked(result)
        }
    }

    private func didTerminate(_ status: Int32) {
        readers.notify(queue: .global()) { [self] in
            lock.withLock {
                finishLocked(.success(ProcessOutput(
                    status: status,
                    stdout: String(decoding: stdoutData, as: UTF8.self),
                    stderr: String(decoding: stderrData, as: UTF8.self)
                )))
            }
        }
    }

    /// Moet onder `lock` worden aangeroepen.
    private func finishLocked(_ result: Result<ProcessOutput, Error>) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        if let continuation {
            continuation.resume(with: result)
            self.continuation = nil
        } else {
            pendingResult = result
        }
    }
}

public struct CLILocator: Sendable {
    public static let defaultSearchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    private let searchPaths: [String]
    private let isExecutable: @Sendable (String) -> Bool

    public init(
        searchPaths: [String] = CLILocator.defaultSearchPaths,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.searchPaths = searchPaths
        self.isExecutable = isExecutable
    }

    public func locate(_ name: String) -> URL? {
        searchPaths
            .map { "\($0)/\(name)" }
            .first(where: isExecutable)
            .map { URL(filePath: $0) }
    }
}
