import Foundation
import CryptoKit

public enum JSON: Codable, Equatable, Hashable, Sendable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSON { object[key] ?? .null }
    public var object: [String: JSON] { if case .object(let v) = self { return v }; return [:] }
    public var array: [JSON] { if case .array(let v) = self { return v }; return [] }
    public var string: String { if case .string(let v) = self { return v }; return "" }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public var bool: Bool { if case .bool(let v) = self { return v }; return number == 1 }
    public var isNull: Bool { self == .null }
    public var text: String { String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "" }
    public static func parse(_ data: Data) throws -> JSON { try JSONDecoder().decode(JSON.self, from: data) }
}
extension JSON: ExpressibleByStringLiteral { public init(stringLiteral value: String) { self = .string(value) } }
extension JSON: ExpressibleByIntegerLiteral { public init(integerLiteral value: Int) { self = .number(Double(value)) } }
extension JSON: ExpressibleByBooleanLiteral { public init(booleanLiteral value: Bool) { self = .bool(value) } }

public struct GatewayAddress: Equatable, Sendable {
    public let url: URL
    public init(_ raw: String) throws {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !input.contains("://") { input = "http://" + input }
        guard var c = URLComponents(string: input), ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              c.host != nil, c.user == nil, c.password == nil else { throw ClientError.message("请输入有效的 Hermes 网关地址") }
        c.query = nil; c.fragment = nil
        var path = c.path
        if let range = path.range(of: "/api/") { path = String(path[..<range.lowerBound]) }
        while path.hasSuffix("/") { path.removeLast() }
        c.path = path
        guard let url = c.url else { throw ClientError.message("网关地址无法解析") }
        self.url = url
    }
    public var key: String { SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() }
    public func endpoint(_ path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        c.path += path.hasPrefix("/") ? path : "/" + path
        c.queryItems = query.isEmpty ? nil : query
        return c.url!
    }
}

public enum ClientError: LocalizedError {
    case message(String), unauthorized, disconnected, timeout(String), rpc(Int, String)
    public var errorDescription: String? {
        switch self {
        case .message(let s): return s
        case .unauthorized: return "登录已过期，请重新登录"
        case .disconnected: return "与 Hermes 的连接已断开，正在重新连接"
        case .timeout(let method): return "等待网关响应超时（\(method)）"
        case .rpc(_, let s): return s
        }
    }
}

public struct Credentials: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var provider: String
    public var expiresAt: Double
    public init(_ json: JSON, previous: Credentials? = nil) throws {
        accessToken = json["access_token"].string
        guard !accessToken.isEmpty else { throw ClientError.message("网关未返回登录令牌") }
        refreshToken = json["refresh_token"].string.isEmpty ? (previous?.refreshToken ?? "") : json["refresh_token"].string
        provider = json["provider"].string.isEmpty ? (previous?.provider ?? "basic") : json["provider"].string
        expiresAt = json["expires_at"].number ?? Date().addingTimeInterval(3600).timeIntervalSince1970
    }
}

public struct Bot: Identifiable, Equatable, Codable, Sendable {
    public var id: String { profile }
    public let profile: String
    public var name: String
    public var subtitle: String
    public var canonicalID: String
    public var resolvedID: String
    public var preview: String
    public var lastActive: Double
    public var hasAvatar: Bool
    public var hidden: Bool
    public var metadata: JSON
    public init(_ row: JSON) {
        profile = row["name"].string
        metadata = row["ui_meta"]["hermes-bots"]
        name = [metadata["title"].string, row["display_name"].string, row["bot_title"].string, profile].first { !$0.isEmpty } ?? profile
        subtitle = row["description"].string
        let canonical = row["canonical_session"]
        canonicalID = canonical["id"].string
        resolvedID = canonical["resolved_id"].string.isEmpty ? canonicalID : canonical["resolved_id"].string
        preview = canonical["preview"].string
        lastActive = canonical["last_active"].number ?? 0
        hasAvatar = row["has_avatar"].bool
        hidden = metadata["hidden"].bool
    }
    public var paletteIndex: Int { profile.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xffff } % 7 }
    public static func canonical(from rows: [JSON]) -> JSON? {
        rows.first { row in
            let root = row["root_title"].string
            return root == "Bot Chat" || (root.isEmpty && row["title"].string == "Bot Chat")
        }
    }
}

public struct ChatAttachment: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    public var localURL: URL?
    public var remotePath: String?
    public var imageData: Data?
    public var byteCount: Int?
    public init(name: String, localURL: URL? = nil, remotePath: String? = nil, imageData: Data? = nil, byteCount: Int? = nil) {
        id = UUID().uuidString; self.name = name; self.localURL = localURL; self.remotePath = remotePath; self.imageData = imageData
        self.byteCount = byteCount
    }
}

public enum Delivery: String, Codable, Sendable { case sending, accepted, uncertain, failed, received }
public struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    /// Server receipt identity is separate from the lifetime of the visible bubble.
    public var serverID: String?
    public var role: String
    public var text: String
    public var timestamp: Date
    public var streaming = false
    public var delivery: Delivery = .received
    public var attachments: [ChatAttachment] = []
    public init(id: String = UUID().uuidString, role: String, text: String, timestamp: Date = Date()) {
        self.id = id; self.role = role; self.text = text; self.timestamp = timestamp
    }
    public static func from(_ row: JSON, index: Int = 0) -> ChatMessage? {
        let role = row["role"].string
        guard ["user", "assistant", "tool"].contains(role), row["display_kind"].string != "hidden" else { return nil }
        var text = row["text"].string
        if text.isEmpty { text = row["display_content"].string }
        if text.isEmpty { text = row["content"].string }
        if text.isEmpty {
            text = row["content"].array.compactMap { part -> String? in
                ["text", "input_text", "output_text"].contains(part["type"].string) ? part["text"].string : nil
            }.joined(separator: "\n")
        }
        let hasImages = row["content"].array.contains { $0["type"].string == "image_url" || $0["type"].string == "image" }
        if text.isEmpty && hasImages { text = "图片" }
        guard !text.isEmpty, !["[SILENT]", "NO_REPLY", "[NO_REPLY]"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let rowID = row["row_id"].number ?? row["id"].number
        let stampKey = row["timestamp"].isNull ? "missing-\(index)" : row["timestamp"].text
        let digest = SHA256.hash(data: Data("\(role)|\(text)|\(stampKey)".utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let stamp = row["timestamp"].number.map(Date.init(timeIntervalSince1970:))
            ?? ISO8601DateFormatter().date(from: row["timestamp"].string) ?? Date(timeIntervalSince1970: 0)
        let stringID = row["id"].string.isEmpty ? row["row_id"].string : row["id"].string
        var msg = ChatMessage(id: rowID.map { "row-\(Int($0))" } ?? (stringID.isEmpty ? "history-\(digest)" : "row-" + stringID), role: role, text: text, timestamp: stamp)
        msg.serverID = msg.id
        for (attachmentIndex, part) in row["content"].array.enumerated() {
            let image = part["image_url"]["url"].string
            if image.hasPrefix("data:image/"), let comma = image.firstIndex(of: ","), let bytes = Data(base64Encoded: String(image[image.index(after: comma)...])) {
                var attachment = ChatAttachment(name: "图片", imageData: bytes)
                attachment.id = msg.id + "-image-\(attachmentIndex)"
                msg.attachments.append(attachment)
            }
        }
        return msg
    }
    /// Gateway numeric row IDs order persisted history, including pages filling an offline gap.
    static func chronological(_ messages: [ChatMessage]) -> [ChatMessage] {
        func row(_ message: ChatMessage) -> Int64? {
            let key = message.serverID ?? message.id
            return key.hasPrefix("row-") ? Int64(key.dropFirst(4)) : nil
        }
        if messages.allSatisfy({ row($0) != nil }) { return messages.sorted { row($0)! < row($1)! } }
        if messages.allSatisfy({ $0.timestamp.timeIntervalSince1970 > 0 }) {
            return messages.enumerated().sorted { a, b in
                a.element.timestamp == b.element.timestamp ? a.offset < b.offset : a.element.timestamp < b.element.timestamp
            }.map(\.element)
        }
        return messages
    }
}

public struct PendingCard: Identifiable, Equatable, Sendable {
    public var id: String
    public var method: String
    public var params: JSON
    public var requestID: JSON
    public var viaRPC: Bool
    public init(id: String, method: String, params: JSON, requestID: JSON = .null, viaRPC: Bool = false) {
        self.id = id; self.method = method; self.params = params; self.requestID = requestID; self.viaRPC = viaRPC
    }
    public var isApproval: Bool { method == "approval" }
    public var isSecret: Bool { ["sudo", "secret", "vault.unlock", "vault.store"].contains(method) }
    public var title: String { isApproval ? "需要你的确认" : (isSecret ? "需要安全输入" : "需要你补充信息") }
    public var choices: [String] { let offered = params["choices"].array.map(\.string); return offered.isEmpty ? ["once", "deny"] : offered }
    public var questions: [JSON] { params["questions"].array.isEmpty ? [.object(["qid": "answer", "question": params["question"], "choices": params["choices"]])] : params["questions"].array }
}

public struct GatewayEvent: Sendable {
    public var type: String
    public var sessionID: String
    public var payload: JSON
    public var sequence: Int?
}
