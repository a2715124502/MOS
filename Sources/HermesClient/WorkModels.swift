import Foundation

extension JSON {
    public var scalarString: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return value.isFinite && value.rounded() == value ? String(format: "%.0f", value) : String(value)
        default: return ""
        }
    }
}

public struct ScheduledJob: Identifiable, Equatable, Sendable {
    public let raw: JSON
    public var id: String { raw["id"].scalarString.isEmpty ? raw["job_id"].scalarString : raw["id"].scalarString }
    public var name: String { raw["name"].string.isEmpty ? "未命名任务" : raw["name"].string }
    public var prompt: String { raw["prompt"].string.isEmpty ? raw["prompt_preview"].string : raw["prompt"].string }
    public var completed: Bool { raw["state"].string == "completed" }
    public var paused: Bool { raw["enabled"] == .bool(false) || raw["state"].string == "paused" }
    public var schedule: String {
        if !raw["schedule_display"].string.isEmpty { return raw["schedule_display"].string }
        let s = raw["schedule"]
        if case .string(let text) = s { return text }
        for key in ["display", "expr", "cron", "raw", "at", "interval"] where !s[key].scalarString.isEmpty { return s[key].scalarString }
        return "由 Hermes 管理"
    }
    public var nextRun: String { raw["next_run_at"].scalarString }
    public var lastRun: String { raw["last_run_at"].scalarString }
    public var lastStatus: String { raw["last_status"].string }
    public init(_ raw: JSON) { self.raw = raw }
}

public struct WorkBoard: Identifiable, Equatable, Sendable {
    public var id: String { slug }
    public let slug: String
    public let name: String
    public init(_ raw: JSON) { slug = raw["slug"].string; name = raw["name"].string.isEmpty ? slug : raw["name"].string }
}
public struct BoardTask: Identifiable, Equatable, Sendable {
    public let raw: JSON
    public var id: String { raw["id"].scalarString }
    public var title: String { raw["title"].string }
    public var body: String { raw["body"].string }
    public var status: String { raw["status"].string }
    public var assignee: String { raw["assignee"].string }
    public var priority: Int { Int(raw["priority"].number ?? 0) }
    public var summary: String { raw["latest_summary"].string }
    public init(_ raw: JSON) { self.raw = raw }
}
public struct BoardColumn: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public let name: String
    public let tasks: [BoardTask]
    public init(_ raw: JSON) { name = raw["name"].string; tasks = raw["tasks"].array.map(BoardTask.init) }
    public static func label(_ name: String) -> String {
        ["triage": "待编排", "todo": "待办", "scheduled": "已排期", "ready": "待执行", "running": "执行中", "blocked": "受阻", "review": "待验收", "done": "已完成", "archived": "已归档"][name] ?? name
    }
}
