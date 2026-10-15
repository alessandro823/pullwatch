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
    public init() {}

    public func run(_ executable: URL, _ arguments: [String]) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            // GUI-apps erven geen shell-PATH; az/gh hebben zelf ook tools uit Homebrew nodig.
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = (CLILocator.defaultSearchPaths + [environment["PATH"] ?? ""]).joined(separator: ":")
            process.environment = environment

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.terminationHandler = { finished in
                let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: ProcessOutput(status: finished.terminationStatus, stdout: out, stderr: err))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
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
