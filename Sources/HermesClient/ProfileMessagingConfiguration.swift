import Foundation
import Observation

public struct MessagingDraft: Equatable, Sendable {
    public var enabled: Bool
    public var values: [String:String]
    public var clear: Set<String> = []
    init(_ row: JSON) {
        enabled = row["enabled"].bool
        values = row["env_vars"].array.reduce(into: [:]) { result, field in
            guard !field["is_password"].bool, case .string(let value) = field["value"] else { return }
            result[field["key"].string] = value
        }
    }
}

@MainActor @Observable public final class ProfileMessagingConfiguration {
    public let profile: String
    private let api: GatewayTransport
    private let isActive: () -> Bool
    public var busy = false
    public var loaded = false
    public var error: String?
    public var notice: String?
    public var problem = false
    public var platforms: [JSON] = []
    public var drafts: [String:MessagingDraft] = [:]
    private var originals: [String:MessagingDraft] = [:]
    private var originalRows: [String:JSON] = [:]
    public var pairingPlatform: String?
    public var pairingID = ""
    public var pairing: JSON = .null
    public var allowedUsers = ""
    public var whatsappMode = "bot"
    public var hasDraft: Bool { drafts != originals || !pairingID.isEmpty }
    public init(api: GatewayTransport, profile: String, isActive: @escaping () -> Bool) { self.api = api; self.profile = profile; self.isActive = isActive }
    private func request(_ path: String, method: String = "GET", body: JSON? = nil) async throws -> JSON {
        guard isActive(), !Task.isCancelled else { throw ClientError.disconnected }
        let r = try await api.request(path, method: method, profile: profile, body: body)
        guard isActive(), !Task.isCancelled else { throw ClientError.disconnected }; return r
    }
    private func run(_ work: () async throws -> Void) async {
        guard !busy else { return }; busy = true; error = nil; notice = nil; problem = false
        defer { busy = false }
        do { try await work() } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func catalog() async throws -> [JSON] {
        let r = try await request("/api/messaging/platforms")
        guard case .array = r["platforms"] else { throw ClientError.message("当前 Hermes 未提供消息平台目录，请升级网关后重试。") }
        return r["platforms"].array.filter { !$0["id"].string.isEmpty }
    }
    public func load() async {
        await run {
            let rows = try await catalog(); platforms = rows
            for row in rows {
                let id = row["id"].string
                if drafts[id] == nil || drafts[id] == originals[id] { let draft = MessagingDraft(row); drafts[id] = draft; originals[id] = draft; originalRows[id] = row }
            }
            loaded = true
        }
    }
    private func component(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
    private func fingerprint(_ row: JSON) -> JSON {
        .object(["enabled":row["enabled"], "env":.array(row["env_vars"].array.map { .object(["key":$0["key"], "is_set":$0["is_set"], "redacted_value":$0["redacted_value"], "value":$0["value"]]) })])
    }
    public func reloadPlatform(_ id: String) async {
        await run {
            let rows = try await catalog()
            guard let row = rows.first(where: { $0["id"].string == id }) else { throw ClientError.message("平台目录已变化，请重新选择。") }
            platforms = rows; let draft = MessagingDraft(row)
            drafts[id] = draft; originals[id] = draft; originalRows[id] = row
            notice = "已重新载入此平台，放弃了它尚未保存的草稿。"
        }
    }
    public func save(_ id: String) async {
        guard let row = platforms.first(where: { $0["id"].string == id }), let draft = drafts[id] else { return }
        let fields = row["env_vars"].array
        if draft.enabled {
            let missing = fields.filter { field in
                let key = field["key"].string
                return field["required"].bool && (draft.clear.contains(key) || !field["is_set"].bool) && (draft.values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard missing.isEmpty else { error = "启用前请补齐：" + missing.map { $0["prompt"].string.isEmpty ? $0["key"].string : $0["prompt"].string }.joined(separator:"、"); return }
        }
        await run {
            let freshRows = try await catalog()
            guard let latest = freshRows.first(where: { $0["id"].string == id }), let originalRow = originalRows[id] else { throw ClientError.message("平台目录已变化，请刷新后比较。") }
            guard fingerprint(latest) == fingerprint(originalRow) else { throw ClientError.message("此平台的远端配置已变化。当前草稿仍保留，请先保留需要的内容，再用重新载入放弃草稿并比较。") }
            var env: [String:JSON] = [:]
            for field in fields {
                let key = field["key"].string, value = (draft.values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, !draft.clear.contains(key), value != originals[id]?.values[key] { env[key] = .string(value) }
            }
            let body: JSON = .object(["profile":.string(profile), "enabled":.bool(draft.enabled), "env":.object(env), "clear_env":.array(draft.clear.sorted().map(JSON.string))])
            let r = try await request("/api/messaging/platforms/" + component(id), method:"PUT", body:body)
            guard r["ok"].bool else { throw ClientError.message("Hermes 未确认平台配置保存。") }
            // Remove submitted secrets from the editor even if the following status refresh fails.
            var sanitized = draft
            for field in fields where field["is_password"].bool || field["value"].isNull { sanitized.values[field["key"].string] = nil }
            sanitized.clear = []; drafts[id] = sanitized; originals[id] = sanitized
            notice = "配置已写入 \(profile)，正在刷新平台状态。"
            let rows = try await catalog(); platforms = rows
            if let saved = rows.first(where: { $0["id"].string == id }) { let value = MessagingDraft(saved); drafts[id] = value; originals[id] = value; originalRows[id] = saved }
            notice = r["hot_served"].bool ? "已写入 \(profile)，Hermes 已收到重新加载通知。实际连接状态见上方。" : "已写入 \(profile)。若显示待重载，请在 Hermes 中重载该 profile 的消息网关。"
        }
    }
    public func check(_ id: String) async {
        await run {
            let r = try await request("/api/messaging/platforms/" + component(id) + "/test", method:"POST")
            problem = !r["ok"].bool || r["auth_posture"].string == "deny_all"
            notice = r["message"].string.isEmpty ? "Hermes 未返回状态说明。" : r["message"].string
        }
    }
    public func startPairing(_ platform: String) async {
        guard ["telegram", "whatsapp"].contains(platform), pairingID.isEmpty else { return }
        await run {
            let body: JSON = platform == "telegram" ? .object(["bot_name":.string("Hermes " + profile)]) : .object(["profile":.string(profile), "mode":.string(whatsappMode), "allowed_users":.string(allowedUsers), "reset_session":false])
            let r = try await request("/api/messaging/" + platform + "/onboarding/start", method:"POST", body:body)
            guard !r["pairing_id"].string.isEmpty else { throw ClientError.message("Hermes 未创建连接流程。") }
            pairingPlatform = platform; pairingID = r["pairing_id"].string; pairing = r
        }
    }
    public func refreshPairing() async {
        guard let platform = pairingPlatform, !pairingID.isEmpty else { return }
        await run {
            let r = try await request("/api/messaging/" + platform + "/onboarding/" + component(pairingID))
            var merged = pairing.object; merged.merge(r.object) { _, new in new }; pairing = .object(merged)
            if platform == "telegram", allowedUsers.isEmpty, !r["owner_user_id"].string.isEmpty { allowedUsers = r["owner_user_id"].string }
        }
    }
    public func cancelPairing() async {
        guard let platform = pairingPlatform, !pairingID.isEmpty else { return }
        await run {
            defer { pairingPlatform = nil; pairingID = ""; pairing = .null }
            _ = try await request("/api/messaging/" + platform + "/onboarding/" + component(pairingID), method:"DELETE")
        }
    }
    public func applyPairing() async {
        guard let platform = pairingPlatform, !pairingID.isEmpty else { return }
        let users = allowedUsers.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        if platform == "telegram", users.isEmpty { error = "请添加至少一个允许使用 Bot 的 Telegram 用户 ID。"; return }
        await run {
            let body: JSON = platform == "telegram" ? .object(["profile":.string(profile), "allowed_user_ids":.array(users.map(JSON.string))]) : .object(["profile":.string(profile), "mode":.string(whatsappMode), "allowed_users":.string(users.joined(separator: ","))])
            let r = try await request("/api/messaging/" + platform + "/onboarding/" + component(pairingID) + "/apply", method:"POST", body:body)
            guard r["ok"].bool else { throw ClientError.message("Hermes 未确认连接配置已应用。") }
            drafts[platform] = nil; originals[platform] = nil; originalRows[platform] = nil
            pairingPlatform = nil; pairingID = ""; pairing = .null
            notice = "连接配置已写入 \(profile)。" + (r["restart_started"].bool ? "Hermes 正在重载消息网关，可能短暂断线。" : "请按 Hermes 的实际状态确认网关是否需重载。")
        }
        if error == nil { let message = notice; await load(); notice = message }
    }
}
