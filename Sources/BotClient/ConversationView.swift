import SwiftUI
import AppKit
import UniformTypeIdentifiers
import HermesClient

struct ConversationView: View {
    @Bindable var store: ChatStore
    @Bindable var chat: BotConversation
    let bot: Bot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var editorFocused = false
    @State private var editorFocusRequest = 0
    @State private var editingAvatar = false
    @State private var modelPickerPresented = false
    @State private var workspaceSection: WorkspaceSection?
    @State private var nearBottom = true
    @State private var newMessages = false
    @State private var lastMessageID: String?
    @State private var dropTargeted = false
    @State private var preparingDrop = false
    @State private var downloadError: String?
    @State private var downloading = false
    @State private var editorHeight: CGFloat = 42
    @State private var initiallyPositioned = false
    @State private var userScrolling = false
    @State private var viewport = TranscriptViewport()
    @State private var followTask: Task<Void, Never>?
    @State private var scrollTaskID: UUID?
    @State private var historyScrollID: UUID?
    @State private var commandIndex = 0
    @State private var dismissedCommandDraft: String?
    init(store: ChatStore, chat: BotConversation, bot: Bot) {
        self.store = store; self.chat = chat; self.bot = bot
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            if store.demo {
                HStack(spacing: 7) { Image(systemName: "eye"); Text("界面预览 · 这里显示的是示例消息") }.font(.ui(size: 11)).foregroundStyle(Color.muted).frame(maxWidth: .infinity).padding(.vertical, 9).background(Color.accent.opacity(0.04))
            } else if store.phase != .connected || store.banner != nil {
                HStack(spacing: 8) {
                    Image(systemName: store.phase == .connected ? "info.circle" : "wifi.exclamationmark")
                    Text(store.phase == .signedOut ? "登录已过期，聊天与草稿已保留" : store.banner ?? "连接暂时中断，已保留聊天与草稿，恢复后自动同步").lineLimit(2)
                    Spacer()
                    if store.phase != .connected { Button(store.phase == .signedOut ? "重新登录" : "重连") { store.reconnectNow() }.buttonStyle(ResponsiveButton()).fontWeight(.semibold) }
                    else { Button { store.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(ResponsiveButton()).accessibilityLabel("关闭提示") }
                }.font(.ui(size: 11)).foregroundStyle(Color.orange).padding(.horizontal, 24).padding(.vertical, 10).background(Color.orange.opacity(0.055))
            }
            messageList
            if !chat.cards.isEmpty {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(chat.cards) { card in PendingCardView(card: card) { result in try await store.answer(card, chat: chat, result: result) }.disabled(store.phase != .connected || !chat.canSubmit).transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)) }
                    }.padding(.horizontal, 30).padding(.vertical, 8)
                }.frame(maxHeight: 280).transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
            if let error = chat.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("重试") { Task { await store.open(profile: chat.profile, force: true) } }.buttonStyle(ResponsiveButton()).fontWeight(.semibold)
                    Button { chat.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(ResponsiveButton())
                }.font(.ui(size: 11)).foregroundStyle(Color.orange).padding(.horizontal, 30).padding(.vertical, 10)
            }
            composer
        }
        .background(Color.canvas)
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $dropTargeted, perform: acceptDrop)
        .overlay { if dropTargeted { OpticalRoundedRectangle().stroke(Color.accent, style: StrokeStyle(lineWidth: 2, dash: [8])).padding(8).allowsHitTesting(false).transition(.opacity) } }
        .animation(reduceMotion ? nil : BotMotion.quick, value: dropTargeted)
        .sheet(isPresented: $editingAvatar) { AvatarPickerView(bot: bot, serverData: chat.avatar) }
        .sheet(item: $workspaceSection) { section in WorkbenchView(store: store, bot: bot, initial: section) }
        .overlay {
            if let downloadError {
                InPageDialog("文件未能下载", message: downloadError) {
                    Button("知道了") { self.downloadError = nil }.buttonStyle(FilledButton()).keyboardShortcut(.cancelAction)
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in openLink(url) })
        .onChange(of: chat.draft) { _, _ in
            commandIndex = 0
            store.cacheCurrentState()
            if commandMenuVisible && chat.commands.isEmpty { Task { await store.loadCommands(for: chat) } }
        }
        .task(id: chat.runtimeID) { if !chat.runtimeID.isEmpty { await store.loadCommands(for: chat) } }
    }
    var header: some View {
        HStack(spacing: 12) {
            Button { editingAvatar = true } label: { BotAvatar(bot: bot, size: 36, data: chat.avatar, busy: chat.running) }
                .buttonStyle(ResponsiveButton(round: true)).help("更换头像").accessibilityLabel("更换\(bot.name)的头像")
            VStack(alignment: .leading, spacing: 4) {
                Text(bot.name).font(.ui(size: 16, weight: .semibold)).foregroundStyle(Color.ink)
                Text(chat.cards.isEmpty ? chat.running ? chat.status : chat.synchronizing ? "正在同步最新消息" : chat.displayingCached ? "已显示本机缓存" : bot.subtitle.isEmpty ? "随时继续对话" : bot.subtitle : "等待你确认")
                    .contentTransition(.opacity).animation(reduceMotion ? nil : BotMotion.quick, value: chat.status)
                    .font(.ui(size: 10)).foregroundStyle(chat.cards.isEmpty ? Color.muted : .orange).lineLimit(1)
            }
            Spacer()
            if downloading { ProgressView().controlSize(.small) }
            Button { workspaceSection = .routines } label: { Image(systemName: "calendar.badge.clock").font(.ui(size: 15)).frame(width: 30, height: 30) }.buttonStyle(ResponsiveButton(round: true)).help("这个 Bot 的定时任务").accessibilityLabel("定时任务").disabled(store.demo || store.phase != .connected)
            Button { workspaceSection = .board } label: { Image(systemName: "rectangle.split.3x1").font(.ui(size: 15)).frame(width: 30, height: 30) }.buttonStyle(ResponsiveButton(round: true)).help("共享任务看板").accessibilityLabel("任务看板").disabled(store.demo || store.phase != .connected)
            PopoverMenu {
                Button("更换头像", systemImage: "face.smiling") { editingAvatar = true }
                Button("刷新消息", systemImage: "arrow.clockwise") { Task { await store.open(profile: chat.profile, force: true) } }.disabled(store.demo)
                Button("整理上下文", systemImage: "arrow.down.right.and.arrow.up.left") { Task { await store.compact(chat) } }.disabled(store.demo || chat.running)
                Divider()
                Text("Profile · \(bot.profile)")
            } label: { Image(systemName: "ellipsis").font(.ui(size: 17)).frame(width: 28, height: 28) }.fixedSize().help("更多操作")
        }.padding(.horizontal, 26).padding(.top, 25).padding(.bottom, 20)
            .foregroundStyle(Color.muted)
            .overlay(alignment: .bottom) { Color.hairline.opacity(0.6).frame(height: 1) }
    }
    var messageList: some View {
        ScrollViewReader { proxy in
            // One stable root per message; List owns row reuse and measured row heights.
            // Avoid LazyVStack's estimated off-screen heights and phase-dependent anchors.
            List {
                if chat.hasOlder {
                    HStack {
                        Spacer()
                        Button {
                            nearBottom = false; viewport.followsBottom = false
                            followTask?.cancel(); followTask = nil; scrollTaskID = nil
                            let readingAnchor = transcriptRows.first?.id
                            let request = UUID(); historyScrollID = request
                            let entry = chat.entryRevision, outgoing = chat.outgoingRevision
                            Task {
                                defer { if historyScrollID == request { historyScrollID = nil } }
                                await store.loadOlder(chat)
                                await Task.yield()
                                guard !Task.isCancelled, historyScrollID == request, chat.entryRevision == entry,
                                      chat.outgoingRevision == outgoing, store.selected == chat.profile, let readingAnchor else { return }
                                var transaction = Transaction(); transaction.disablesAnimations = true
                                withTransaction(transaction) { proxy.scrollTo(readingAnchor, anchor: .top) }
                            }
                        } label: { if chat.loading { ProgressView().controlSize(.small) } else { Text("查看更早的消息") } }
                            .buttonStyle(ResponsiveButton()).font(.ui(size: 11)).foregroundStyle(Color.muted).disabled(chat.loading || store.phase != .connected)
                        Spacer()
                    }.modifier(TranscriptRowSurface(viewport: viewport)).id("older")
                }
                if chat.messages.isEmpty && !chat.loading {
                    VStack(spacing: 13) {
                        BotAvatar(bot: bot, size: 64, data: chat.avatar)
                        Text("与 \(bot.name) 的对话").font(.ui(size: 17, weight: .medium))
                        Text("从这里接续你们的 Bot Chat。").font(.ui(size: 12)).foregroundStyle(Color.muted)
                    }.frame(maxWidth: .infinity).padding(.vertical, 80).modifier(TranscriptRowSurface(viewport: viewport)).id("empty")
                }
                ForEach(transcriptRows) { row in
                    ConversationMessageRow(message: row.message, bot: bot, showTime: row.showTime, chat: chat, store: store,
                        download: { path in saveFile(path: path) }, preview: { path in previewFile(path) })
                        .equatable().modifier(TranscriptRowSurface(viewport: viewport)).id(row.id).transition(.identity)
                }
                if chat.loading && chat.messages.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(60).modifier(TranscriptRowSurface(viewport: viewport)).id("loading")
                }
                if chat.running && chat.activity.visible && !chat.hasStreamingReply {
                    ConversationActivityView(activity: chat.activity).modifier(TranscriptRowSurface(viewport: viewport)).id("activity")
                }
                Color.clear.frame(height: 1).modifier(TranscriptRowSurface(viewport: viewport, bottom: 17)).id("bottom")
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 1)
            .scrollContentBackground(.hidden).background(Color.canvas)
            .contentMargins(.vertical, 0, for: .scrollContent)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .animation(nil, value: chat.revision)
            .onChange(of: viewport.userScrolling) { _, scrolling in
                userScrolling = scrolling
                if scrolling {
                    historyScrollID = nil
                    followTask?.cancel(); followTask = nil; scrollTaskID = nil
                    nearBottom = viewport.atBottom
                }
            }
            .onChange(of: viewport.atBottom) { _, bottom in
                if bottom { newMessages = false }
            }
            .onChange(of: viewport.followsBottom) { _, follows in nearBottom = follows }
            .onChange(of: chat.outgoingRevision) { _, _ in
                historyScrollID = nil
                nearBottom = true; viewport.followsBottom = true; newMessages = false; chat.scrollAnchor = "bottom"
                followTask?.cancel(); followTask = nil; scrollTaskID = nil
                // Sending is an explicit navigation intent, even when reading older messages.
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { if !viewport.scrollToBottom() { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onAppear { viewport.activate(); positionInitially(proxy) }
            .onChange(of: chat.entryRevision) { _, _ in
                historyScrollID = nil
                initiallyPositioned = false
                positionInitially(proxy)
            }
            .onChange(of: chat.loading) { _, loading in if !loading && !initiallyPositioned { positionInitially(proxy) } }
            .onChange(of: chat.revision) { _, _ in
                let newest = chat.messages.last(where: { $0.role != "tool" })?.id
                let appended = lastMessageID != nil && newest != lastMessageID
                lastMessageID = newest
                if !initiallyPositioned && !chat.loading { positionInitially(proxy) }
                else if nearBottom && viewport.followsBottom && !userScrolling {
                    guard followTask == nil else { return }
                    let id = UUID(); scrollTaskID = id
                    followTask = Task { @MainActor in
                        defer { if scrollTaskID == id { followTask = nil; scrollTaskID = nil } }
                        try? await Task.sleep(for: .milliseconds(60))
                        guard !Task.isCancelled, scrollTaskID == id, nearBottom, viewport.followsBottom, !userScrolling, !chat.loading else { return }
                        if !viewport.scrollToBottom() { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                } else if appended && (userScrolling || !nearBottom) { newMessages = true }
            }
            .onDisappear { followTask?.cancel(); followTask = nil; scrollTaskID = nil; historyScrollID = nil; viewport.stop(); store.cacheCurrentState() }
            .overlay(alignment: .bottom) {
                if newMessages {
                    Button { nearBottom = true; viewport.followsBottom = true; chat.scrollAnchor = "bottom"; if !viewport.scrollToBottom() { proxy.scrollTo("bottom", anchor: .bottom) }; newMessages = false } label: { Label("新消息", systemImage: "arrow.down").font(.ui(size: 11, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 8) }
                        .buttonStyle(ResponsiveButton()).background(.regularMaterial, in: OpticalRoundedRectangle()).overlay(OpticalRoundedRectangle().stroke(.primary.opacity(0.08))).shadow(color: .black.opacity(0.06), radius: 8, y: 3).padding(.bottom, 12).transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }
    var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let notice = chat.modelNotice {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "info.circle")
                    Text(notice).frame(maxWidth: .infinity, alignment: .leading)
                    Button { chat.modelNotice = nil } label: { Image(systemName: "xmark") }.buttonStyle(ResponsiveButton()).accessibilityLabel("关闭模型提示")
                }.font(.ui(size: 10)).foregroundStyle(Color.muted).padding(.horizontal, 5)
            }
            commandResults
            if commandMenuVisible { commandMenu }
            VStack(alignment: .leading, spacing: 3) {
                if !chat.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(chat.attachments) { item in ComposerAttachmentView(item: item) { store.removeAttachment(item.id, from: chat) }.disabled(chat.uploading) }
                        }.padding(.vertical, 4)
                    }.padding(.horizontal, 5).padding(.top, 7)
                }
                ComposerEditor(text: $chat.draft, height: $editorHeight, placeholder: "发消息给 \(bot.name)…", onSend: submit, onFiles: { urls, temporary in
                        Task {
                            await store.stage(urls, for: chat)?.value
                            if temporary { for url in urls { try? FileManager.default.removeItem(at: url) } }
                        }
                    }, onFocusChange: { editorFocused = $0 }, onCommandKey: handleCommandKey, focusRequest: editorFocusRequest)
                    .frame(height: editorHeight).disabled(store.demo || chat.uploading || chat.executingCommand)
                    .padding(.horizontal, 5)
                HStack(spacing: 8) {
                    PopoverMenu {
                        Button("添加文件…", systemImage: "doc.badge.plus") { chooseFiles() }
                        Button("添加图片…", systemImage: "photo") { chooseFiles(imagesOnly: true) }
                    } label: { Image(systemName: "paperclip").font(.ui(size: 17)).frame(width: 28, height: 30).foregroundStyle(Color.muted) }
                        .fixedSize().disabled(store.demo || chat.uploading || chat.executingCommand || preparingDrop || chat.attachments.count >= 10).help("添加图片或文件，也可直接拖入或粘贴").accessibilityLabel("添加文件或图片")
                    Button {
                        if !chat.draft.hasPrefix("/") { chat.draft = "/" }
                        dismissedCommandDraft = nil
                        editorFocusRequest += 1
                    } label: { Image(systemName: "slash.circle").font(.ui(size: 17)).frame(width: 28, height: 30).foregroundStyle(Color.muted) }
                        .buttonStyle(ResponsiveButton(round: true)).help("输入命令").accessibilityLabel("展开命令菜单")
                        .disabled(store.demo || chat.uploading || chat.executingCommand)
                Button { modelPickerPresented = true } label: {
                    HStack(spacing: 6) {
                        if chat.switchingModel { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "cpu").font(.ui(size: 11)) }
                        Text(chat.modelLabel).font(.ui(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.down").font(.ui(size: 8, weight: .semibold))
                    }.padding(.horizontal, 10).padding(.vertical, 7).background(Color.canvas.opacity(0.65), in: OpticalRoundedRectangle())
                }.buttonStyle(ResponsiveButton(round: true)).disabled(store.demo || store.phase != .connected || !chat.canSubmit || chat.switchingModel)
                    .help(chat.running ? "查看模型；回复完成后可切换" : "选择当前 Bot Chat 使用的模型")
                    .accessibilityLabel("当前模型：\(chat.modelLabel)，选择模型")
                    .popover(isPresented: $modelPickerPresented, arrowEdge: .bottom) { ChatModelPicker(store: store, chat: chat) }
                    Spacer(minLength: 0)
                    if !chat.attachments.isEmpty { Text("\(chat.attachments.count)/10").font(.ui(size: 11)).foregroundStyle(Color.muted).help("最多 10 个附件，单个 25 MB") }
                    if chat.uploading || preparingDrop || chat.executingCommand { ProgressView().controlSize(.small).frame(width: 36, height: 36) }
                    else if chat.running && chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && chat.attachments.isEmpty {
                        Button { Task { await store.stop(chat) } } label: { Image(systemName: "stop.fill").font(.ui(size: 12)).foregroundStyle(Color.onOutgoing).frame(width: 36, height: 36).background(Color.outgoing, in: OpticalRoundedRectangle()) }
                            .buttonStyle(ResponsiveButton(round: true)).accessibilityLabel("停止回复").help("停止回复 ⌘.")
                    } else {
                        Button(action: submit) { Image(systemName: "arrow.up").font(.ui(size: 16, weight: .semibold)).foregroundStyle(canSend ? Color.onOutgoing : Color.muted).frame(width: 36, height: 36).background(canSend ? Color.outgoing : Color.hairline, in: OpticalRoundedRectangle()) }
                            .buttonStyle(ResponsiveButton(round: true)).disabled(!canSend).help("发送消息").accessibilityLabel("发送消息")
                    }
                }
            }.padding(.horizontal, 13).padding(.top, 5).padding(.bottom, 12)
                .background(Color.inputSurface, in: OpticalRoundedRectangle())
                .overlay(OpticalRoundedRectangle().strokeBorder(editorFocused ? Color.accent.opacity(0.65) : Color.hairline.opacity(0.7), lineWidth: editorFocused ? 1.5 : 1))
                .animation(reduceMotion ? nil : BotMotion.quick, value: editorFocused)
                .animation(reduceMotion ? nil : BotMotion.quick, value: canSend)
            HStack {
                Text(store.demo ? "示例仅用于预览，连接后即可发送消息" : preparingDrop ? "正在准备附件…" : chat.uploading ? "正在上传附件…" : chat.executingCommand ? "正在执行命令…" : "↵ 发送   ⇧↵ 换行   / 命令")
                Spacer()
                if !store.demo { Text("Bot Chat · \(bot.profile)") }
            }.font(.ui(size: 10)).foregroundStyle(Color.muted).padding(.horizontal, 7)
        }.animation(reduceMotion ? nil : BotMotion.spring, value: chat.attachments.map(\.id))
            .padding(.horizontal, 30).padding(.top, 9).padding(.bottom, 18).frame(maxWidth: 900).frame(maxWidth: .infinity)
    }
    var canSend: Bool { store.selected == chat.profile && !store.demo && store.phase == .connected && !chat.uploading && !chat.switchingModel && !preparingDrop && chat.canSubmit && (!chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.attachments.isEmpty) }
    func positionInitially(_ proxy: ScrollViewProxy) {
        guard !initiallyPositioned, !chat.loading, !chat.messages.isEmpty else { return }
        initiallyPositioned = true
        lastMessageID = chat.messages.last(where: { $0.role != "tool" })?.id
        nearBottom = true; viewport.followsBottom = true; newMessages = false
        chat.scrollAnchor = "bottom"
        followTask?.cancel()
        let id = UUID(); scrollTaskID = id
        // Let newly hydrated rows enter layout; later size changes stay bottom-anchored
        // until the user deliberately scrolls up. Never restore a cached historical row.
        followTask = Task { @MainActor in
            defer { if scrollTaskID == id { followTask = nil; scrollTaskID = nil } }
            await Task.yield()
            guard !Task.isCancelled, scrollTaskID == id, nearBottom, !userScrolling else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { if !viewport.scrollToBottom() { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }
    func submit() {
        guard canSend else { return }
        let command = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if command == "/model" { modelPickerPresented = true; chat.draft = ""; return }
        dismissedCommandDraft = chat.draft
        Task { await store.send(chat) }
    }
    private var transcriptRows: [TranscriptRow] {
        let messages = chat.messages.filter { $0.role != "tool" }
        return messages.enumerated().map { index, message in
            TranscriptRow(message: message, showTime: index == 0 || message.timestamp.timeIntervalSince(messages[index - 1].timestamp) > 900)
        }
    }
    func timeLabel(_ date: Date) -> String {
        guard date.timeIntervalSince1970 > 0 else { return "历史消息" }
        return date.formatted(.dateTime.month().day().hour().minute())
    }
    func chooseFiles(imagesOnly: Bool = false) {
        let panel = NSOpenPanel(); panel.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.title = imagesOnly ? "添加图片" : "添加文件"; panel.prompt = "添加"; panel.message = "一次最多 10 个附件，单个附件不超过 25 MB。"
        if imagesOnly { panel.allowedContentTypes = [.image] }
        panel.begin { result in if result == .OK { store.stage(panel.urls, for: chat) } }
    }
    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !store.demo, !chat.uploading, !chat.executingCommand, !preparingDrop else { return false }
        let supported = providers.filter { provider in
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
            provider.registeredTypeIdentifiers.contains { UTType($0)?.conforms(to: .image) == true }
        }
        guard !supported.isEmpty else { return false }
        preparingDrop = true
        Task {
            defer { preparingDrop = false }
            var urls: [URL] = [], temporaryFiles: [URL] = []
            defer { for url in temporaryFiles { try? FileManager.default.removeItem(at: url) } }
            for provider in supported {
                do { let item = try await droppedURL(provider); urls.append(item.url); if item.temporary { temporaryFiles.append(item.url) } }
                catch { chat.error = error.localizedDescription }
            }
            // Stage the whole drop together; separate callbacks must not race the upload lock.
            if !urls.isEmpty { await store.stage(urls, for: chat)?.value }
        }
        return true
    }
    func droppedURL(_ provider: NSItemProvider) async throws -> (url: URL, temporary: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    if let url { continuation.resume(returning: (url, false)) }
                    else { continuation.resume(throwing: error ?? ClientError.message("未能读取拖入的文件，请使用添加附件。")) }
                }
            } else if let identifier = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, error in
                    guard let data, data.count <= 25 * 1024 * 1024 else {
                        continuation.resume(throwing: error ?? ClientError.message("图片未能读取，或已超过 25 MB。")); return
                    }
                    let ext = UTType(identifier)?.preferredFilenameExtension ?? "png"
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("图片-\(UUID().uuidString).\(ext)")
                    do { try data.write(to: url, options: .atomic); continuation.resume(returning: (url, true)) }
                    catch { continuation.resume(throwing: error) }
                }
            } else { continuation.resume(throwing: ClientError.message("不支持此附件类型")) }
        }
    }
    func openLink(_ url: URL) -> OpenURLAction.Result {
        if url.isFileURL || url.scheme == "sandbox" { saveFile(path: url.path); return .handled }
        if ["http", "https", "mailto"].contains(url.scheme ?? "") { return .systemAction }
        return .discarded
    }
    func saveFile(path: String) {
        guard !store.demo else { return }
        let panel = NSSavePanel(); panel.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua); panel.nameFieldStringValue = URL(fileURLWithPath: path).lastPathComponent
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            downloading = true
            Task {
                defer { downloading = false }
                do { try await store.download(path: path, profile: chat.profile, to: url); NSWorkspace.shared.activateFileViewerSelecting([url]) }
                catch { downloadError = store.readable(error) }
            }
        }
    }
    func previewFile(_ path: String) {
        guard !store.demo else { return }
        downloading = true
        Task {
            defer { downloading = false }
            do {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BotClient-Preview/\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
                try await store.download(path: path, profile: chat.profile, to: url)
                NSWorkspace.shared.open(url)
            } catch { downloadError = store.readable(error) }
        }
    }
}

private struct TranscriptRow: Identifiable {
    let message: ChatMessage
    let showTime: Bool
    var id: String { message.id }
}

/// Suppress platform row chrome; all visible content keeps MOS's custom drawing.
private struct TranscriptRowSurface: ViewModifier {
    let viewport: TranscriptViewport
    var bottom: CGFloat = 18
    func body(content: Content) -> some View {
        content.frame(maxWidth: 852, alignment: .leading).frame(maxWidth: .infinity)
            .padding(.horizontal, 34).padding(.top, 9).padding(.bottom, bottom)
            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
            .selectionDisabled()
            .background(TranscriptViewportProbe(viewport: viewport).allowsHitTesting(false))
    }
}

extension ConversationView {
    var commandMenuVisible: Bool {
        editorFocused && chat.draft.hasPrefix("/") && !chat.draft.contains(where: { $0.isWhitespace }) && dismissedCommandDraft != chat.draft
    }
    var matchingCommands: [SlashCommand] {
        let query = chat.draft.lowercased()
        let commands = chat.commands.isEmpty ? SlashCommand.local : chat.commands
        return commands.filter { query == "/" || $0.name.lowercased().contains(String(query.dropFirst())) || $0.description.localizedCaseInsensitiveContains(String(query.dropFirst())) }
    }
    var commandMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("命令").font(.ui(size: 12, weight: .semibold))
                if chat.loadingCommands { ProgressView().controlSize(.mini) }
                Spacer()
                Text("↑↓ 选择   ↵ / Tab 填入   Esc 关闭").font(.ui(size: 10)).foregroundStyle(Color.muted)
            }.padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(matchingCommands.enumerated()), id: \.element.id) { index, command in
                            Button { chooseCommand(command) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: command.kind == "skill" ? "sparkles" : "slash.circle").font(.ui(size: 15)).foregroundStyle(Color.accent)
                                    Text(command.name).font(.ui(size: 13, weight: .semibold, design: .monospaced)).frame(minWidth: 100, alignment: .leading)
                                    Text(command.description).font(.ui(size: 12)).foregroundStyle(Color.muted).lineLimit(1)
                                    Spacer(minLength: 4)
                                    if index == commandIndex { Image(systemName: "return").font(.ui(size: 11)).foregroundStyle(Color.accent) }
                                }.padding(.horizontal, 10).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(index == commandIndex ? Color.selectionFill : Color.clear, in: OpticalRoundedRectangle())
                            }.buttonStyle(ResponsiveButton()).id(command.id)
                        }
                        if matchingCommands.isEmpty { Text("没有匹配的命令").font(.ui(size: 12)).foregroundStyle(Color.muted).padding(16) }
                    }.padding(6)
                }.frame(maxHeight: 210)
                    .onChange(of: commandIndex) { _, index in if matchingCommands.indices.contains(index) { proxy.scrollTo(matchingCommands[index].id) } }
            }
            if let error = chat.commandError { Text(error).font(.ui(size: 10)).foregroundStyle(Color.orange).lineLimit(2).padding(10) }
        }.background(Color.elevated, in: OpticalRoundedRectangle())
            .overlay(OpticalRoundedRectangle().strokeBorder(Color.hairline))
            .shadow(color: .black.opacity(0.13), radius: 18, y: 6)
    }
    @ViewBuilder var commandResults: some View {
        if let output = chat.commandOutput {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("命令结果", systemImage: "terminal").font(.ui(size: 12, weight: .semibold))
                    Spacer()
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(output, forType: .string) } label: { Image(systemName: "doc.on.doc").frame(width: 26, height: 24) }.buttonStyle(ResponsiveButton()).help("复制结果")
                    Button { chat.commandOutput = nil } label: { Image(systemName: "xmark").frame(width: 26, height: 24) }.buttonStyle(ResponsiveButton()).help("关闭结果")
                }
                ScrollView { Text(verbatim: output).font(.ui(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 160)
            }.padding(12).background(Color.soft, in: OpticalRoundedRectangle())
        }
    }
    func chooseCommand(_ command: SlashCommand) {
        chat.draft = command.name + " "
        commandIndex = 0
    }
    func handleCommandKey(_ key: UInt16) -> Bool {
        guard commandMenuVisible else { return false }
        let commands = matchingCommands
        switch key {
        case 53: dismissedCommandDraft = chat.draft; return true
        case 125, 126:
            guard !commands.isEmpty else { return true }
            commandIndex = (commandIndex + (key == 125 ? 1 : commands.count - 1)) % commands.count
            return true
        case 48, 36, 76:
            guard commands.indices.contains(commandIndex) else { return false }
            chooseCommand(commands[commandIndex]); return true
        default: return false
        }
    }
}

struct MessageBubble: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.bot == rhs.bot && lhs.profile == rhs.profile && lhs.store === rhs.store
    }
    let message: ChatMessage
    let bot: Bot
    let profile: String
    let store: ChatStore
    var download: (String) -> Void
    var preview: (String) -> Void
    var user: Bool { message.role == "user" }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if user { Spacer(minLength: 70) }
            else { BotAvatar(bot: bot, size: 28, data: store.conversations[profile]?.avatar, animate: false).padding(.top, 3) }
            VStack(alignment: user ? .trailing : .leading, spacing: 5) {
                VStack(alignment: .leading, spacing: 10) {
                    if message.role == "tool" { Label("工具详情", systemImage: "wrench.and.screwdriver").font(.caption).foregroundStyle(Color.muted) }
                    MarkdownBody(text: message.text, user: user)
                    ForEach(message.attachments) { item in
                        if let data = item.imageData {
                            TranscriptImageView(data: data, cacheKey: JSON.array([.string("inline"), .string(store.addressText), .string(store.username), .string(profile), .string(message.id), .string(item.id)]).text)
                        } else { Label(item.name, systemImage: "doc.fill").font(.ui(size: 12)) }
                    }
                    ForEach(Array(remoteFiles.enumerated()), id: \.offset) { _, path in
                        RemoteFileView(path: path, profile: profile, store: store, download: { download(path) }, preview: { preview(path) })
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 15)
                .foregroundStyle(user ? Color.onOutgoing : Color.ink)
                .background(user ? Color.outgoing : Color.soft, in: OpticalRoundedRectangle())
                .frame(maxWidth: 620, alignment: user ? .trailing : .leading)
                .customContextMenu { Button("复制消息", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) } }
                if user && message.delivery != .received {
                    Text(message.delivery == .sending ? "发送中" : message.delivery == .uncertain ? "结果待确认" : message.delivery == .failed ? "未发送 · 可复制后重试" : "已提交")
                        .font(.ui(size: 9)).foregroundStyle(message.delivery == .failed || message.delivery == .uncertain ? Color.orange : Color.muted).padding(.horizontal, 6)
                }
            }
            if !user { Spacer(minLength: 60) }
        }.help(message.timestamp.timeIntervalSince1970 > 0 ? message.timestamp.formatted() : "")
    }
    private static let fileMatcher = try! NSRegularExpression(pattern: #"(?:@file:|MEDIA:\s*|\]\((?:sandbox:|file://)?)(/[^\s\)\]]+)"#)
    var remoteFiles: [String] {
        let regex = Self.fileMatcher
        let source = message.text as NSString
        return Array(Set(regex.matches(in: message.text, range: NSRange(location: 0, length: source.length)).compactMap { $0.numberOfRanges > 1 ? source.substring(with: $0.range(at: 1)) : nil })).sorted()
    }
}

private struct RemoteFileView: View {
    let path: String
    let profile: String
    let store: ChatStore
    var download: () -> Void
    var preview: () -> Void
    @State private var image: NSImage?
    @State private var loading = false
    private var isImage: Bool { UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)?.conforms(to: .image) == true }
    private var cacheKey: String { JSON.array([.string(store.addressText), .string(store.username), .string(profile), .string(path)]).text }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if isImage {
                ZStack {
                    Color.clear
                    if let image { Image(nsImage: image).resizable().scaledToFit() }
                    else { Image(systemName: "photo").foregroundStyle(Color.muted) }
                }.frame(width: 280, height: 210).clipShape(OpticalRoundedRectangle()).hoverSurface().onTapGesture(perform: preview)
            }
            HStack(spacing: 10) {
                Image(systemName: "doc")
                Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                Spacer(minLength: 4)
                if loading { ProgressView().controlSize(.mini) }
                Button("预览", action: preview).buttonStyle(ResponsiveButton())
                Button(action: download) { Image(systemName: "arrow.down.to.line") }.buttonStyle(ResponsiveButton()).help("保存文件")
            }.font(.ui(size: 11))
        }.padding(10).background(.primary.opacity(0.04), in: OpticalRoundedRectangle())
            .task(id: path) {
                guard isImage, !store.demo else { return }
                let key = cacheKey
                if let cached = TranscriptImages.cached(key) {
                    image = NSImage(cgImage: cached, size: NSSize(width: cached.width, height: cached.height)); return
                }
                loading = true; defer { loading = false }
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".preview")
                defer { try? FileManager.default.removeItem(at: destination) }
                do {
                    try await store.download(path: path, profile: profile, to: destination)
                    let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    guard size < 25 * 1024 * 1024, !Task.isCancelled else { return }
                    let decoded = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                        guard let data = try? Data(contentsOf: destination) else { return nil }
                        return TranscriptImages.decode(data, key: key)
                    }.value
                    guard !Task.isCancelled else { return }
                    image = decoded.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                } catch { /* The explicit preview/save actions expose download errors. */ }
            }
    }
}
