import SwiftUI
import UniformTypeIdentifiers
import OSLog
import HermesClient

// Presented from the current conversation; ownership is captured at presentation time.
enum WorkspaceSection: String, Identifiable, CaseIterable {
    case routines, board
    var id: String { rawValue }
    var label: String { self == .routines ? "定时任务" : "看板" }
}
struct WorkbenchView: View {
    @Bindable var store: ChatStore
    let bot: Bot
    @State private var workspace: BotWorkspace?
    @State private var section: WorkspaceSection
    @Environment(\.dismiss) private var dismiss
    init(store: ChatStore, bot: Bot, initial: WorkspaceSection) {
        self.store = store; self.bot = bot
        _section = State(initialValue: initial)
        if let api = store.transport {
            _workspace = State(initialValue: BotWorkspace(api: api, profile: bot.profile, isActive: { store.transport === api && store.phase == .connected && !store.demo }))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                BotAvatar(bot: bot, size: 32, data: store.conversations[bot.profile]?.avatar)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bot.name).font(.ui(size: 14, weight: .semibold))
                    Text(section == .routines ? "这个助手的定时安排" : "共享看板 · 多个助手协作执行").font(.ui(size: 11)).foregroundStyle(Color.muted)
                }
                Spacer()
                ChoiceTabs(selection: $section, options: WorkspaceSection.allCases.map { Choice($0, $0.label) }).frame(width: 200)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).padding(.leading, 12)
            }.padding(22)
            Divider()
            if let workspace {
                if store.phase != .connected { Label("连接恢复后可继续操作，已保存内容仍在远端。", systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.orange).padding(8) }
                Group {
                    if section == .routines { RoutinesPane(work: workspace, bot: bot) }
                    else { BoardPane(work: workspace, bots: store.bots, bot: bot) }
                }.disabled(store.phase != .connected)
                    .task(id: section) {
                        if section == .routines { await workspace.loadJobs() } else { await workspace.loadBoards() }
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .seconds(8)) } catch { break }
                            if section == .routines { await workspace.loadJobs() } else { await workspace.refreshBoard() }
                        }
                    }
            } else { ContentUnavailableView("连接 Hermes 后即可使用", systemImage: "network") }
        }.frame(width: 1000, height: 690).background(Color.canvas).appTheme()
    }
}

private struct RoutinesPane: View {
    @Bindable var work: BotWorkspace
    let bot: Bot
    @State private var selected: String?
    @State private var creating = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(work.jobs.count) 项安排").font(.ui(size: 12)).foregroundStyle(Color.muted)
                if work.loadingJobs { ProgressView().controlSize(.small) }
                Spacer()
                Button { Task { await work.loadJobs() } } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(work.loadingJobs)
                Button { creating = true } label: { Label("新建任务", systemImage: "plus") }.buttonStyle(FilledButton()).disabled(work.busy)
            }.padding(.horizontal, 22).padding(.vertical, 14)
            if let message = work.jobsError { WorkspaceNotice(text: message) }
            Divider()
            HSplitView {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(work.jobs) { job in
                            Button { selected = job.id } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: job.paused ? "pause.circle" : "clock").foregroundStyle(job.paused ? Color.muted : Color.accent).padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(job.name).font(.ui(size: 13, weight: .medium)).foregroundStyle(Color.ink).lineLimit(2)
                                        Text(job.schedule).font(.ui(size: 11)).foregroundStyle(Color.muted).lineLimit(2)
                                        Text(job.completed ? "已完成" : job.paused ? "已暂停" : job.nextRun.isEmpty ? "等待远端调度" : "下次 · \(job.nextRun)").font(.ui(size: 10)).foregroundStyle(Color.muted).lineLimit(2)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(selected == job.id ? Color.selectionFill : Color.soft, in: OpticalRoundedRectangle())
                            }.buttonStyle(ResponsiveButton())
                        }
                        if work.jobs.isEmpty && !work.loadingJobs { ContentUnavailableView("还没有定时任务", systemImage: "clock", description: Text("为 \(bot.name) 安排下一件事。")) }
                    }.padding(12)
                }.frame(minWidth: 280, idealWidth: 320, maxWidth: 370)
                Group {
                    if let job = work.jobs.first(where: { $0.id == selected }) {
                        RoutineDetail(work: work, job: job).id(job.id)
                    } else { ContentUnavailableView("让助手按时行动", systemImage: "calendar.badge.clock", description: Text("选择一项安排查看内容与运行记录，\n或新建一项定时任务。")) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $creating) { RoutineCreateView(work: work, bot: bot) }
    }
}
private struct RoutineDetail: View {
    @Bindable var work: BotWorkspace
    let job: ScheduledJob
    @State private var runs: [JSON] = []
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(job.name).font(.ui(size: 23, weight: .semibold))
                        Label(job.completed ? "已完成" : job.paused ? "已暂停" : "由远端 Hermes 定时执行", systemImage: job.paused ? "pause.circle" : "checkmark.circle").font(.ui(size: 11)).foregroundStyle(job.paused ? Color.muted : .green)
                    }
                    Spacer()
                    if !job.completed { Button(job.paused ? "继续执行" : "暂停") {
                        Task { do { try await work.setPaused(job, paused: !job.paused) } catch { self.error = error.localizedDescription } }
                    }.disabled(work.busy) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("执行时间", value: job.schedule)
                    if !job.nextRun.isEmpty { LabeledContent("下次执行", value: job.nextRun) }
                    if !job.lastRun.isEmpty { LabeledContent("上次执行", value: job.lastRun) }
                    if !job.lastStatus.isEmpty { LabeledContent("上次结果", value: job.lastStatus) }
                    if !job.raw["deliver"].scalarString.isEmpty { LabeledContent("结果送达", value: job.raw["deliver"].scalarString) }
                }.font(.ui(size: 11)).foregroundStyle(Color.muted)
                Divider()
                Text("任务内容").font(.ui(size: 12, weight: .semibold))
                Text(job.prompt).font(.ui(size: 13)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                HStack { Text("最近运行").font(.ui(size: 12, weight: .semibold)); Spacer(); Button("刷新") { Task { await loadRuns() } }.controlSize(.small) }
                if runs.isEmpty { Text("暂无运行记录").font(.ui(size: 12)).foregroundStyle(Color.muted) }
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(run["title"].string.isEmpty ? "任务运行" : run["title"].string).font(.ui(size: 12, weight: .medium))
                        Text(run["preview"].string).font(.ui(size: 11)).foregroundStyle(Color.muted).lineLimit(8).textSelection(.enabled)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.03), in: OpticalRoundedRectangle())
                }
                if let error { WorkspaceNotice(text: error) }
            }.padding(28)
        }.task { await loadRuns() }
    }
    func loadRuns() async { do { runs = try await work.jobRuns(job.id); error = nil } catch { self.error = error.localizedDescription } }
}
private struct RoutineCreateView: View {
    @Bindable var work: BotWorkspace
    let bot: Bot
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var prompt = ""
    @State private var frequency = "daily"
    @State private var hour = 9
    @State private var minute = 0
    @State private var weekday = 1
    @State private var interval = 30
    @State private var custom = ""
    @State private var deliver = "bot-chat"
    @State private var error: String?
    var schedule: String {
        switch frequency {
        case "daily": return "\(minute) \(hour) * * *"
        case "weekly": return "\(minute) \(hour) * * \(weekday)"
        case "interval": return "every \(interval)m"
        case "once": return "\(interval)m"
        default: return custom.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SheetHeading(title: "为 \(bot.name) 新建任务", subtitle: "安排保存在这个 Bot 的远端 Hermes 中。")
            TextField("任务名称", text: $name).textFieldStyle(BotsTextFieldStyle())
            Text("希望助手做什么").font(.ui(size: 12, weight: .medium))
            TextEditor(text: $prompt).font(.ui(size: 13)).frame(height: 110).padding(5).overlay(OpticalRoundedRectangle().stroke(Color.primary.opacity(0.12)))
            ChoicePicker(title: "执行频率", selection: $frequency, options: [Choice("daily", "每天"), Choice("weekly", "每周"), Choice("interval", "间隔执行"), Choice("once", "仅执行一次"), Choice("custom", "自定义")])
            if frequency == "daily" || frequency == "weekly" {
                HStack {
                    if frequency == "weekly" { ChoicePicker(title: "星期", selection: $weekday, options: (0..<7).map { Choice($0, ["周日","周一","周二","周三","周四","周五","周六"][$0]) }).frame(width: 140) }
                    ChoicePicker(title: "时", selection: $hour, options: (0..<24).map { Choice($0, String(format: "%02d 时", $0)) })
                    ChoicePicker(title: "分", selection: $minute, options: (0..<60).map { Choice($0, String(format: "%02d 分", $0)) })
                }
                Text("以上时刻使用远端 Hermes 配置的时区。").font(.ui(size: 10)).foregroundStyle(Color.muted)
            } else if frequency == "interval" || frequency == "once" {
                NumberAdjuster(title: frequency == "once" ? "分钟后执行一次" : "间隔分钟", value: $interval, range: 1...10080)
            } else { TextField("例如 0 9 * * 1-5 或 every 2h", text: $custom).textFieldStyle(BotsTextFieldStyle()) }
            ChoicePicker(title: "结果送达", selection: $deliver, options: [Choice("bot-chat", "当前 Bot Chat"), Choice("local", "仅保存运行结果")])
            if let error { WorkspaceNotice(text: error) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if work.busy { ProgressView().controlSize(.small) }
                Button("创建安排") { Task { do { try await work.createJob(name: name, prompt: prompt, schedule: schedule, deliver: deliver); dismiss() } catch { self.error = error.localizedDescription } } }
                    .buttonStyle(FilledButton()).disabled(work.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || schedule.isEmpty)
            }
        }.padding(28).frame(width: 520).disabled(work.busy)
            .interactiveDismissDisabled(work.busy).appTheme()
    }
}

private struct BoardTaskSelection: Identifiable {
    let task: BoardTask
    let board: String
    var id: String { board + ":" + task.id }
}
private struct BoardPane: View {
    @Bindable var work: BotWorkspace
    let bots: [Bot]
    let bot: Bot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onlyMine = false
    @State private var creatingTask = false
    @State private var creatingBoard = false
    @State private var selectedTask: BoardTaskSelection?
    @State private var error: String?
    @State private var dragScope = UUID().uuidString
    @State private var targetColumn: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ChoicePicker(title: "看板", selection: Binding(get: { work.selectedBoard }, set: { slug in Task { await work.selectBoard(slug) } }), options: work.boards.map { Choice($0.slug, $0.name) }).frame(width: 200).disabled(work.busy || work.loadingBoards || work.boards.isEmpty)
                Toggle("仅看 \(bot.name)", isOn: $onlyMine).toggleStyle(BotsToggleStyle()).font(.ui(size: 11))
                Spacer()
                if work.loadingBoard || work.loadingBoards || work.busy { ProgressView().controlSize(.small) }
                PopoverMenu {
                    Button("新建看板") { creatingBoard = true }
                    Button("刷新看板列表") { Task { await work.loadBoards() } }
                    Button("唤醒远端调度") { Task { do { try await work.dispatch() } catch { self.error = error.localizedDescription } } }.disabled(work.selectedBoard.isEmpty)
                } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }.fixedSize().disabled(work.busy || work.loadingBoards)
                Button { creatingTask = true } label: { Label("新建任务", systemImage: "plus") }.buttonStyle(FilledButton()).disabled(work.selectedBoard.isEmpty || work.busy || work.loadingBoards)
            }.padding(.horizontal, 22).padding(.vertical, 14)
            if let message = work.boardError { WorkspaceNotice(text: message) }
            if let message = work.warning { WorkspaceNotice(text: message) }
            if let error { HStack { WorkspaceNotice(text: error); Button { self.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(ResponsiveButton()).padding(.trailing, 20) } }
            HStack { Text("拖动卡片安排状态，或打开卡片编辑负责人和依赖。待执行任务由远端 Agent 调度。"); Spacer() }.font(.ui(size: 10)).foregroundStyle(Color.muted).padding(.horizontal, 22).padding(.bottom, 12)
            Divider()
            if work.boards.isEmpty && work.loadingBoards {
                ProgressView("正在读取共享看板…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if work.boards.isEmpty && !work.loadingBoard {
                ContentUnavailableView {
                    Label(work.boardError == nil ? "创建你的第一个看板" : "看板暂不可用", systemImage: "rectangle.split.3x1")
                } description: { Text(work.boardError == nil ? "把工作分配给助手，按依赖顺序执行。" : "确认远端 Hermes 已启用 Kanban 插件，再刷新。") }
                actions: { Button("新建看板") { creatingBoard = true }; Button("重试") { Task { await work.loadBoards() } } }
                Spacer()
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(work.columns) { column in boardColumn(column) }
                    }.padding(20)
                }.background(Color.rail.opacity(0.6)).id(work.selectedBoard).transition(.identity)
                    .animation(reduceMotion ? nil : BotMotion.spring, value: work.columns.map { $0.tasks.map(\.id) })
            }
        }
        .sheet(isPresented: $creatingTask) { BoardTaskEditor(work: work, bots: bots, initialAssignee: bot.profile) }
        .sheet(isPresented: $creatingBoard) { BoardCreateView(work: work) }
        .sheet(item: $selectedTask) { selection in BoardTaskDetail(work: work, bots: bots, task: selection.task, board: selection.board) }
    }
    func boardColumn(_ column: BoardColumn) -> some View {
        let board = work.selectedBoard
        let tasks = column.tasks.filter { !onlyMine || $0.assignee == bot.profile }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(statusColor(column.name)).frame(width: 7, height: 7)
                Text(BoardColumn.label(column.name)).font(.ui(size: 12, weight: .semibold))
                Spacer()
                Text("\(tasks.count)").font(.ui(size: 10, weight: .medium)).foregroundStyle(Color.muted)
            }.padding(.horizontal, 5).padding(.top, 6)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(tasks) { task in
                        BoardCard(task: task, bots: bots)
                            .contentShape(OpticalRoundedRectangle())
                            .hoverSurface().onTapGesture { if board == work.selectedBoard { selectedTask = BoardTaskSelection(task: task, board: board) } }
                            .onDrag {
                                Logger(subsystem: "local.hermes.remote", category: "BoardDrag").notice("Board drag began")
                                return NSItemProvider(object: "\(dragScope)|\(board)|\(task.id)" as NSString)
                            }
                            .focusable()
                            .onKeyPress(.return) { if board == work.selectedBoard { selectedTask = BoardTaskSelection(task: task, board: board) }; return .handled }
                            .onKeyPress(.space) { if board == work.selectedBoard { selectedTask = BoardTaskSelection(task: task, board: board) }; return .handled }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { if board == work.selectedBoard { selectedTask = BoardTaskSelection(task: task, board: board) } }
                            .help("点击查看详情，或拖到其他状态列")
                    }
                    if tasks.isEmpty { Text("暂无任务").font(.ui(size: 11)).foregroundStyle(Color.muted.opacity(0.6)).frame(maxWidth: .infinity).padding(.vertical, 35) }
                    Color.clear.frame(height: 60)
                }
            }.scrollIndicators(.hidden)
        }.padding(10).frame(width: 235).frame(maxHeight: .infinity).background(Color.canvas.opacity(0.75), in: OpticalRoundedRectangle())
            .overlay(OpticalRoundedRectangle().strokeBorder(targetColumn == column.name ? Color.accent.opacity(0.65) : .clear, lineWidth: 2))
            .animation(reduceMotion ? nil : BotMotion.quick, value: targetColumn)
            .contentShape(OpticalRoundedRectangle())
            .onDrop(of: [UTType.utf8PlainText.identifier, UTType.plainText.identifier], isTargeted: Binding(get: { targetColumn == column.name }, set: { targeted in
                if targeted && movableColumn(column.name) { targetColumn = column.name }
                else if targetColumn == column.name { targetColumn = nil }
            })) { providers in
                guard board == work.selectedBoard, !work.busy, movableColumn(column.name), let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
                Logger(subsystem: "local.hermes.remote", category: "BoardDrag").notice("Board drop received")
                _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                    guard let token = value as? String else { return }
                    Task { @MainActor in
                        let parts = token.components(separatedBy: "|")
                        guard board == work.selectedBoard, parts.count == 3, parts[0] == dragScope, parts[1] == board,
                              let task = work.columns.flatMap(\.tasks).first(where: { $0.id == parts[2] }), task.status != column.name else { return }
                        do { try await work.patchTask(task.id, patch: ["status": .string(column.name)], board: board) }
                        catch { self.error = error.localizedDescription }
                    }
                }
                return true
            }
    }
    func movableColumn(_ name: String) -> Bool { ["triage", "todo", "ready", "blocked", "scheduled", "review", "done"].contains(name) }

}
private struct BoardCard: View {
    @Environment(ChatStore.self) private var store
    let task: BoardTask
    let bots: [Bot]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(task.title).font(.ui(size: 13, weight: .medium)).foregroundStyle(Color.ink).multilineTextAlignment(.leading).lineLimit(4)
            if !task.summary.isEmpty { Text(task.summary).font(.ui(size: 11)).foregroundStyle(Color.muted).multilineTextAlignment(.leading).lineLimit(3) }
            HStack(spacing: 6) {
                if let bot = bots.first(where: { $0.profile == task.assignee }) { BotAvatar(bot: bot, size: 18, data: store.conversations[bot.profile]?.avatar) }
                Text(bots.first(where: { $0.profile == task.assignee })?.name ?? (task.assignee.isEmpty ? "待分配" : task.assignee)).lineLimit(1)
                Spacer()
                if task.priority > 0 { Image(systemName: "flag.fill").foregroundStyle(.orange); Text("\(task.priority)") }
            }.font(.ui(size: 10)).foregroundStyle(Color.muted)
            if let total = task.raw["progress"]["total"].number, total > 0 {
                ProgressView(value: task.raw["progress"]["done"].number ?? 0, total: total).tint(Color.accent)
            }
            if task.raw["link_counts"]["parents"].number ?? 0 > 0 { Label("有前置依赖", systemImage: "link").font(.ui(size: 9)).foregroundStyle(Color.muted) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.canvas, in: OpticalRoundedRectangle()).overlay(OpticalRoundedRectangle().stroke(Color.primary.opacity(0.075)))
    }
}
private struct BoardTaskEditor: View {
    @Bindable var work: BotWorkspace
    let bots: [Bot]
    let initialAssignee: String
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var bodyText = ""
    @State private var assignee = ""
    @State private var priority = 0
    @State private var triage = false
    @State private var parents: Set<String> = []
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeading(title: "新建看板任务", subtitle: "指定助手后，由 Hermes 按依赖与调度规则执行。")
            TextField("任务标题", text: $title).textFieldStyle(BotsTextFieldStyle())
            TextEditor(text: $bodyText).font(.ui(size: 13)).frame(height: 100).padding(5).overlay(OpticalRoundedRectangle().stroke(Color.primary.opacity(0.12)))
            HStack {
                AssigneePicker(bots: bots, selection: $assignee)
                ChoicePicker(title: "优先级", selection: $priority, options: [Choice(0, "普通"), Choice(1, "优先"), Choice(2, "高")] + ([0,1,2].contains(priority) ? [] : [Choice(priority, "自定义 \(priority)")]))
            }
            Toggle("先交给编排 Agent 分解任务", isOn: $triage).font(.ui(size: 12))
            Text(triage ? "使用远端配置的编排助手。" : assignee.isEmpty ? "未分配的任务将留在待办中。" : "创建后交给所选助手，未完成的依赖会阻止提前执行。") .font(.ui(size: 10)).foregroundStyle(Color.muted)
            Text("前置任务 · 可选").font(.ui(size: 11, weight: .medium)).foregroundStyle(Color.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(work.columns.flatMap(\.tasks).filter { $0.status != "archived" }) { task in
                        Toggle(task.title, isOn: Binding(get: { parents.contains(task.id) }, set: { if $0 { parents.insert(task.id) } else { parents.remove(task.id) } })).font(.ui(size: 11))
                    }
                    if work.columns.flatMap(\.tasks).isEmpty { Text("暂无可选前置任务").font(.caption).foregroundStyle(Color.muted) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 100)
            if let error { WorkspaceNotice(text: error) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Spacer()
                if work.busy { ProgressView().controlSize(.small) }
                Button("创建任务") {
                    Task { do { try await work.createTask(title: title, body: bodyText, assignee: assignee, parents: parents.sorted(), priority: priority, triage: triage); dismiss() } catch { self.error = error.localizedDescription } }
                }.buttonStyle(FilledButton()).disabled(work.busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(28).frame(width: 540).disabled(work.busy).interactiveDismissDisabled(work.busy).appTheme()
            .onAppear { assignee = initialAssignee }
    }
}
private struct BoardTaskDetail: View {
    @Bindable var work: BotWorkspace
    let bots: [Bot]
    let task: BoardTask
    let board: String
    @Environment(\.dismiss) private var dismiss
    @State private var detail: JSON = .null
    @State private var title = ""
    @State private var bodyText = ""
    @State private var assignee = ""
    @State private var status = ""
    @State private var priority = 0
    @State private var comment = ""
    @State private var parent = ""
    @State private var log: String?
    @State private var error: String?
    @State private var loading = false
    @State private var hydrated = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("任务详情").font(.ui(size: 20, weight: .semibold)); Spacer(); if loading { ProgressView().controlSize(.small) }; Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Group {
                    TextField("标题", text: $title).textFieldStyle(BotsTextFieldStyle())
                    TextEditor(text: $bodyText).font(.ui(size: 13)).frame(height: 110).padding(5).overlay(OpticalRoundedRectangle().stroke(Color.primary.opacity(0.12)))
                    HStack {
                        AssigneePicker(bots: bots, selection: $assignee)
                        ChoicePicker(title: "状态", selection: $status, options: Array(Set(["triage", "todo", "scheduled", "ready", "blocked", "review", "done", status])).sorted().map { Choice($0, BoardColumn.label($0)) })
                        ChoicePicker(title: "优先级", selection: $priority, options: [Choice(0, "普通"), Choice(1, "优先"), Choice(2, "高")] + ([0,1,2].contains(priority) ? [] : [Choice(priority, "自定义 \(priority)")]))
                    }
                    Text("移到“待执行”会交给远端调度；“执行中”由 Agent 自动更新。") .font(.ui(size: 10)).foregroundStyle(Color.muted)
                    HStack { Spacer(); Button("保存修改") { save() }.buttonStyle(FilledButton()).disabled(work.busy || !hydrated || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                    }.disabled(work.busy || loading || !hydrated)
                    Divider()
                    Text("执行结果与依赖").font(.ui(size: 12, weight: .semibold))
                    if !detail["task"]["result"].string.isEmpty { Text(detail["task"]["result"].string).font(.ui(size: 12)).textSelection(.enabled) }
                    ForEach(Array(detail["link_tasks"].array.enumerated()), id: \.offset) { _, link in
                        Label("\(detail["links"]["parents"].array.contains(.string(link["id"].scalarString)) ? "前置" : "后续") · \(link["title"].string) · \(BoardColumn.label(link["status"].string))", systemImage: "link").font(.ui(size: 11)).foregroundStyle(Color.muted)
                    }
                    HStack {
                        ChoicePicker(title: "添加前置任务", selection: $parent, options: [Choice("", "选择任务…")] + work.columns.flatMap(\.tasks).filter { $0.id != task.id }.map { Choice($0.id, $0.title) })
                        Button("添加依赖") { Task { do { try await work.linkTasks(parent: parent, child: task.id, board: board); parent = ""; await reload() } catch { self.error = error.localizedDescription } } }.disabled(parent.isEmpty || work.busy)
                    }
                    Divider()
                    HStack { Text("运行记录").font(.ui(size: 12, weight: .semibold)); Spacer(); Button("刷新") { Task { await reload() } }.disabled(loading); Button("查看执行日志") { Task { do { let value = try await work.taskLog(task.id, board: board); log = value["exists"].bool ? value["content"].string : "暂无执行日志" } catch { self.error = error.localizedDescription } } } }
                    ForEach(Array(detail["runs"].array.enumerated()), id: \.offset) { _, run in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(run["profile"].string) · \(run["status"].string)").font(.ui(size: 11, weight: .medium))
                            Text(run["summary"].string.isEmpty ? run["error"].string : run["summary"].string).font(.ui(size: 11)).foregroundStyle(Color.muted).textSelection(.enabled)
                        }
                    }
                    if let log { ScrollView(.horizontal) { Text(log).font(.ui(size: 10, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false) }.frame(maxHeight: 170).padding(12).background(Color.soft, in: OpticalRoundedRectangle()) }
                    Divider()
                    Text("备注与协作").font(.ui(size: 12, weight: .semibold))
                    ForEach(Array(detail["comments"].array.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 5) { Text(row["author"].string).font(.ui(size: 10)).foregroundStyle(Color.muted); Text(row["body"].string).font(.ui(size: 12)).textSelection(.enabled) }
                    }
                    HStack {
                        TextField("添加说明或反馈", text: $comment).textFieldStyle(BotsTextFieldStyle())
                        Button("添加") { Task { do { try await work.addComment(task.id, board: board, text: comment); comment = ""; await reload() } catch { self.error = error.localizedDescription } } }.disabled(work.busy || comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let error { WorkspaceNotice(text: error) }
                }
            }
        }.padding(26).frame(width: 680, height: 650).interactiveDismissDisabled(work.busy).appTheme()
            .task {
                title = task.title; bodyText = task.body; assignee = task.assignee; status = task.status; priority = task.priority
                await reload(hydrate: true)
            }
    }
    func reload(hydrate: Bool = false) async {
        loading = true; defer { loading = false }
        do {
            detail = try await work.taskDetail(task.id, board: board); error = nil
            if hydrate { let current = BoardTask(detail["task"]); title = current.title; bodyText = current.body; assignee = current.assignee; status = current.status; priority = current.priority; hydrated = true }
        } catch { self.error = error.localizedDescription }
    }
    func save() {
        var patch: [String: JSON] = ["title": .string(title), "body": .string(bodyText), "priority": .number(Double(priority))]
        if assignee != detail["task"]["assignee"].string { patch["assignee"] = .string(assignee) }
        if status != detail["task"]["status"].string { patch["status"] = .string(status) }
        Task { do { try await work.patchTask(task.id, patch: patch, board: board); await reload(hydrate: true) } catch { self.error = error.localizedDescription } }
    }
}
private struct BoardCreateView: View {
    @Bindable var work: BotWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var slug = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeading(title: "新建共享看板", subtitle: "可以为不同项目分别安排助手与任务。")
            TextField("看板名称", text: $name).textFieldStyle(BotsTextFieldStyle())
            TextField("标识，例如 product-launch", text: $slug).textFieldStyle(BotsTextFieldStyle())
            if let error { WorkspaceNotice(text: error) }
            HStack { Button("取消") { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("创建") { Task { do { try await work.createBoard(slug: slug, name: name); dismiss() } catch { self.error = error.localizedDescription } } }.buttonStyle(FilledButton()).disabled(work.busy || slug.isEmpty || name.isEmpty) }
        }.padding(28).frame(width: 430).disabled(work.busy).interactiveDismissDisabled(work.busy).appTheme()
    }
}
private struct AssigneePicker: View {
    let bots: [Bot]
    @Binding var selection: String
    var body: some View {
        ChoicePicker(title: "负责人", selection: $selection, options: [Choice("", "未分配")] + bots.map { Choice($0.profile, $0.name) } + (!selection.isEmpty && !bots.contains(where: { $0.profile == selection }) ? [Choice(selection, selection)] : []))
    }
}
private struct SheetHeading: View {
    let title: String
    let subtitle: String
    var body: some View { VStack(alignment: .leading, spacing: 8) { Text(title).font(.ui(size: 21, weight: .semibold)); Text(subtitle).font(.ui(size: 11)).foregroundStyle(Color.muted) } }
}
private struct WorkspaceNotice: View {
    let text: String
    var body: some View { Label(text, systemImage: "exclamationmark.circle").font(.ui(size: 11)).foregroundStyle(.orange).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 10) }
}
private func statusColor(_ name: String) -> Color {
    switch name { case "running": return .green; case "ready": return .blue; case "blocked": return .red; case "review": return .orange; case "scheduled": return .purple; default: return .muted }
}
