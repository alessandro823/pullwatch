import Foundation
import Testing
@testable import PullwatchCore

final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func read(account: String) throws -> String? { lock.withLock { values[account] } }
    func write(_ secret: String, account: String) throws { lock.withLock { values[account] = secret } }
    func delete(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

@Suite(.serialized) struct KeychainTests {
    @Test func realKeychainRoundTrip() throws {
        let store = KeychainStore(service: "nl.torrisi.pullwatch.tests")
        let account = UUID().uuidString
        defer { try? store.delete(account: account) }

        #expect(try store.read(account: account) == nil)
        try store.write("first", account: account)
        #expect(try store.read(account: account) == "first")
        try store.write("second", account: account)
        #expect(try store.read(account: account) == "second")
        try store.delete(account: account)
        #expect(try store.read(account: account) == nil)
        try store.delete(account: account) // verwijderen van niet-bestaand item is geen fout
    }

    @Test func patSourceReadsByAccountId() async throws {
        let store = InMemorySecretStore()
        let id = UUID()
        try store.write("pat-123", account: id.uuidString)
        #expect(try await KeychainPATSource(store: store, accountId: id).token() == "pat-123")
    }

    @Test func patSourceMissingToken() async {
        let source = KeychainPATSource(store: InMemorySecretStore(), accountId: UUID())
        await #expect(throws: ProviderError.missingToken) { try await source.token() }
    }
}
