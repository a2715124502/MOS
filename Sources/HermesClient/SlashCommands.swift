import Foundation

public struct SlashCommand: Identifiable, Equatable, Sendable {
    public var name: String
    public var description: String
    public var kind: String
    public var id: String { name }
    static let unsupported: Set<String> = ["/quit", "/exit", "/sessions", "/resume", "/clear", "/skin", "/theme", "/voice"]
    public static let local: [SlashCommand] = [
        .init(name: "/help", description: "查看当前 Bot 的可用命令", kind: "command"),
        .init(name: "/model", description: "选择当前对话的模型", kind: "local"),
        .init(name: "/stop", description: "停止当前回复", kind: "local"),
        .init(name: "/compact", description: "整理当前 Bot Chat 的上下文", kind: "local"),
        .init(name: "/new", description: "整理上下文，保留 Bot Chat 与历史", kind: "local")
    ]
    public static func isInvocation(_ text: String) -> Bool {
        text.range(of: #"^/[A-Za-z0-9][A-Za-z0-9_-]*(?:\s|$)"#, options: .regularExpression) != nil
    }
    static func catalog(_ payload: JSON) -> [SlashCommand] {
        var result = local
        for row in payload["pairs"].array {
            guard row.array.count >= 2 else { continue }
            let name = row.array[0].string
            let meta = payload["commands"][name]
            guard name.hasPrefix("/"), !unsupported.contains(name),
                  !["terminal", "messaging", "hidden", "settings", "composer-voice"].contains(meta["desktop"].string),
                  !result.contains(where: { $0.name == name }) else { continue }
            result.append(.init(name: name, description: row.array[1].string, kind: payload["skills"][name].isNull ? "command" : "skill"))
        }
        return result
    }
}

extension ChatStore {
    public func loadCommands(for chat: BotConversation) async {
        guard !demo, phase == .connected, let api = transport, !chat.runtimeID.isEmpty, !chat.loadingCommands else { return }
        let sid = chat.runtimeID, serial = api.connectionSerial
        chat.loadingCommands = true; chat.commandError = nil
        defer { chat.loadingCommands = false }
        do {
            let payload = try await api.call("commands.catalog", params: ["session_id": .string(sid)], profile: chat.profile, timeout: 20)
            guard transport === api, serial == api.connectionSerial, conversations[chat.profile] === chat, sid == chat.runtimeID else { return }
            chat.commands = SlashCommand.catalog(payload)
            if !payload["warning"].string.isEmpty { chat.commandError = payload["warning"].string }
        } catch {
            guard transport === api, conversations[chat.profile] === chat else { return }
            if chat.commands.isEmpty { chat.commands = SlashCommand.local }
            chat.commandError = "命令目录暂不可用，显示客户端常用命令。" + readable(error)
        }
    }

    func executeCommand(_ command: String, for chat: BotConversation) async {
        guard let api = transport, phase == .connected, !chat.executingCommand else { return }
        let name = String(command.split(whereSeparator: { $0.isWhitespace }).first ?? "").lowercased()
        guard !SlashCommand.unsupported.contains(name) else { chat.error = "这个命令不适用于当前固定 Bot Chat，草稿已保留"; return }
        guard chat.attachments.isEmpty else { chat.error = "请先发送或移除附件，再执行命令"; return }
        if command == "/stop" {
            if await stop(chat), chat.draft.trimmingCharacters(in: .whitespacesAndNewlines) == command { chat.draft = "" }
            return
        }
        guard !chat.running else { chat.error = "请等待当前回复完成，或先使用 /stop"; return }
        let sid = chat.runtimeID, serial = api.connectionSerial
        chat.executingCommand = true; chat.commandOutput = nil; chat.error = nil
        defer { chat.executingCommand = false; cacheCurrentState() }
        do {
            let result: JSON
            if command == "/help" || command == "/commands" {
                await loadCommands(for: chat)
                chat.commandOutput = (chat.commands.isEmpty ? SlashCommand.local : chat.commands).map { "\($0.name)  \($0.description)" }.joined(separator: "\n")
                if chat.draft.trimmingCharacters(in: .whitespacesAndNewlines) == command { chat.draft = "" }
                return
            }
            do {
                result = try await api.call("slash.exec", params: ["session_id": .string(sid), "command": .string(command)], profile: chat.profile)
            } catch ClientError.rpc(4018, _) {
                let parts = command.dropFirst().split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                result = try await api.call("command.dispatch", params: ["session_id": .string(sid), "name": .string(String(parts[0])), "arg": .string(parts.count > 1 ? String(parts[1]) : "")], profile: chat.profile)
            }
            guard transport === api, serial == api.connectionSerial, conversations[chat.profile] === chat, sid == chat.runtimeID else { return }
            guard result["ok"] != .bool(false), !result["blocked"].bool,
                  !["refused", "error", "failed", "unsupported", "confirmation_required", "confirm_required"].contains(result["status"].string) else {
                throw ClientError.message(result["message"].string.isEmpty ? "命令未执行，请在 Hermes 中查看详情" : result["message"].string)
            }
            switch result["type"].string {
            case "skill", "send":
                guard !result["message"].string.isEmpty else { throw ClientError.message("Hermes 未返回命令内容") }
                chat.executingCommand = false
                await send(chat, prompt: result["message"].string)
            case "prefill":
                guard !result["message"].string.isEmpty else { throw ClientError.message("Hermes 未返回命令草稿") }
                chat.draft = result["message"].string
                chat.commandOutput = result["notice"].string
            default:
                let output = result["output"].string.isEmpty ? result["message"].string : result["output"].string
                guard !output.isEmpty || result["ok"].bool else { throw ClientError.message("Hermes 尚未确认命令执行结果，请先检查状态，不要重复执行") }
                chat.commandOutput = output.isEmpty ? "命令已完成" : output
                if chat.draft.trimmingCharacters(in: .whitespacesAndNewlines) == command { chat.draft = "" }
                await open(profile: chat.profile, force: true)
            }
        } catch {
            if transport === api, conversations[chat.profile] === chat {
                chat.error = "命令结果未确认，草稿已保留。" + readable(error)
            }
        }
    }
}
