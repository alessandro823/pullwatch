import Foundation

public struct JSONFileStore<Value: Codable & Sendable>: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Geeft `nil` als het bestand niet bestaat.
    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

public enum AppPaths {
    public static func file(_ name: String) -> URL {
        URL.applicationSupportDirectory
            .appending(path: "Pullwatch")
            .appending(path: name)
    }
}
