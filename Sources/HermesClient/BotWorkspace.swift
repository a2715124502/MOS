import Foundation
import Observation

/// A workspace is pinned to one gateway and one Bot for its entire lifetime.
@Observable @MainActor public final class BotWorkspace {
    public let profile: String
    public private(set) var jobs: [ScheduledJob] = []
    public private(set) var boards: [WorkBoard] = []
    public private(set) var columns: [BoardColumn] = []
    public private(set) var selectedBoard = ""
    public private(set) var loadingJobs = false
    public private(set) var loadingBoard = false
    public private(set) var loadingBoards = false
    public private(set) var busy = false
    public private(set) var jobsError: String?
    public private(set) var boardError: String?
    public private(set) var warning: String?
    @ObservationIgnored private let api: GatewayTransport
    @ObservationIgnored private let isActive: () -> Bool
    @ObservationIgnored private var boardRevision = 0
    @ObservationIgnored private var pendingTaskSubmission: (fingerprint: Data, key: String)?
    private let base = "/api/plugins/kanban"
    public init(api: GatewayTransport, profile: String, isActive: @escaping () -> Bool = { true }) {
        self.api = api; self.profile = profile; self.isActive = isActive
    }
    private func request(_ path: String, method: String = "GET", board: String? = nil, body: JSON? = nil, query: [URLQueryItem] = []) async throws -> JSON {
        guard isActive() else { throw ClientError.disconnected }
        var items = query
        if let board { guard !board.isEmpty else { throw ClientError.message("请先选择一个看板") }; items.append(.init(name: "board", value: board)) }
        let value = try await api.request(path, method: method, profile: profile, query: items, body: body)
        guard isActive() else { throw ClientError.disconnected }
        return value
    }
    private func segment(_ value: String) throws -> String {
        guard !value.isEmpty, !value.contains("/"), !value.contains("\\"), value != ".", value != ".." else { throw ClientError.message("任务标识无效，请刷新后重试") }
        return value
    }
    public func loadJobs() async {
        guard !loadingJobs else { return }
        loadingJobs = true; defer { loadingJobs = false }
        do {
            let value = try await request("/api/cron/jobs")
            let rows: [JSON]
            if case .array(let a) = value { rows = a }
            else if case .array(let a) = value["jobs"] { rows = a }
            else { throw ClientError.message("网关返回的定时任务格式无法识别") }
            // Explicit profile on every request; reject an unexpected foreign owner.
            jobs = rows.filter { row in
                let owner = row["profile"].string.isEmpty ? row["profile_name"].string : row["profile"].string
                return owner.isEmpty || owner == profile
            }.map(ScheduledJob.init).filter { !$0.id.isEmpty }
            jobsError = nil
        } catch { if !Task.isCancelled { jobsError = error.localizedDescription } }
    }
    private func begin() throws {
        guard isActive() else { throw ClientError.disconnected }
        guard !busy else { throw ClientError.message("正在保存，请稍候") }
        busy = true; warning = nil
    }
    public func createJob(name: String, prompt: String, schedule: String, deliver: String = "bot-chat") async throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientError.message("请填写名称、任务内容和执行时间") }
        try begin(); defer { busy = false }
        let created = try await request("/api/cron/jobs", method: "POST", body: .object(["name": .string(name), "prompt": .string(prompt), "schedule": .string(schedule), "deliver": .string(deliver)]))
        guard !ScheduledJob(created).id.isEmpty else { throw ClientError.message("创建结果未确认，请先刷新任务列表，避免重复创建") }
        await loadJobs()
    }
    public func setPaused(_ job: ScheduledJob, paused: Bool) async throws {
        try begin(); defer { busy = false }
        _ = try await request("/api/cron/jobs/\(try segment(job.id))/\(paused ? "pause" : "resume")", method: "POST")
        await loadJobs()
    }
    public func jobRuns(_ id: String) async throws -> [JSON] {
        try await request("/api/cron/jobs/\(try segment(id))/runs", query: [.init(name: "limit", value: "20")])["runs"].array
    }
    public func loadBoards() async {
        guard !loadingBoards else { return }
        loadingBoards = true; defer { loadingBoards = false }
        do {
            let value = try await request(base + "/boards")
            guard case .array = value["boards"] else { throw ClientError.message("看板接口未返回有效列表，请确认 Kanban 插件已启用") }
            boards = value["boards"].array.map(WorkBoard.init).filter { !$0.slug.isEmpty }
            if !boards.contains(where: { $0.slug == selectedBoard }) {
                let current = value["current"].string
                await selectBoard(boards.contains(where: { $0.slug == current }) ? current : boards.first?.slug ?? "")
            } else { await refreshBoard() }
            if boards.isEmpty { columns = []; boardError = nil }
        } catch { if !Task.isCancelled { boardError = "看板未能加载：" + error.localizedDescription } }
    }
    public func selectBoard(_ slug: String) async {
        boardRevision += 1; loadingBoard = false; selectedBoard = slug; columns = []; boardError = nil
        if !slug.isEmpty { await refreshBoard() }
    }
    public func refreshBoard() async {
        guard !selectedBoard.isEmpty else { return }
        let slug = selectedBoard; boardRevision += 1; let revision = boardRevision
        loadingBoard = true
        defer { if revision == boardRevision { loadingBoard = false } }
        do {
            let value = try await request(base + "/board", board: slug)
            guard revision == boardRevision, slug == selectedBoard else { return }
            guard case .array = value["columns"] else { throw ClientError.message("看板内容格式无法识别") }
            columns = value["columns"].array.map(BoardColumn.init); boardError = nil
        } catch { if revision == boardRevision && !Task.isCancelled { boardError = error.localizedDescription } }
    }
    public func createBoard(slug: String, name: String) async throws {
        guard slug.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientError.message("看板标识请使用小写英文、数字、短横线或下划线，并填写名称") }
        try begin(); defer { busy = false }
        _ = try await request(base + "/boards", method: "POST", body: .object(["slug": .string(slug), "name": .string(name)]))
        await loadBoards(); await selectBoard(slug)
    }
    public func createTask(title: String, body: String, assignee: String, parents: [String] = [], priority: Int = 0, triage: Bool = false) async throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientError.message("请填写任务标题") }
        try begin(); defer { busy = false }
        let slug = selectedBoard
        var payload: [String: JSON] = [
            "title": .string(title), "body": .string(body), "assignee": assignee.isEmpty ? .null : .string(assignee),
            "parents": .array(parents.map(JSON.string)), "priority": .number(Double(priority)), "triage": .bool(triage)
        ]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fingerprint = try encoder.encode(JSON.object(["board": .string(slug), "payload": .object(payload)]))
        if pendingTaskSubmission?.fingerprint != fingerprint { pendingTaskSubmission = (fingerprint, UUID().uuidString) }
        payload["idempotency_key"] = .string(pendingTaskSubmission!.key)
        let result = try await request(base + "/tasks", method: "POST", board: slug, body: .object(payload))
        guard !result["task"]["id"].scalarString.isEmpty else { throw ClientError.message("任务提交结果未确认，请先刷新看板") }
        pendingTaskSubmission = nil
        if !result["warning"].string.isEmpty { warning = result["warning"].string }
        await afterBoardWrite(slug)
    }
    public func patchTask(_ id: String, patch: [String: JSON], board: String? = nil) async throws {
        try begin(); defer { busy = false }
        let slug = board ?? selectedBoard
        _ = try await request(base + "/tasks/\(try segment(id))", method: "PATCH", board: slug, body: .object(patch))
        await afterBoardWrite(slug)
    }
    public func linkTasks(parent: String, child: String, board: String? = nil) async throws {
        guard parent != child else { throw ClientError.message("任务不能依赖自己") }
        try begin(); defer { busy = false }
        let slug = board ?? selectedBoard
        _ = try await request(base + "/links", method: "POST", board: slug, body: .object(["parent_id": .string(parent), "child_id": .string(child)]))
        await afterBoardWrite(slug)
    }
    public func taskDetail(_ id: String, board: String) async throws -> JSON { try await request(base + "/tasks/\(try segment(id))", board: board) }
    public func taskLog(_ id: String, board: String) async throws -> JSON { try await request(base + "/tasks/\(try segment(id))/log", board: board, query: [.init(name: "tail", value: "16384")]) }
    public func addComment(_ id: String, board: String, text: String) async throws {
        try begin(); defer { busy = false }
        _ = try await request(base + "/tasks/\(try segment(id))/comments", method: "POST", board: board, body: .object(["body": .string(text), "author": "desktop"]))
    }
    public func dispatch() async throws {
        try begin(); defer { busy = false }
        _ = try await request(base + "/dispatch", method: "POST", board: selectedBoard, body: .object([:]))
        await refreshBoard()
    }
    private func afterBoardWrite(_ slug: String) async {
        // A saved edit stays saved even if the dispatcher or refresh is unavailable.
        do { _ = try await request(base + "/dispatch", method: "POST", board: slug, body: .object([:])) }
        catch { warning = "已保存；远端调度未能立即唤醒，请检查 Hermes 调度器：" + error.localizedDescription }
        if slug == selectedBoard { await refreshBoard() }
    }
}
