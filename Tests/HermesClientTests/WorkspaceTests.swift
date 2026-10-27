import Foundation
import XCTest
@testable import HermesClient

@MainActor final class WorkspaceTests: XCTestCase {
    private let kanban = "/api/plugins/kanban"

    private func api() async throws -> GatewayTransport {
        guard let raw = ProcessInfo.processInfo.environment["HERMES_FIXTURE_URL"] else {
            throw XCTSkip("Workspace 集成测试需要本机 HTTP fixture")
        }
        let credentials = try Credentials(.object(["access_token": "fixture-access", "refresh_token": "fixture-refresh"]))
        let api = GatewayTransport(address: try GatewayAddress(raw), credentials: credentials)
        _ = try await api.request("/test/workspace/reset", method: "POST", body: .object([:]))
        return api
    }
    private func control(_ api: GatewayTransport, _ settings: [String: JSON]) async throws {
        _ = try await api.request("/test/workspace/control", method: "POST", body: .object(settings))
    }
    private func state(_ api: GatewayTransport) async throws -> JSON {
        try await api.request("/test/workspace/state")
    }
    private func rejects(_ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("无效或失效的操作必须明确失败", file: file, line: line) }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line) }
    }
    private func received(_ api: GatewayTransport, method: String, path: String) async throws {
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            let log = try await state(api)["log"].array
            if log.contains(where: { $0["method"].string == method && $0["path"].string == path }) { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTFail("fixture 未收到 \(method) \(path)")
    }
    private func tasks(_ workspace: BotWorkspace) -> [BoardTask] { workspace.columns.flatMap(\.tasks) }

    func testModelsKeepWireStringIdentifiersAndScheduleDisplay() {
        let job = ScheduledJob(.object(["id": "job-1", "name": "晨报", "schedule": .object(["kind": "cron", "expr": "0 8 * * *"])]))
        XCTAssertEqual(job.id, "job-1", "REST 路径必须使用原始标识，不能含 JSON 字符串引号")
        XCTAssertEqual(job.schedule, "0 8 * * *")
        XCTAssertEqual(ScheduledJob(.object(["job_id": "fallback-job"])).id, "fallback-job")
        XCTAssertEqual(BoardTask(.object(["id": "task-1"])).id, "task-1")
        XCTAssertEqual(ScheduledJob(.object(["id": 42])).id, "42")
        XCTAssertEqual(BoardTask(.object(["id": 99])).id, "99")
        XCTAssertEqual(ScheduledJob(.object(["id": .null, "job_id": "fallback-job"])).id, "fallback-job")
        XCTAssertTrue(ScheduledJob(.object(["id": .null])).id.isEmpty)
        XCTAssertTrue(ScheduledJob(.object([:])).id.isEmpty)
        XCTAssertTrue(BoardTask(.object(["id": .null])).id.isEmpty)
        XCTAssertTrue(BoardTask(.object(["id": true])).id.isEmpty)
    }

    func testCronProfileIsolationPauseResumeAndRunHistory() async throws {
        let api = try await api()
        let writer = BotWorkspace(api: api, profile: "writer"), ops = BotWorkspace(api: api, profile: "ops")
        try await control(api, ["foreign_jobs": true])
        await writer.loadJobs(); await ops.loadJobs()
        XCTAssertNil(writer.jobsError); XCTAssertNil(ops.jobsError)
        XCTAssertEqual(writer.jobs.count, 1); XCTAssertEqual(ops.jobs.count, 1)
        XCTAssertEqual(writer.jobs.first?.name, "writer daily")
        XCTAssertEqual(ops.jobs.first?.name, "ops daily")
        let job = try XCTUnwrap(writer.jobs.first)
        try await writer.setPaused(job, paused: true)
        XCTAssertTrue(try XCTUnwrap(writer.jobs.first).paused)
        await ops.loadJobs()
        XCTAssertFalse(try XCTUnwrap(ops.jobs.first).paused, "相同 job id 在另一个 profile 中不能被暂停")
        try await writer.setPaused(try XCTUnwrap(writer.jobs.first), paused: false)
        XCTAssertFalse(try XCTUnwrap(writer.jobs.first).paused)
        let runs = try await writer.jobRuns(job.id)
        XCTAssertEqual(runs.first?["profile"].string, "writer")
        let snapshot = try await state(api)
        XCTAssertTrue(snapshot["log"].array.allSatisfy { ["writer", "ops"].contains($0["profile"].string) })
    }

    func testCronCreateBusyGuardSubmitsOnceAndKeepsProfilesSeparate() async throws {
        let api = try await api()
        let writer = BotWorkspace(api: api, profile: "writer")
        try await control(api, ["delays": .object(["POST /api/cron/jobs": 250])])
        let first = Task { try await writer.createJob(name: "晨报", prompt: "总结今天", schedule: "0 8 * * *") }
        try await received(api, method: "POST", path: "/api/cron/jobs")
        XCTAssertTrue(writer.busy)
        await rejects { try await writer.createJob(name: "重复晨报", prompt: "重复", schedule: "0 8 * * *") }
        try await first.value
        XCTAssertFalse(writer.busy)
        XCTAssertEqual(writer.jobs.count, 2)
        let snapshot = try await state(api)
        XCTAssertEqual(snapshot["jobs"]["writer"].object.count, 2)
        XCTAssertEqual(snapshot["jobs"]["ops"].object.count, 1)
        let posts = snapshot["log"].array.filter { $0["method"].string == "POST" && $0["path"].string == "/api/cron/jobs" }
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?["profile"].string, "writer")
        XCTAssertEqual(posts.first?["body"]["deliver"].string, "bot-chat")
        XCTAssertEqual(posts.first?["body"]["prompt"].string, "总结今天")
    }

    func testBoardSelectionAndCreationNeverChangeServerCurrentPointer() async throws {
        let api = try await api()
        let writer = BotWorkspace(api: api, profile: "writer")
        await writer.loadBoards()
        XCTAssertEqual(writer.selectedBoard, "main")
        await writer.selectBoard("secondary")
        XCTAssertTrue(tasks(writer).allSatisfy { $0.title.hasPrefix("secondary") })
        try await writer.createBoard(slug: "third-board", name: "第三个共享看板")
        XCTAssertEqual(writer.selectedBoard, "third-board")
        XCTAssertTrue(writer.columns.allSatisfy { $0.tasks.isEmpty })
        let snapshot = try await state(api)
        XCTAssertEqual(snapshot["current"].string, "main")
        XCTAssertEqual(snapshot["boards"].object.count, 3)
        for entry in snapshot["log"].array {
            XCTAssertEqual(entry["profile"].string, "writer")
            XCTAssertFalse(entry["path"].string.hasSuffix("/switch"))
            if entry["path"].string == kanban + "/boards" {
                XCTAssertTrue(entry["board"].isNull)
                XCTAssertFalse(entry["body"]["switch"].bool)
            } else { XCTAssertFalse(entry["board"].string.isEmpty) }
        }
    }

    func testSharedBoardAssignmentDependenciesDetailCommentsAndLog() async throws {
        let api = try await api()
        let writer = BotWorkspace(api: api, profile: "writer"), ops = BotWorkspace(api: api, profile: "ops")
        await writer.loadBoards(); await ops.loadBoards()
        try await writer.createTask(title: "交给运维的依赖任务", body: "先完成父任务", assignee: "ops", parents: ["task-1"], priority: 3)
        await ops.refreshBoard()
        let child = try XCTUnwrap(tasks(ops).first { $0.title == "交给运维的依赖任务" })
        XCTAssertEqual(child.assignee, "ops"); XCTAssertEqual(child.status, "blocked"); XCTAssertEqual(child.priority, 3)
        try await writer.linkTasks(parent: "task-1", child: "task-2")
        var detail = try await ops.taskDetail("task-2", board: "main")
        XCTAssertEqual(detail["links"]["parents"].array, [.string("task-1")])
        try await ops.patchTask("task-2", patch: ["status": "review", "assignee": "writer"])
        try await ops.addComment("task-2", board: "main", text: "请验收")
        detail = try await writer.taskDetail("task-2", board: "main")
        XCTAssertEqual(detail["task"]["status"].string, "review")
        XCTAssertEqual(detail["task"]["assignee"].string, "writer")
        XCTAssertEqual(detail["comments"].array.first?["body"].string, "请验收")
        XCTAssertFalse(detail["runs"].array.isEmpty); XCTAssertFalse(detail["events"].array.isEmpty)
        XCTAssertTrue(detail["task"]["comments"].isNull, "详情的 comments/runs/events 是与 task 并列的字段")
        let log = try await writer.taskLog("task-2", board: "main")
        XCTAssertEqual(log["content"].string, "fixture worker log")
        let secondary = try await writer.taskDetail("task-2", board: "secondary")
        XCTAssertEqual(secondary["task"]["status"].string, "todo", "共享看板不等于不同 board 之间混写")
        let snapshot = try await state(api)
        let posts = snapshot["log"].array.filter { $0["path"].string == kanban + "/tasks" && $0["method"].string == "POST" }
        XCTAssertEqual(posts.count, 1)
        XCTAssertFalse(posts.first?["body"]["idempotency_key"].string.isEmpty ?? true)
        XCTAssertEqual(snapshot["current"].string, "main")
        XCTAssertTrue(snapshot["log"].array.allSatisfy { ["writer", "ops"].contains($0["profile"].string) })
        XCTAssertTrue(snapshot["log"].array.filter { $0["path"].string != kanban + "/boards" }.allSatisfy { !$0["board"].string.isEmpty })
    }

    func testBoardTaskWireIDCanBeUsedForDetailAndMutation() async throws {
        let api = try await api()
        let writer = BotWorkspace(api: api, profile: "writer")
        await writer.loadBoards()
        let task = try XCTUnwrap(tasks(writer).first)
        let detail = try await writer.taskDetail(task.id, board: writer.selectedBoard)
        XCTAssertEqual(detail["task"]["id"].string, task.id)
        try await writer.patchTask(task.id, patch: ["status": "review"])
    }

    func testBoardBusyGuardPreventsDuplicateSaveAndReleasesAfterCompletion() async throws {
        let api = try await api()
        let writer = BotWorkspace(api: api, profile: "writer")
        await writer.loadBoards()
        try await control(api, ["delays": .object(["POST /api/plugins/kanban/tasks": 250])])
        let first = Task { try await writer.createTask(title: "只保存一次", body: "", assignee: "writer") }
        try await received(api, method: "POST", path: kanban + "/tasks")
        XCTAssertTrue(writer.busy)
        await rejects { try await writer.createTask(title: "只保存一次", body: "", assignee: "writer") }
        await rejects { try await writer.patchTask("task-1", patch: ["title": "不应混入另一次写入"]) }
        try await first.value
        XCTAssertFalse(writer.busy)
        let snapshot = try await state(api)
        XCTAssertEqual(snapshot["log"].array.filter { $0["path"].string == kanban + "/tasks" && $0["method"].string == "POST" }.count, 1)
        XCTAssertEqual(tasks(writer).filter { $0.title == "只保存一次" }.count, 1)
    }

    func testInvalidInputIsRejectedAndDoesNotLeaveBusyStuck() async throws {
        let api = try await api()
        let writer = BotWorkspace(api: api, profile: "writer")
        await rejects { try await writer.createJob(name: " ", prompt: "x", schedule: "0 8 * * *") }
        await rejects { try await writer.createTask(title: "\n", body: "", assignee: "writer") }
        await rejects { try await writer.createBoard(slug: "../unsafe", name: "bad") }
        await rejects { try await writer.linkTasks(parent: "task-1", child: "task-1") }
        await rejects { _ = try await writer.jobRuns("../bad") }
        await rejects { _ = try await writer.taskDetail("../bad", board: "main") }
        await rejects { _ = try await writer.taskLog("bad/id", board: "main") }
        await rejects { try await writer.patchTask("..", patch: ["status": "done"]) }
        XCTAssertFalse(writer.busy)
        let beforeServerValidation = try await state(api)
        XCTAssertTrue(beforeServerValidation["log"].array.isEmpty)
        await writer.selectBoard("main")
        await rejects { try await writer.createJob(name: "bad cron", prompt: "x", schedule: "invalid-schedule") }
        await rejects { try await writer.patchTask("task-1", patch: ["status": "not-a-status"]) }
        await rejects { try await writer.addComment("task-1", board: "main", text: "  ") }
        XCTAssertFalse(writer.busy)
        try await writer.addComment("task-1", board: "main", text: "失败后仍可保存")
    }

    func testUnavailableInterfacesExposeErrorsAndRecover() async throws {
        let api = try await api()
        let writer = BotWorkspace(api: api, profile: "writer")
        try await control(api, ["cron_unavailable": true, "kanban_unavailable": true])
        await writer.loadJobs(); await writer.loadBoards()
        XCTAssertNotNil(writer.jobsError); XCTAssertNotNil(writer.boardError)
        await rejects { try await writer.createJob(name: "x", prompt: "x", schedule: "0 8 * * *") }
        await writer.selectBoard("main")
        await rejects { try await writer.createTask(title: "x", body: "", assignee: "writer") }
        XCTAssertFalse(writer.busy)
        try await control(api, ["cron_unavailable": false, "kanban_unavailable": false])
        await writer.loadJobs(); await writer.loadBoards()
        XCTAssertNil(writer.jobsError); XCTAssertNil(writer.boardError)
        XCTAssertFalse(writer.jobs.isEmpty); XCTAssertFalse(writer.columns.isEmpty)
    }

    func testDispatcherFailureLeavesSavedTaskWithWarningAndNoRetryDuplicate() async throws {
        let api = try await api()
        let writer = BotWorkspace(api: api, profile: "writer")
        await writer.loadBoards()
        try await control(api, ["dispatch_failure": true])
        try await writer.createTask(title: "已保存但调度失败", body: "", assignee: "ops")
        XCTAssertTrue(writer.warning?.contains("已保存") == true)
        XCTAssertEqual(tasks(writer).filter { $0.title == "已保存但调度失败" }.count, 1)
        await rejects { try await writer.dispatch() }
        XCTAssertFalse(writer.busy)
        try await control(api, ["dispatch_failure": false, "create_warning": "fixture dispatcher not running"])
        try await writer.createTask(title: "服务端创建警告", body: "", assignee: "writer")
        XCTAssertEqual(writer.warning, "fixture dispatcher not running")
        let snapshot = try await state(api)
        XCTAssertEqual(snapshot["log"].array.filter { $0["path"].string == kanban + "/tasks" && $0["method"].string == "POST" }.count, 2)
    }

    func testInactiveGatewayRejectsEveryReadAndWriteWithoutHTTPRequests() async throws {
        let api = try await api()
        let writer = BotWorkspace(api: api, profile: "writer", isActive: { false })
        await writer.loadJobs(); await writer.loadBoards(); await writer.selectBoard("main"); await writer.refreshBoard()
        XCTAssertNotNil(writer.jobsError); XCTAssertNotNil(writer.boardError)
        await rejects { try await writer.createJob(name: "x", prompt: "x", schedule: "0 8 * * *") }
        await rejects { try await writer.setPaused(ScheduledJob(.object(["id": "shared-job"])), paused: true) }
        await rejects { _ = try await writer.jobRuns("shared-job") }
        await rejects { try await writer.createBoard(slug: "new-board", name: "x") }
        await rejects { try await writer.createTask(title: "x", body: "", assignee: "writer") }
        await rejects { try await writer.patchTask("task-1", patch: ["status": "done"]) }
        await rejects { try await writer.linkTasks(parent: "task-1", child: "task-2") }
        await rejects { _ = try await writer.taskDetail("task-1", board: "main") }
        await rejects { _ = try await writer.taskLog("task-1", board: "main") }
        await rejects { try await writer.addComment("task-1", board: "main", text: "x") }
        await rejects { try await writer.dispatch() }
        let snapshot = try await state(api)
        XCTAssertTrue(snapshot["log"].array.isEmpty)
        XCTAssertFalse(writer.busy)
    }

    func testGatewayRetirementRejectsInFlightResponseAndDoesNotPublishOldJobs() async throws {
        let api = try await api()
        try await control(api, ["delays": .object(["GET /api/cron/jobs": 250])])
        var active = true
        let writer = BotWorkspace(api: api, profile: "writer", isActive: { active })
        let loading = Task { await writer.loadJobs() }
        try await received(api, method: "GET", path: "/api/cron/jobs")
        active = false
        await loading.value
        XCTAssertTrue(writer.jobs.isEmpty); XCTAssertNotNil(writer.jobsError)
        await rejects { try await writer.createJob(name: "old gateway", prompt: "x", schedule: "0 8 * * *") }
        let snapshot = try await state(api)
        XCTAssertEqual(snapshot["log"].array.count, 1, "失效后不能追加旧网关请求")
    }

    func testSlowerPreviousBoardCannotOverwriteNewSelection() async throws {
        let api = try await api()
        let writer = BotWorkspace(api: api, profile: "writer")
        try await control(api, ["delays": .object(["GET /api/plugins/kanban/board?board=main": 250])])
        let first = Task { await writer.selectBoard("main") }
        try await received(api, method: "GET", path: kanban + "/board")
        await writer.selectBoard("secondary")
        await first.value
        XCTAssertEqual(writer.selectedBoard, "secondary")
        XCTAssertFalse(writer.loadingBoard)
        XCTAssertTrue(tasks(writer).allSatisfy { $0.title.hasPrefix("secondary") })
    }

    func testMalformedReadShapesExposeErrorsAndPreservePreviouslyLoadedData() async throws {
        let api = try await api()
        let writer = BotWorkspace(api: api, profile: "writer")
        await writer.loadJobs(); await writer.loadBoards()
        let previousJobCount = writer.jobs.count, previousTaskCount = tasks(writer).count
        try await control(api, ["responses": .object([
            "/api/cron/jobs": .object(["jobs": .object([:])]),
            "/api/plugins/kanban/boards": .object(["boards": .object([:])]),
            "/api/plugins/kanban/board": .object(["columns": .object([:])])
        ])])
        await writer.loadJobs()
        XCTAssertNotNil(writer.jobsError); XCTAssertEqual(writer.jobs.count, previousJobCount)
        await writer.loadBoards()
        XCTAssertNotNil(writer.boardError)
        await writer.refreshBoard()
        XCTAssertNotNil(writer.boardError); XCTAssertEqual(tasks(writer).count, previousTaskCount)
        XCTAssertFalse(writer.loadingJobs); XCTAssertFalse(writer.loadingBoard)
        try await control(api, ["responses": .object([:])])
        await writer.loadJobs(); await writer.loadBoards()
        XCTAssertNil(writer.jobsError); XCTAssertNil(writer.boardError)
    }

    func testCreateResponsesWithoutConfirmedIDsAreRejected() async throws {
        let api = try await api()
        let writer = BotWorkspace(api: api, profile: "writer")
        await writer.loadBoards()
        for invalidID in [JSON.null, JSON.string("")] {
            try await control(api, ["create_job_response": .object(["id": invalidID]), "create_task_response": .object(["task": .object(["id": invalidID])])])
            await rejects { try await writer.createJob(name: "未确认的任务", prompt: "x", schedule: "0 8 * * *") }
            await rejects { try await writer.createTask(title: "未确认的看板任务-" + invalidID.text, body: "", assignee: "writer") }
            XCTAssertFalse(writer.busy)
        }
        try await control(api, ["create_job_response": .object([:]), "create_task_response": .object(["task": .object([:])])])
        await rejects { try await writer.createJob(name: "缺少ID", prompt: "x", schedule: "0 8 * * *") }
        await rejects { try await writer.createTask(title: "缺少task.id", body: "", assignee: "writer") }
    }

    func testSavedButTimedOutTaskRetryReusesKeyAndConfirmedNextSubmissionGetsNewKey() async throws {
        let api = try await api()
        let writer = BotWorkspace(api: api, profile: "writer")
        await writer.loadBoards()
        try await control(api, ["task_response_lost_once": true])
        await rejects { try await writer.createTask(title: "超时后的安全重试", body: "相同内容", assignee: "ops", parents: ["task-1"], priority: 2) }
        XCTAssertFalse(writer.busy)
        var snapshot = try await state(api)
        XCTAssertEqual(snapshot["boards"]["main"]["tasks"].object.count, 3, "第一次请求虽未获确认，但任务已经持久化到fixture状态")
        try await writer.createTask(title: "超时后的安全重试", body: "相同内容", assignee: "ops", parents: ["task-1"], priority: 2)
        snapshot = try await state(api)
        var posts = snapshot["log"].array.filter { $0["method"].string == "POST" && $0["path"].string == kanban + "/tasks" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0]["body"]["idempotency_key"], posts[1]["body"]["idempotency_key"])
        XCTAssertEqual(snapshot["boards"]["main"]["tasks"].object.count, 3, "未确认请求的重试不能创建第二条任务")
        try await writer.createTask(title: "超时后的安全重试", body: "相同内容", assignee: "ops", parents: ["task-1"], priority: 2)
        snapshot = try await state(api)
        posts = snapshot["log"].array.filter { $0["method"].string == "POST" && $0["path"].string == kanban + "/tasks" }
        XCTAssertEqual(posts.count, 3)
        XCTAssertNotEqual(posts[1]["body"]["idempotency_key"], posts[2]["body"]["idempotency_key"], "确认成功后的新提交必须获得新键")
        XCTAssertEqual(snapshot["boards"]["main"]["tasks"].object.count, 4)
    }

    func testExplicitMutationBoardStaysPinnedWhenSelectionChanges() async throws {
        let api = try await api()
        let writer = BotWorkspace(api: api, profile: "writer")
        await writer.selectBoard("secondary")
        try await writer.patchTask("task-1", patch: ["status": "review"], board: "main")
        try await writer.linkTasks(parent: "task-1", child: "task-2", board: "main")
        let main = try await writer.taskDetail("task-1", board: "main")
        let secondary = try await writer.taskDetail("task-1", board: "secondary")
        XCTAssertEqual(main["task"]["status"].string, "review")
        XCTAssertEqual(secondary["task"]["status"].string, "todo")
        XCTAssertEqual(writer.selectedBoard, "secondary")
        XCTAssertTrue(tasks(writer).allSatisfy { $0.title.hasPrefix("secondary") })
        let snapshot = try await state(api)
        let mutations = snapshot["log"].array.filter { ["PATCH", "POST"].contains($0["method"].string) }
        XCTAssertTrue(mutations.allSatisfy { $0["board"].string == "main" })
        XCTAssertEqual(snapshot["current"].string, "main")
    }
}
