import Foundation

public struct ChatModelOption: Identifiable, Equatable, Sendable {
    public let model: String
    public let name: String
    public let provider: String
    public let providerName: String
    public let available: Bool
    public var id: String { JSON.array([.string(provider), .string(model)]).text }
    public static func catalog(_ payload: JSON) throws -> [ChatModelOption] {
        guard case .array(let providers) = payload["providers"] else { throw ClientError.message("Hermes 未返回有效的模型列表") }
        var seen = Set<String>()
        return providers.flatMap { row -> [ChatModelOption] in
            let provider = row["slug"].string
            guard !provider.isEmpty else { return [] }
            let unavailable = Set(row["unavailable_models"].array.map(\.string))
            return row["models"].array.compactMap { entry in
                let model = entry.string.isEmpty ? (entry["id"].string.isEmpty ? entry["name"].string : entry["id"].string) : entry.string
                guard !model.isEmpty else { return nil }
                let option = ChatModelOption(model: model, name: entry["name"].string.isEmpty ? model : entry["name"].string,
                    provider: provider, providerName: row["name"].string.isEmpty ? provider : row["name"].string,
                    available: row["authenticated"] != .bool(false) && !unavailable.contains(model))
                return seen.insert(option.id).inserted ? option : nil
            }
        }
    }
}
public struct ModelSwitchWarning: Sendable {
    public let message: String
    public let token: String
}

extension BotConversation {
    public var modelLabel: String { pendingModel.isEmpty ? (model.isEmpty ? "选择模型" : model) : pendingModel }
    public var modelProvider: String { pendingModel.isEmpty ? provider : pendingProvider }
    func adoptModel(_ snapshot: JSON) {
        let info = snapshot["info"].isNull ? snapshot : snapshot["info"]
        if !info["model"].string.isEmpty { model = info["model"].string }
        if !info["provider"].string.isEmpty { provider = info["provider"].string }
        if !pendingModel.isEmpty && model == pendingModel && (pendingProvider.isEmpty || provider == pendingProvider) { pendingModel = ""; pendingProvider = "" }
    }
}

extension ChatStore {
    public func loadModels(for chat: BotConversation, refresh: Bool = false) async {
        guard !demo, let api = transport, phase == .connected, !chat.loadingModels, !chat.switchingModel,
              conversations[chat.profile] === chat, !chat.runtimeID.isEmpty else { return }
        let sid = chat.runtimeID
        chat.loadingModels = true; chat.modelError = nil
        defer { chat.loadingModels = false }
        do {
            let result = try await api.call("model.options", params: ["session_id": .string(sid), "explicit_only": false, "include_unconfigured": false, "refresh": .bool(refresh)], profile: chat.profile, timeout: 25)
            guard transport === api, !demo, conversations[chat.profile] === chat, chat.runtimeID == sid else { return }
            chat.models = try ChatModelOption.catalog(result)
            if !result["model"].string.isEmpty { chat.adoptModel(result) }
        } catch { if transport === api, !demo, conversations[chat.profile] === chat { chat.modelError = readable(error) } }
    }

    /// Uses the current session owner; never rewrites the profile's default model.
    public func switchModel(_ choice: ChatModelOption, for chat: BotConversation, confirmed: Bool = false, token: String = "") async throws -> ModelSwitchWarning? {
        guard !demo, let api = transport, phase == .connected, conversations[chat.profile] === chat,
              chat.canSubmit, !chat.running, !chat.uploading, !chat.switchingModel else { throw ClientError.message("请等当前回复完成后再切换模型") }
        guard choice.available, [choice.model, choice.provider].allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && $0.rangeOfCharacter(from: .whitespacesAndNewlines) == nil }) else { throw ClientError.message("这个模型暂不可用") }
        let sid = chat.runtimeID
        chat.switchingModel = true; chat.modelError = nil
        defer { chat.switchingModel = false }
        func current() -> Bool { transport === api && !demo && phase == .connected && conversations[chat.profile] === chat && chat.runtimeID == sid }
        let result: JSON
        if api.sessionAuthority {
            let snapshot = try await api.call("session.resume", params: ["session_id": .string(sid), "omit_messages": true], profile: chat.profile)
            guard current(), !chat.running, !snapshot["running"].bool, !snapshot["info"]["running"].bool else { throw ClientError.message("会话状态已变化，请稍后重新选择模型") }
            guard let revision = snapshot["revision"].number, let generation = snapshot["execution_generation"].number else { throw ClientError.message("当前 Hermes 未提供模型切换所需的会话状态，请升级网关") }
            var payload: [String: JSON] = ["model": .string(choice.model), "provider": .string(choice.provider)]
            if confirmed {
                guard !token.isEmpty else { throw ClientError.message("确认已失效，请重新选择模型") }
                payload["confirm"] = .string(token)
            }
            result = try await api.call("session.mutate", params: ["session_id": .string(sid), "request_id": .string(UUID().uuidString), "operation": "model", "payload": .object(payload), "expected_revision": .number(revision), "expected_generation": .number(generation)], profile: chat.profile)
        } else {
            result = try await api.call("config.set", params: ["session_id": .string(sid), "key": "model", "value": .string("\(choice.model) --provider \(choice.provider) --session"), "confirm_expensive_model": .bool(confirmed)], profile: chat.profile)
        }
        guard current() else { throw ClientError.disconnected }
        if result["confirm_required"].bool || result["status"].string == "confirmation_required" {
            return ModelSwitchWarning(message: result["confirm_message"].string.isEmpty ? "Hermes 要求确认这次模型切换。" : result["confirm_message"].string, token: result["confirm"].string)
        }
        guard result["ok"] != .bool(false), ["", "applied", "committed", "deferred", "ok"].contains(result["status"].string),
              !result["model"].string.isEmpty || !result["value"].string.isEmpty else {
            throw ClientError.message(result["message"].string.isEmpty ? "Hermes 尚未确认模型切换，请刷新会话后重试" : result["message"].string)
        }
        if result["deferred"].bool || result["status"].string == "deferred" {
            chat.pendingModel = choice.model; chat.pendingProvider = choice.provider; chat.modelNotice = "已选择 \(choice.model)，从下一条消息起生效"
        } else {
            chat.model = result["model"].string.isEmpty ? result["value"].string : result["model"].string
            chat.provider = result["provider"].string.isEmpty ? choice.provider : result["provider"].string
            chat.pendingModel = ""; chat.pendingProvider = ""; chat.modelNotice = result["warning"].string.isEmpty ? nil : result["warning"].string
        }
        return nil
    }
}
