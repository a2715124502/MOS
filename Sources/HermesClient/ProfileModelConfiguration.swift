import Foundation
import Observation

public struct AuxiliaryModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let hint: String
    public var provider: String
    public var model: String
    public var baseURL: String
    public var apiKey = ""
    init(_ row: JSON) {
        id = row["task"].string
        let labels = ["vision":"图像理解", "compression":"上下文压缩", "skills_hub":"技能检索", "approval":"审批判断", "mcp":"MCP 工具路由", "title_generation":"对话标题", "review":"结果审阅", "voice_chat":"语音对话", "triage_specifier":"任务分流", "kanban_decomposer":"看板任务拆解", "profile_describer":"角色描述", "curator":"记忆整理"]
        title = row["label"].string.isEmpty ? labels[id] ?? id : row["label"].string
        hint = row["hint"].string
        provider = row["provider"].string.isEmpty ? "auto" : row["provider"].string
        model = row["model"].string; baseURL = row["base_url"].string
    }
    var signature: [String] { [provider, model, baseURL] }
}
public struct FallbackModel: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var provider: String
    public var model: String
    private var extra: [String: JSON]
    public init(provider: String = "", model: String = "") { self.provider = provider; self.model = model; extra = [:] }
    init(_ raw: JSON) throws {
        if case .object(let fields) = raw {
            extra = fields; provider = fields["provider"]?.string ?? ""; model = fields["model"]?.string ?? ""
        } else if case .string(let value) = raw {
            let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
            provider = parts.count == 2 ? parts[0] : ""; model = parts.count == 2 ? parts[1] : value; extra = [:]
        } else { throw ClientError.message("备用列表含无法编辑的条目，请先在 Hermes 中修正；MOS 没有覆盖原配置。") }
    }
    public var endpoint: String { extra["base_url"]?.string ?? "" }
    public var hasExtraRouting: Bool { extra.keys.contains { !["provider", "model"].contains($0) } }
    var payload: JSON { var value = extra; value["provider"] = .string(provider.trimmingCharacters(in: .whitespacesAndNewlines)); value["model"] = .string(model.trimmingCharacters(in: .whitespacesAndNewlines)); return .object(value) }
}

@MainActor @Observable public final class ProfileModelConfiguration {
    public let profile: String
    private let api: GatewayTransport
    private let isActive: () -> Bool
    public var busy = false
    public var error: String?
    public var notice: String?
    public var auxiliary: [AuxiliaryModel] = []
    public var fallbacks: [FallbackModel] = []
    public var auxiliaryLoaded = false
    public var fallbackLoaded = false
    public var hasLegacyFallback = false
    public var pendingWarning: String?
    private var pending: AuxiliaryModel?
    private var originalAuxiliary: [AuxiliaryModel] = []
    private var originalFallback: JSON = .null
    private var originalLegacy: JSON = .null
    private var originalRows: [JSON] = []
    public var hasDraft: Bool { auxiliary != originalAuxiliary || fallbackLoaded && fallbacks.map(\.payload) != originalRows }
    public init(api: GatewayTransport, profile: String, isActive: @escaping () -> Bool) { self.api = api; self.profile = profile; self.isActive = isActive }
    private func request(_ path: String, method: String = "GET", body: JSON? = nil, query: [URLQueryItem] = []) async throws -> JSON {
        guard isActive(), !Task.isCancelled else { throw ClientError.disconnected }
        let r = try await api.request(path, method: method, profile: profile, query: query, body: body)
        guard isActive(), !Task.isCancelled else { throw ClientError.disconnected }; return r
    }
    private func run(_ work: () async throws -> Void) async {
        guard !busy else { return }; busy = true; error = nil; notice = nil
        defer { busy = false }
        do { try await work() } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func rawConfig() async throws -> JSON {
        let r = try await request("/api/config", query: [.init(name: "include_defaults", value: "false")]); return r["config"].isNull ? r : r["config"]
    }
    public func loadAuxiliary() async {
        await run {
            let r = try await request("/api/model/auxiliary")
            guard case .array = r["tasks"] else { throw ClientError.message("此 Hermes 未提供辅助模型目录，请升级网关后重试。") }
            auxiliary = r["tasks"].array.map(AuxiliaryModel.init).filter { !$0.id.isEmpty }
            originalAuxiliary = auxiliary; auxiliaryLoaded = true; cancelWarning()
        }
    }
    public func loadFallbacks() async {
        await run {
            let c = try await rawConfig()
            func rows(_ value: JSON) throws -> [FallbackModel] {
                if value.isNull { return [] }
                if case .array(let list) = value { return try list.map(FallbackModel.init) }
                if case .object(let fields) = value { return fields.isEmpty ? [] : [try FallbackModel(value)] }
                throw ClientError.message("备用配置格式无法安全编辑，请先在 Hermes 中修正。")
            }
            let primary = try rows(c["fallback_providers"]), legacy = try rows(c["fallback_model"])
            fallbacks = primary + legacy; originalRows = fallbacks.map(\.payload)
            originalFallback = c["fallback_providers"]; originalLegacy = c["fallback_model"]
            hasLegacyFallback = !legacy.isEmpty; fallbackLoaded = true
        }
    }
    public func confirmAuxiliary() async { if let id = pending?.id { await saveAuxiliary(id, confirmed: true) } }
    public func cancelWarning() { pending = nil; pendingWarning = nil }
    public func saveAuxiliary(_ id: String, confirmed: Bool = false) async {
        guard auxiliaryLoaded, let draft = (confirmed ? pending : auxiliary.first { $0.id == id }), let original = originalAuxiliary.first(where: { $0.id == id }) else { return }
        guard !draft.provider.isEmpty, ["auto", "main"].contains(draft.provider) || !draft.model.isEmpty else { error = "请填写服务商与模型，或选择自动／跟随主模型。"; return }
        if !draft.apiKey.isEmpty && draft.baseURL.isEmpty { error = "填写新 API Key 时需要同时填写自定义 API 地址；已有服务商的通用凭据由 Hermes 管理。"; return }
        if !draft.baseURL.isEmpty { guard let url = URL(string: draft.baseURL), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { error = "自定义地址需要完整的 HTTP 或 HTTPS URL。"; return } }
        await run {
            let latest = try await request("/api/model/auxiliary")
            guard let row = latest["tasks"].array.first(where: { $0["task"].string == id }), AuxiliaryModel(row).signature == original.signature else { throw ClientError.message("这个辅助模型已在别处修改，请先保留草稿，再重新载入比较。") }
            var body: [String:JSON] = ["scope":"auxiliary", "task":.string(id), "provider":.string(draft.provider), "model":.string(draft.model), "base_url":.string(draft.baseURL), "profile":.string(profile), "confirm_expensive_model":.bool(confirmed)]
            if !draft.apiKey.isEmpty { body["api_key"] = .string(draft.apiKey) }
            let r = try await request("/api/model/set", method:"POST", body:.object(body))
            if r["confirm_required"].bool { pending = draft; pendingWarning = r["confirm_message"].string.isEmpty ? "Hermes 要求确认此模型选择。" : r["confirm_message"].string; return }
            guard r["ok"].bool else { throw ClientError.message("Hermes 未确认辅助模型保存。") }
            // The write is confirmed: clear the submitted secret before the follow-up GET.
            if let i = auxiliary.firstIndex(where: { $0.id == id }) { auxiliary[i].apiKey = "" }
            cancelWarning(); notice = "辅助模型已写入 \(profile)；正在核对保存结果。"
            let saved = try await request("/api/model/auxiliary")
            guard let value = saved["tasks"].array.first(where: { $0["task"].string == id }) else { throw ClientError.message("保存已提交，但未读回该辅助模型，请刷新确认。") }
            let readback = AuxiliaryModel(value)
            if let i = auxiliary.firstIndex(where: { $0.id == id }) { auxiliary[i] = readback }
            if let i = originalAuxiliary.firstIndex(where: { $0.id == id }) { originalAuxiliary[i] = readback }
            notice = "\(readback.title) 已写入 \(profile) 的 Hermes 配置。"
        }
    }
    public func saveFallbacks() async {
        guard fallbackLoaded else { return }
        let rows = fallbacks.map(\.payload)
        guard rows.allSatisfy({ !$0["provider"].string.isEmpty && !$0["model"].string.isEmpty }) else { error = "每个备用节点都需要服务商和模型；请补齐或移除空行。"; return }
        await run {
            let latest = try await rawConfig()
            guard latest["fallback_providers"] == originalFallback, latest["fallback_model"] == originalLegacy else { throw ClientError.message("备用列表已在别处修改，请先保留草稿再重新载入。") }
            let r = try await request("/api/config", method:"PUT", body:.object(["profile":.string(profile), "config":.object(["fallback_providers":.array(rows), "fallback_model":.array([])])]))
            guard r["ok"].bool else { throw ClientError.message("Hermes 未确认备用列表保存。") }
            notice = "备用列表已提交，正在核对保存结果。"
            let saved = try await rawConfig()
            guard saved["fallback_providers"].array == rows, saved["fallback_model"].isNull || saved["fallback_model"] == .array([]) else { throw ClientError.message("写入已提交，但读回列表与预期不同；请刷新比较，不要重复提交。") }
            originalFallback = saved["fallback_providers"]; originalLegacy = saved["fallback_model"]; originalRows = rows; hasLegacyFallback = false
            notice = "备用列表已写入 \(profile)，按显示顺序依次尝试。"
        }
    }
}
