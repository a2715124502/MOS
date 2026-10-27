import Foundation
import CryptoKit

/// A bounded display cache. Canonical session identity is always resolved again on reconnect.
struct ConversationSnapshot: Codable, Sendable {
    var profile: String
    var storedID: String
    var messages: [ChatMessage]
    var draft: String
    var scrollAnchor: String?
    var model: String
    var provider: String
}

struct WorkspaceSnapshot: Codable, Sendable {
    var version = 1
    var savedAt = Date()
    var bots: [Bot]
    var selected: String?
    var conversations: [ConversationSnapshot]
}

actor ConversationCache {
    private var owner: UUID?
    private var activeKey: String?
    private var revokedOwners: Set<UUID> = []
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("local.hermes.remote/Conversations", isDirectory: true)
    private let legacyDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("local.hermes.remote/Conversations", isDirectory: true)

    static func key(gateway: String, user: String) -> String {
        SHA256.hash(data: Data(JSON.array([.string(gateway), .string(user)]).text.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    func activate(_ owner: UUID, key: String) -> WorkspaceSnapshot? {
        guard !revokedOwners.contains(owner) else { return nil }
        self.owner = owner; activeKey = key
        let primary = directory.appendingPathComponent(key + ".json")
        let file = FileManager.default.fileExists(atPath: primary.path) ? primary : legacyDirectory.appendingPathComponent(key + ".json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 12 * 1024 * 1024,
              let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data),
              value.version == 1, Date().timeIntervalSince(value.savedAt) < 30 * 86400 else { return nil }
        if file != primary { save(value, key: key, owner: owner) }
        return value
    }
    func save(_ snapshot: WorkspaceSnapshot, key: String, owner: UUID) {
        guard self.owner == owner, activeKey == key else { return }
        var bounded = snapshot
        guard var data = try? JSONEncoder().encode(bounded) else { return }
        // Prefer recent messages in the selected chat over silently abandoning a large write.
        while data.count > 12 * 1024 * 1024 {
            if let index = bounded.conversations.indices.reversed().first(where: { bounded.conversations[$0].messages.count > 1 }) {
                let count = bounded.conversations[index].messages.count
                bounded.conversations[index].messages.removeFirst(max(1, count / 2))
            } else if bounded.conversations.count > 1 { bounded.conversations.removeLast() }
            else { return }
            guard let next = try? JSONEncoder().encode(bounded) else { return }; data = next
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(key + ".json")
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { /* Cache failure must never affect the connection or an admitted send. */ }
    }
    func deactivate(owner: UUID, key: String?, remove: Bool) {
        revokedOwners.insert(owner)
        if self.owner == owner { self.owner = nil; activeKey = nil }
        if remove, let key, activeKey != key {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(key + ".json"))
            try? FileManager.default.removeItem(at: legacyDirectory.appendingPathComponent(key + ".json"))
        }
    }
}
