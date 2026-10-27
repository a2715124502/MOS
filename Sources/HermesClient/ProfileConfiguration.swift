import Foundation
import Observation

/// One editor owns one gateway/profile. A response from a retired login cannot update it.
@MainActor @Observable public final class ProfileConfiguration {
    public let profile: String
    private let api: GatewayTransport
    private let isActive: () -> Bool
    public var active: Bool { isActive() }
    public var busy = false
    public var loading = false
    public var error: String?
    public var notice: String?
    public var soul = ""
    private var originalSoul: String?
    public var model = ""
    public var provider = ""
    public var description = ""
    public var title = ""
    private var originalTitle = ""
    private var originalDescription = ""
    private var originalModel = ""
    private var originalProvider = ""
    public var modelLoaded = false
    public let routing: ProfileModelConfiguration
    public let messaging: ProfileMessagingConfiguration
    public var loaded = false
    public var models: [ChatModelOption] = []
    public var tools: [JSON] = []
    public var skills: [JSON] = []
    public var servers: [JSON] = []
    public var toolConfiguration: JSON = .null
    public var skillContent = ""
    public var skillPath = ""
    public var skillName: String?
    private var originalSkill: String?
    public var oauth: JSON = .null
    public var pendingModelWarning: String?
    private var pendingModel: (String, String)?
    public init(api: GatewayTransport, profile: String, isActive: @escaping () -> Bool) {
        self.api = api; self.profile = profile; self.isActive = isActive
        routing = ProfileModelConfiguration(api: api, profile: profile, isActive: isActive)
        messaging = ProfileMessagingConfiguration(api: api, profile: profile, isActive: isActive)
    }
    private func validate() throws { guard active, !Task.isCancelled else { throw ClientError.message("连接已变化，请重新载入配置后继续；当前草稿仍保留。") } }
    private func request(_ path: String, method: String = "GET", body: JSON? = nil, query: [URLQueryItem] = []) async throws -> JSON {
        try validate()
        let result = try await api.request(path, method: method, profile: profile, query: query, body: body)
        try validate()
        return result
    }
    private func run(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; error = nil; notice = nil
        defer { busy = false }
        do { try validate(); try await operation() }
        catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    public var hasSkillDraft: Bool { !skillContent.isEmpty && skillContent != originalSkill || skillName != nil && skillContent != originalSkill }
    public var hasDraft: Bool {
        loaded && (soul != originalSoul || description != originalDescription || title != originalTitle) || modelLoaded && (model != originalModel || provider != originalProvider) || hasSkillDraft || routing.hasDraft || messaging.hasDraft
    }
    public func discardSkill() { skillName = nil; skillPath = ""; skillContent = ""; originalSkill = nil }

    public func load() async {
        guard !loading, !busy else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let s = try await request("/api/profiles/\(profile)/soul")
            let c = try await request("/api/config")
            let rows = try await request("/api/profiles")
            let row = rows["profiles"].array.first { $0["name"].string == profile } ?? .null
            soul = s["content"].string; originalSoul = soul
            let cfg = c["config"].isNull ? c : c["config"]
            if !modelLoaded {
                let main = try await mainFields(cfg)
                model = main.0; provider = main.1; modelLoaded = true
                originalModel = model; originalProvider = provider
            }
            description = row["description"].string
            title = [row["bot_title"].string, row["display_name"].string, profile].first { !$0.isEmpty } ?? profile
            originalDescription = description; originalTitle = title
            loaded = true
        } catch { self.error = error.localizedDescription }
    }
    private func mainFields(_ config: JSON) async throws -> (String, String) {
        if case .object = config["model"] {
            return (config["model"]["default"].string, config["model"]["provider"].string)
        }
        // REST config normalizes model to a string; the scoped model endpoint owns provider.
        do {
            let r = try await request("/api/model/auxiliary")
            guard case .object = r["main"] else { throw ClientError.message("Hermes 未返回主模型配置") }
            return (r["main"]["model"].string, r["main"]["provider"].string)
        } catch {
            let r = try await request("/api/model/info")
            return (r["model"].string, r["provider"].string)
        }
    }
    public func loadModelBase() async {
        await run {
            let c = try await request("/api/config")
            let pair = try await mainFields(c["config"].isNull ? c : c["config"])
            model = pair.0; provider = pair.1
            originalModel = model; originalProvider = provider; modelLoaded = true
            pendingModel = nil; pendingModelWarning = nil
        }
    }
    public func loadModels() async {
        await run {
            let data = try await request("/api/model/options")
            models = try ChatModelOption.catalog(data)
        }
    }
    public func saveSoul() async {
        guard loaded, let originalSoul else { return }
        let draft = soul
        await run {
            let latest = try await request("/api/profiles/\(profile)/soul")
            guard latest["content"].string == originalSoul else { throw ClientError.message("SOUL.md 已在别处修改。请先保留草稿，再重新载入比较。") }
            let response = try await request("/api/profiles/\(profile)/soul", method: "PUT", body: .object(["content": .string(draft)]))
            guard response["ok"].bool else { throw ClientError.message("Hermes 未确认 SOUL.md 已保存") }
            self.originalSoul = draft; notice = "SOUL.md 已保存到 \(profile)"
        }
    }
    public func saveIdentity() async {
        guard loaded else { return }
        let draftTitle = title.trimmingCharacters(in: .whitespacesAndNewlines), draftDescription = description
        await run {
            var messages: [String] = []
            if draftTitle != originalTitle {
                guard !draftTitle.isEmpty else { throw ClientError.message("Bot 名称不能为空") }
                let listed = try await api.call("profiles.list", profile: profile)
                try validate()
                guard let row = listed["profiles"].array.first(where: { $0["name"].string == profile }), case .object(let revisions) = row["ui_meta_revisions"] else {
                    throw ClientError.message("当前 Hermes 不支持安全更新 Bot 显示名称，请升级网关后再试。")
                }
                let revision = revisions["hermes-bots"] ?? .number(0)
                let latestTitle = [row["ui_meta"]["hermes-bots"]["title"].string, row["display_name"].string, row["bot_title"].string, profile].first { !$0.isEmpty } ?? profile
                guard latestTitle == originalTitle else { throw ClientError.message("Bot 名称已在别处修改，请重新载入后比较。") }
                var metadata = row["ui_meta"]["hermes-bots"].object
                metadata["title"] = .string(draftTitle)
                let r = try await api.call("profiles.configure", params: ["name": .string(profile), "ui_meta": .object(["hermes-bots": .object(metadata)]), "ui_meta_expected_revisions": .object(["hermes-bots": revision])], profile: profile)
                try validate()
                guard r["applied"]["ui_meta"].bool else { throw ClientError.message("Bot 名称未保存，配置可能已被另一客户端更新") }
                originalTitle = draftTitle; messages.append("名称")
            }
            if draftDescription != originalDescription {
                let r = try await request("/api/profiles/\(profile)/description", method: "PUT", body: .object(["description": .string(draftDescription)]))
                guard r["ok"].bool else { throw ClientError.message("角色说明未保存") }
                originalDescription = draftDescription; messages.append("角色说明")
            }
            notice = messages.isEmpty ? "没有待保存的更改" : messages.joined(separator: "、") + "已保存"
        }
    }
    public func saveModel(confirmed: Bool = false) async {
        guard modelLoaded else { return }
        let chosen = confirmed ? pendingModel : (model, provider)
        guard let (chosenModel, chosenProvider) = chosen, !chosenModel.isEmpty, !chosenProvider.isEmpty else { error = "请选择或填写模型和服务商"; return }
        await run {
            let latest = try await mainFields(.null)
            guard latest.0 == originalModel, latest.1 == originalProvider else { throw ClientError.message("默认模型已在别处修改，请先保留草稿，再重新载入比较。") }
            let r = try await request("/api/model/set", method: "POST", body: .object(["profile": .string(profile), "scope": "main", "model": .string(chosenModel), "provider": .string(chosenProvider), "confirm_expensive_model": .bool(confirmed)]))
            if r["confirm_required"].bool {
                pendingModel = (chosenModel, chosenProvider); pendingModelWarning = r["confirm_message"].string
                return
            }
            guard r["ok"].bool else { throw ClientError.message("Hermes 未确认默认模型已保存") }
            model = r["model"].string.isEmpty ? chosenModel : r["model"].string
            provider = r["provider"].string.isEmpty ? chosenProvider : r["provider"].string
            originalModel = model; originalProvider = provider; pendingModel = nil; pendingModelWarning = nil
            notice = "默认模型已保存。当前正在进行的 Bot Chat 保留原模型，可从聊天输入区单独切换。"
        }
    }
    public func loadCapabilities(_ category: String) async {
        await run {
            switch category {
            case "tools": tools = try await request("/api/tools/toolsets").array
            case "skills": skills = try await request("/api/skills").array
            default: servers = try await request("/api/mcp/servers")["servers"].array
            }
        }
    }
    public func toggle(_ category: String, name: String, enabled: Bool) async {
        await run {
            let path = category == "tools" ? "/api/tools/toolsets/\(name)" : category == "skills" ? "/api/skills/toggle" : "/api/mcp/servers/\(name)/enabled"
            let r = try await request(path, method: "PUT", body: .object(["name": .string(name), "enabled": .bool(enabled)]))
            guard r["ok"].bool else { throw ClientError.message("Hermes 未确认设置已保存") }
            notice = "\(name) 已\(enabled ? "开启" : "关闭")；运行中的会话按 Hermes 生效规则更新。"
        }
        if error == nil { let message = notice; await loadCapabilities(category); notice = message }
    }
    public func loadTool(_ name: String) async { await run { toolConfiguration = .null; toolConfiguration = try await request("/api/tools/toolsets/\(name)/config") } }
    public func saveTool(_ name: String, provider: String, env: [String: String]) async {
        await run {
            if !env.isEmpty {
                _ = try await request("/api/tools/toolsets/\(name)/env", method: "PUT", body: .object(["env": .object(env.mapValues(JSON.string))]))
            }
            var needsAuth = false
            if !provider.isEmpty {
                let r = try await request("/api/tools/toolsets/\(name)/provider", method: "PUT", body: .object(["provider": .string(provider)]))
                needsAuth = r["needs_nous_auth"].bool
            }
            toolConfiguration = try await request("/api/tools/toolsets/\(name)/config")
            tools = try await request("/api/tools/toolsets").array
            notice = needsAuth ? "配置已保存，还需在 Hermes 完成 Nous 授权。" : "工具配置已保存到 \(profile)"
        }
    }
    public func loadSkill(_ name: String) async {
        await run {
            let r = try await request("/api/skills/content", query: [.init(name: "name", value: name)])
            skillName = name; skillPath = r["path"].string; skillContent = r["content"].string; originalSkill = skillContent
        }
    }
    public func saveSkill(create: Bool = false, name: String? = nil) async {
        guard let selectedName = name ?? skillName, !selectedName.isEmpty else { return }
        let draft = skillContent
        await run {
            if !create {
                let latest = try await request("/api/skills/content", query: [.init(name: "name", value: selectedName)])
                guard latest["content"].string == originalSkill else { throw ClientError.message("该 Skill 已在别处修改，请重新载入后比较。") }
            }
            let r = try await request(create ? "/api/skills" : "/api/skills/content", method: create ? "POST" : "PUT", body: .object(["name": .string(selectedName), "content": .string(draft)]))
            guard r["success"].bool || r["ok"].bool else { throw ClientError.message(r["error"].string.isEmpty ? "Skill 未保存" : r["error"].string) }
            skillName = selectedName; originalSkill = draft; notice = "Skill 已保存"
            skills = try await request("/api/skills").array
        }
    }
    public func installSkill(_ identifier: String) async {
        await run {
            let identifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty, !identifier.hasPrefix("-"), !identifier.contains(where: { $0.isNewline }) else { throw ClientError.message("请输入有效的 Skill 标识") }
            let r = try await request("/api/skills/hub/install", method: "POST", body: .object(["identifier": .string(identifier)]))
            guard r["ok"].bool || r["success"].bool || r["pid"].number != nil else { throw ClientError.message("Hermes 未确认安装任务已提交") }
            notice = "安装任务已提交到远端，完成后点击刷新查看。"
        }
    }
    public func saveServer(name: String, url: String, command: String, args: [String], env: [String:String], auth: String, token: String, editing: Bool) async {
        await run {
            guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else { throw ClientError.message("连接名称请使用字母、数字、短横线或下划线") }
            var fields: [String: JSON] = ["auth": .string(auth)]
            if !url.isEmpty {
                guard let endpoint = URL(string: url), ["https", "http"].contains(endpoint.scheme?.lowercased() ?? ""), endpoint.host != nil else { throw ClientError.message("请输入有效的 HTTP 或 HTTPS MCP 地址") }
                fields["url"] = .string(url)
            } else {
                guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientError.message("请填写远端执行的命令") }
                fields["command"] = .string(command); fields["args"] = .array(args.map(JSON.string))
            }
            if !env.isEmpty { fields["env"] = .object(env.mapValues(JSON.string)) }
            if editing {
                // Deep-merge only submitted fields. Existing secrets and other servers stay on the backend.
                _ = try await request("/api/config", method: "PUT", body: .object(["config": .object(["mcp_servers": .object([name: .object(fields)])])]))
                if !token.isEmpty { _ = try await api.call("mcp.servers.set_api_key", params: ["name": .string(name), "value": .string(token)], profile: profile); try validate() }
            } else {
                fields["name"] = .string(name)
                if !token.isEmpty { fields["bearer_token"] = .string(token) }
                _ = try await request("/api/mcp/servers", method: "POST", body: .object(fields))
            }
            servers = try await request("/api/mcp/servers")["servers"].array
            notice = "MCP 连接已保存到 \(profile)；可手动检查连接或进行授权。"
        }
    }
    public func checkServer(_ name: String) async {
        await run {
            let r = try await api.call("mcp.servers.test", params: ["name": .string(name)], profile: profile, timeout: 90)
            try validate()
            guard r["ok"].bool else { throw ClientError.message(r["error"].string.isEmpty ? "连接检查失败" : r["error"].string) }
            notice = "连接成功，发现 \(r["tools"].array.count) 个工具"
        }
    }
    public func beginOAuth(_ name: String) async {
        await run { oauth = try await request("/api/mcp/servers/\(name)/auth", method: "POST", body: .object([:])) }
    }
    public func refreshOAuth() async {
        let id = oauth["flow_id"].string
        guard !id.isEmpty else { return }
        await run { oauth = try await request("/api/mcp/oauth/flows/\(id)") }
    }
    public func cancelOAuth() async {
        let id = oauth["flow_id"].string
        guard !id.isEmpty else { oauth = .null; return }
        await run { _ = try await request("/api/mcp/oauth/flows/\(id)", method: "DELETE"); oauth = .null; notice = "授权已取消" }
    }
    public func removeServer(_ name: String) async {
        await run {
            _ = try await request("/api/mcp/servers/\(name)", method: "DELETE")
            servers = try await request("/api/mcp/servers")["servers"].array; notice = "MCP 连接已移除"
        }
    }
}
