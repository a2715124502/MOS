import Foundation

/// All callers enqueue from the main actor; Security.framework runs on one background queue.
@MainActor public protocol CredentialStorage: AnyObject {
    func read(_ account: String) async throws -> Credentials?
    func save(_ credentials: Credentials, account: String) async throws
    func delete(_ account: String)
}
@MainActor public final class CredentialVault: CredentialStorage {
    public static let shared = CredentialVault()
    private let queue = DispatchQueue(label: "local.hermes.remote.credentials", qos: .userInitiated)
    public init() {}
    public func read(_ account: String) async throws -> Credentials? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try CredentialStore.read(account) }) }
        }
    }
    public func save(_ credentials: Credentials, account: String) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { continuation.resume(with: Result { try CredentialStore.save(credentials, account: account) }) }
        }
    }
    public func delete(_ account: String) { queue.async { CredentialStore.delete(account) } }
}
