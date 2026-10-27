import Foundation
import Observation
import UniformTypeIdentifiers

@Observable @MainActor public final class BotConversation {
    public let profile: String
    public var storedID = ""
    public var runtimeID = ""
    public var messages: [ChatMessage] = []
    public let activity = ConversationActivity()
    public var displayingCached = false
    public var synchronizing: Bool { opening || loading }
    /// Ephemeral admission tickets: history/cache/socket messages can never create one.
    @ObservationIgnored private var outgoingEntrances: [String: Date] = [:]
    public private(set) var outgoingRevision = 0
    func registerOutgoingEntrance(_ id: String) {
        outgoingEntrances = outgoingEntrances.filter { Date().timeIntervalSince($0.value) < 2 }
        outgoingEntrances[id] = Date(); outgoingRevision += 1
    }
    public func claimOutgoingEntrance(_ id: String) -> Bool {
        guard let sentAt = outgoingEntrances.removeValue(forKey: id) else { return false }
        return Date().timeIntervalSince(sentAt) < 2
    }
    func discardOutgoingEntrances() { outgoingEntrances.removeAll(keepingCapacity: true) }
    @ObservationIgnored var pendingStreamText = ""
    @ObservationIgnored var streamFlushTask: Task<Void, Never>?
    @ObservationIgnored var lastSyncedAt = Date.distantPast
    public var cards: [PendingCard] = []
    public var draft = ""
    public var attachments: [ChatAttachment] = []
    public var loading = false
    public var uploading = false
    public var running = false
    public var status = ""
    public var error: String?
    public var hasOlder = false
    public var offset = 0
    public var generation = 0
    public var revision = 0
    /// Explicit navigation intent, separate from incoming message revisions.
    public var entryRevision = 0
    public var avatar: Data?
    public var model = ""
    public var provider = ""
    public var pendingModel = ""
    public var pendingProvider = ""
    public var models: [ChatModelOption] = []
    public var loadingModels = false
    public var switchingModel = false
    public var commands: [SlashCommand] = []
    public var loadingCommands = false
    public var executingCommand = false
    public var commandError: String?
    public var commandOutput: String?
    public var modelError: String?
    public var modelNotice: String?
    public var scrollAnchor: String?
    public var lastSequence = -1
    public var searchResults: [ChatMessage] = []
    public var searching = false
    public var searchError: String?
    public var searchTask: Task<Void, Never>?
    @ObservationIgnored var stagingTask: Task<Void, Never>?
    @ObservationIgnored var stagedFolders: Set<URL> = []
    var streamingID: String?
    public var hasStreamingReply: Bool { streamingID != nil }
    var opening = false
    var binding = false
    var bufferingEvents = false
    @ObservationIgnored var refreshRequested = false
    @ObservationIgnored var openRequest: UUID?
    @ObservationIgnored var historyRequest: UUID?
    @ObservationIgnored var lastEventAt = Date.distantPast
    var buffered: [GatewayEvent] = []
    var loadedRowIDs: Set<String> = []
    public var canSubmit: Bool { !runtimeID.isEmpty && !binding && (!loading || !messages.isEmpty) && !executingCommand }
    public init(profile: String) { self.profile = profile }
}

public enum ConnectionPhase: Equatable {
    case signedOut, connecting, connected, reconnecting(Int)
    public var label: String {
        switch self {
        case .signedOut: return "未连接"
        case .connecting: return "正在连接"
        case .connected: return "已连接"
        case .reconnecting(let n): return "重连中 · \(n)"
        }
    }
}

@Observable @MainActor public final class ChatStore {
    public var addressText: String
    public var username = ""
    public var loginError: String?
    public var connecting = false
    public var requiresLogin = false
    public var phase: ConnectionPhase = .signedOut
    public var bots: [Bot] = []
    public var selected: String?
    public var conversations: [String: BotConversation] = [:]
    public var filter = ""
    public var banner: String?
    public var demo = false
    public var serverVersion = ""
    public var unread: Set<String> = []
    public var pinnedProfiles: [String] = []
    public var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notifications") }
    }
    @ObservationIgnored public var notify: ((String, String, String) -> Void)?
    @ObservationIgnored public private(set) var transport: GatewayTransport?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var connectionEpoch = 0
    @ObservationIgnored private let credentials: any CredentialStorage
    @ObservationIgnored private var credentialSaveTask: Task<Void, Never>?
    @ObservationIgnored private var activeRestore: UUID?
    @ObservationIgnored private var activeLogin: UUID?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastActive: [String: Double] = [:]
    @ObservationIgnored private var seen: [String: Double] = [:]
    @ObservationIgnored private var unboundEvents: [GatewayEvent] = []
    @ObservationIgnored private var unboundCards: [PendingCard] = []
    @ObservationIgnored private let displayCache = ConversationCache()
    @ObservationIgnored private var cacheOwner = UUID()
    @ObservationIgnored private var cacheKey: String?
    @ObservationIgnored private var cacheTask: Task<Void, Never>?
    @ObservationIgnored private var cacheWriteRequest: UUID?
    @ObservationIgnored private var accountIdentity: String?
    @ObservationIgnored private var botListRequest: UUID?
    public init(defaults: UserDefaults = .standard, credentials: (any CredentialStorage)? = nil) {
        self.defaults = defaults; self.credentials = credentials ?? CredentialVault.shared
        addressText = defaults.string(forKey: "gateway") ?? ""
        notificationsEnabled = defaults.bool(forKey: "notifications")
        username = defaults.string(forKey: "username") ?? ""
    }
    public var current: BotConversation? { selected.flatMap { conversations[$0] } }
    public var currentBot: Bot? { bots.first { $0.id == selected } }
    public var filteredBots: [Bot] { bots.filter { !($0.hidden) && (filter.isEmpty || ($0.name + $0.profile + $0.subtitle).localizedCaseInsensitiveContains(filter)) } }
    public var pinnedBots: [Bot] { pinnedProfiles.compactMap { profile in bots.first { $0.profile == profile && !$0.hidden } } }
    public var unpinnedBots: [Bot] { filteredBots.filter { !pinnedProfiles.contains($0.profile) } }
    public func togglePin(_ profile: String) {
        if pinnedProfiles.contains(profile) { pinnedProfiles.removeAll { $0 == profile } }
        else { pinnedProfiles.append(profile) }
        if let key = preferenceKey { defaults.set(pinnedProfiles, forKey: "pinned." + key) }
    }
    private var preferenceKey: String? {
        if demo { return "demo" }
        guard let address = transport?.address ?? (try? GatewayAddress(addressText)) else { return nil }
        return ConversationCache.key(gateway: address.url.absoluteString, user: username)
    }
    public var workingCount: Int { conversations.values.filter(\.running).count }
    public var attentionCount: Int { conversations.values.reduce(0) { $0 + $1.cards.count } }
    public func restore() async {
        guard phase == .signedOut, !demo, !connecting, activeRestore == nil, let address = try? GatewayAddress(addressText) else { return }
        guard !defaults.bool(forKey: "disableRestore." + address.key) else { return }
        let restoreID = UUID(); activeRestore = restoreID; let epoch = connectionEpoch
        defer { if activeRestore == restoreID { activeRestore = nil } }
        phase = .connecting
        await restoreDisplayCache(address: address, epoch: epoch)
        do {
            guard let creds = try await credentials.read(address.key) else {
                if activeRestore == restoreID && epoch == connectionEpoch { phase = .signedOut; requiresLogin = !bots.isEmpty }
                return
            }
            guard !Task.isCancelled, activeRestore == restoreID, epoch == connectionEpoch, !demo, phase == .connecting, (try? GatewayAddress(addressText)) == address else { return }
            try await establish(address: address, credentials: creds)
        } catch { if activeRestore == restoreID && !demo && !Task.isCancelled { loginError = readable(error); phase = .signedOut; requiresLogin = !bots.isEmpty } }
    }
    public func login(password: String) async {
        guard !connecting else { return }
        activeRestore = nil
        connectionEpoch += 1; let epoch = connectionEpoch
        let loginID = UUID(); activeLogin = loginID
        connecting = true; loginError = nil
        defer { if activeLogin == loginID { connecting = false; activeLogin = nil } }
        do {
            let address = try GatewayAddress(addressText)
            let creds = try await GatewayTransport.login(address: address, username: username, password: password)
            guard epoch == connectionEpoch, !Task.isCancelled else { return }
            defaults.set(true, forKey: "disableRestore." + address.key)
            defaults.set(address.url.absoluteString, forKey: "gateway"); defaults.set(username, forKey: "username")
            try await establish(address: address, credentials: creds)
            if activeLogin == loginID, !demo, let api = transport, phase == .connected, !Task.isCancelled {
                persistCredentials(api.credentialsSnapshot ?? creds, account: address.key, epoch: connectionEpoch)
            }
        } catch { if activeLogin == loginID && !demo && !Task.isCancelled { loginError = readable(error); phase = .signedOut } }
    }
    func establish(address: GatewayAddress, credentials: Credentials) async throws {
        connectionEpoch += 1; let epoch = connectionEpoch
        cacheTask?.cancel(); cacheTask = nil; cacheWriteRequest = nil
        let identity = ConversationCache.key(gateway: address.url.absoluteString, user: username)
        let wasDemo = demo
        demo = false; phase = .connecting; banner = nil; requiresLogin = false
        if wasDemo || (accountIdentity != nil && accountIdentity != identity) {
            conversations.values.forEach { retire($0) }
            conversations = [:]; bots = []; selected = nil; unread = []; seen = [:]; lastActive = [:]
            unboundEvents = []; unboundCards = []
        }
        accountIdentity = identity
        pinnedProfiles = defaults.stringArray(forKey: "pinned." + identity) ?? []
        await restoreDisplayCache(address: address, epoch: epoch)
        guard epoch == connectionEpoch else { return }
        transport?.disconnect(); pollTask?.cancel(); reconnectTask?.cancel()
        suspendConversations()
        let api = GatewayTransport(address: address, credentials: credentials)
        install(api, epoch: epoch)
        transport = api
        do {
            let status = try await api.request("/api/status", authenticated: false)
            guard epoch == connectionEpoch, !demo, !Task.isCancelled else { api.disconnect(); return }
            serverVersion = status["version"].string
            try await api.connect()
            guard epoch == connectionEpoch else { return }
            try await loadBots()
            guard epoch == connectionEpoch else { return }
            phase = .connected; banner = nil; requiresLogin = false
            if let selected { await open(profile: selected, force: true) }
            guard epoch == connectionEpoch, phase == .connected else { return }
            startPolling(epoch: epoch)
            if selected == nil, let first = bots.first(where: { !$0.hidden }) { await select(first.profile) }
        } catch {
            api.disconnect()
            guard epoch == connectionEpoch else { return }
            reconnectTask?.cancel(); pollTask?.cancel()
            if case ClientError.unauthorized = error {
                phase = .signedOut; requiresLogin = !bots.isEmpty
                throw error
            }
            if !bots.isEmpty {
                banner = readable(error); reconnect(epoch: epoch)
            } else { phase = .signedOut; throw error }
        }
    }
    private func restoreDisplayCache(address: GatewayAddress, epoch: Int) async {
        let identity = ConversationCache.key(gateway: address.url.absoluteString, user: username)
        guard cacheKey != identity || bots.isEmpty else { return }
        cacheTask?.cancel(); cacheTask = nil; cacheOwner = UUID(); cacheKey = identity
        let owner = cacheOwner
        let cached = await displayCache.activate(owner, key: identity)
        guard epoch == connectionEpoch, cacheOwner == owner, !demo, let cached, bots.isEmpty else { return }
        accountIdentity = identity; pinnedProfiles = defaults.stringArray(forKey: "pinned." + identity) ?? []
        bots = cached.bots; selected = cached.selected ?? bots.first(where: { !$0.hidden })?.profile
        for saved in cached.conversations {
            let chat = conversation(saved.profile)
            chat.storedID = saved.storedID; chat.messages = TranscriptReconciler.merge(saved.messages, into: [])
            chat.streamingID = chat.messages.last(where: \.streaming)?.id
            chat.draft = saved.draft; chat.scrollAnchor = "bottom"
            chat.model = saved.model; chat.provider = saved.provider; chat.displayingCached = true
            chat.hasOlder = true; chat.offset = 0
        }
        banner = "已显示本机缓存，正在同步最新消息"
    }
    private func install(_ api: GatewayTransport, epoch: Int) {
        let account = api.address.key
        api.onCredentials = { [weak self] creds in self?.persistCredentials(creds, account: account, epoch: epoch) }
        api.onEvent = { [weak self] event in guard let self, self.connectionEpoch == epoch else { return }; self.handle(event) }
        api.onRequest = { [weak self] card in guard let self, self.connectionEpoch == epoch else { return }; self.receive(card) }
        api.onDisconnect = { [weak self] error in
            guard let self, self.connectionEpoch == epoch else { return }
            guard self.phase == .connected else { return }
            self.banner = self.readable(error)
            self.reconnect(epoch: epoch)
        }
    }
    private func persistCredentials(_ creds: Credentials, account: String, epoch: Int) {
        guard epoch == connectionEpoch else { return }
        credentialSaveTask?.cancel()
        credentialSaveTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.connectionEpoch == epoch else { return }
            do {
                try await self.credentials.save(creds, account: account)
                if !Task.isCancelled && self.connectionEpoch == epoch { self.defaults.set(false, forKey: "disableRestore." + account) }
            }
            catch { if !Task.isCancelled && self.connectionEpoch == epoch { self.banner = "已连接，但登录状态未能保存；下次打开需重新登录" } }
        }
    }
    public func logout() {
        let account = transport?.address.key ?? (try? GatewayAddress(addressText))?.key
        cacheTask?.cancel(); cacheTask = nil
        let key = cacheKey, owner = cacheOwner
        Task { await displayCache.deactivate(owner: owner, key: key, remove: true) }
        cacheKey = nil; accountIdentity = nil
        connectionEpoch += 1; credentialSaveTask?.cancel(); activeLogin = nil; activeRestore = nil; connecting = false; loginError = nil; requiresLogin = false; pinnedProfiles = []
        if let account { defaults.set(true, forKey: "disableRestore." + account); credentials.delete(account) }
 pollTask?.cancel(); reconnectTask?.cancel(); transport?.disconnect(); transport = nil
        for chat in conversations.values { retire(chat) }
        phase = .signedOut; demo = false; bots = []; conversations = [:]; selected = nil; banner = nil; unread = []; lastActive = [:]; seen = [:]; unboundEvents = []; unboundCards = []
    }
    public func reconnectNow() {
        guard !demo else { return }
        if phase == .signedOut { requiresLogin = true; return }
        reconnect(epoch: connectionEpoch)
    }
    private func reconnect(epoch: Int) {
        reconnectTask?.cancel(); pollTask?.cancel()
        phase = .reconnecting(1)
        suspendConversations()
        reconnectTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self, let api = self.transport, epoch == self.connectionEpoch else { return }
                attempt += 1; self.phase = .reconnecting(attempt)
                do {
                    try await api.connect()
                    guard !Task.isCancelled, epoch == self.connectionEpoch else { return }
                    try await self.loadBots()
                    guard !Task.isCancelled, epoch == self.connectionEpoch else { return }
                    self.phase = .connected; self.banner = nil; self.requiresLogin = false
                    if let selected = self.selected { await self.open(profile: selected, force: true) }
                    guard !Task.isCancelled, epoch == self.connectionEpoch, self.phase == .connected else { return }
                    self.startPolling(epoch: epoch); return
                } catch ClientError.unauthorized {
                    guard !Task.isCancelled, epoch == self.connectionEpoch else { return }
                    self.phase = .signedOut; self.loginError = "登录已过期，请重新登录"; self.requiresLogin = !self.bots.isEmpty; return
                } catch {
                    guard !Task.isCancelled, epoch == self.connectionEpoch else { return }
                    self.banner = self.readable(error)
                    try? await Task.sleep(for: .seconds(min(30, pow(1.8, Double(attempt))) + Double.random(in: 0...0.5)))
                }
            }
        }
    }
    private func suspendConversations() {
        botListRequest = nil
        for chat in conversations.values {
            flushStreaming(chat)
            chat.activity.clear(); chat.running = false; chat.status = ""
            chat.openRequest = nil; chat.historyRequest = nil
            chat.opening = false; chat.binding = false; chat.bufferingEvents = false; chat.refreshRequested = false; chat.loading = false; chat.runtimeID = ""; chat.buffered = []
        }
        cacheCurrentState()
    }
    private func startPolling(epoch: Int) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, let self, epoch == self.connectionEpoch, self.phase == .connected else { return }
                do { try await self.loadBots() }
                catch { if !Task.isCancelled, epoch == self.connectionEpoch, !(error is CancellationError) { self.banner = self.readable(error) } }
            }
        }
    }
    public func loadBots() async throws {
        guard let api = transport, botListRequest == nil else { return }
        let request = UUID(); botListRequest = request
        defer { if botListRequest == request { botListRequest = nil } }
        let epoch = connectionEpoch, serial = api.connectionSerial
        let result = try await api.call("profiles.list", params: ["include_sessions": true], profile: "default", timeout: 30)
        guard epoch == connectionEpoch, serial == api.connectionSerial, botListRequest == request, !Task.isCancelled else { throw CancellationError() }
        guard case .array = result["profiles"] else { throw ClientError.message("Hermes 尚未返回有效的助手目录，已保留当前聊天。") }
        var updated = result["profiles"].array.map(Bot.init).filter { !$0.profile.isEmpty }
        if updated.isEmpty && !bots.isEmpty { return }
        // An incomplete registry refresh must not remove the current conversation canvas.
        if let selected, !updated.contains(where: { $0.profile == selected }), let old = bots.first(where: { $0.profile == selected }) { updated.append(old) }
        for bot in updated {
            let key = "seen.\(api.address.key).\(bot.profile)"
            if seen[bot.profile] == nil { seen[bot.profile] = defaults.object(forKey: key) as? Double ?? bot.lastActive }
            if bot.lastActive > (seen[bot.profile] ?? 0) + 0.01, bot.profile != selected { unread.insert(bot.profile) }
            if let previous = lastActive[bot.profile] {
                if let chat = conversations[bot.profile],
                   (bot.lastActive > previous && !chat.running || chat.running && Date().timeIntervalSince(chat.lastEventAt) > 20),
                   !chat.loading, !chat.uploading, !chat.opening, !chat.executingCommand {
                    // A terminal event can be lost without changing the transcript's timestamp.
                    // Reconcile active work against the server snapshot as a backstop.
                    Task { [weak self] in await self?.open(profile: bot.profile, force: true) }
                } else if bot.lastActive > previous, notificationsEnabled, selected != bot.profile, conversations[bot.profile] == nil, !bot.resolvedID.isEmpty {
                    Task { [weak self] in
                        guard let self else { return }
                        guard let page = try? await api.request("/api/sessions/\(bot.resolvedID)/messages", profile: bot.profile, query: [.init(name: "limit", value: "1"), .init(name: "order", value: "latest"), .init(name: "inline_images", value: "false")]),
                              self.connectionEpoch == epoch, self.notificationsEnabled, self.selected != bot.profile,
                              let row = page["messages"].array.last, let message = ChatMessage.from(row), message.role == "assistant" else { return }
                        self.notify?(bot.profile, bot.name, String(message.text.prefix(160)))
                    }
                }
            }
            lastActive[bot.profile] = bot.lastActive
        }
        if bots != updated { bots = updated }
        if let selected, !updated.contains(where: { $0.profile == selected }) { self.selected = nil }
        cacheCurrentState()
    }
    public func select(_ profile: String) async {
        if let selected { conversations[selected]?.discardOutgoingEntrances() }
        selected = profile; unread.remove(profile)
        let chat = conversation(profile)
        chat.scrollAnchor = "bottom"
        chat.entryRevision += 1
        if let api = transport {
            let stamp = max(Date().timeIntervalSince1970, bots.first(where: { $0.profile == profile })?.lastActive ?? 0)
            seen[profile] = stamp; defaults.set(stamp, forKey: "seen.\(api.address.key).\(profile)")
        }
        if !demo { await open(profile: profile) }
        chat.revision += 1
        cacheCurrentState()
    }
    public func conversation(_ profile: String) -> BotConversation {
        if let chat = conversations[profile] { return chat }
        let chat = BotConversation(profile: profile)
        conversations[profile] = chat
        return chat
    }
    public func open(profile: String, force: Bool = false) async {
        guard let api = transport, phase == .connected else { return }
        let chat = conversation(profile)
        guard !demo else { return }
        if chat.opening { if force { chat.refreshRequested = true }; return }
        guard !chat.loading else { return }
        if !force, !chat.runtimeID.isEmpty, Date().timeIntervalSince(chat.lastSyncedAt) < 8 { return }
        flushStreaming(chat)
        let request = UUID(); chat.openRequest = request
        chat.opening = true; chat.binding = true; chat.bufferingEvents = true; chat.loading = chat.messages.isEmpty; chat.error = nil
        let epoch = connectionEpoch, serial = api.connectionSerial
        func current() -> Bool { epoch == connectionEpoch && serial == api.connectionSerial && conversations[profile] === chat && chat.openRequest == request && !Task.isCancelled }
        defer {
            if chat.openRequest == request {
                chat.opening = false; chat.binding = false; chat.bufferingEvents = false; chat.loading = false; chat.openRequest = nil
                if chat.refreshRequested {
                    chat.refreshRequested = false
                    Task { [weak self] in await self?.open(profile: profile, force: true) }
                }
            }
        }
        do {
            var params: [String: JSON] = ["title": "Bot Chat", "include_hidden": true, "limit": 200]
            if api.sessionAuthority { params["scope"] = "stored" }
            let list = try await api.call("session.list", params: params, profile: profile)
            guard current() else { return }
            guard let row = Bot.canonical(from: list["sessions"].array) else {
                chat.error = "这个 Bot 还没有固定 Bot Chat，请先在 Hermes 中初始化它的 Bot 对话"; return
            }
            let sid = row["resolved_id"].string.isEmpty ? row["id"].string : row["resolved_id"].string
            guard !sid.isEmpty else { throw ClientError.message("无法解析这个 Bot 的固定会话") }
            // Start buffering before resume; events may precede its response.
            let snapshot = try await api.call("session.resume", params: ["session_id": .string(sid), "omit_messages": true, "cols": 100], profile: profile)
            guard current() else { return }
            chat.runtimeID = snapshot["session_id"].string
            chat.binding = false
            chat.storedID = snapshot["stored_session_id"].string.isEmpty ? sid : snapshot["stored_session_id"].string
            chat.generation = Int(snapshot["execution_generation"].number ?? 0)
            chat.lastSequence = Int(snapshot["last_sequence"].number ?? -1)
            chat.buffered += unboundEvents.filter { $0.sessionID == chat.runtimeID || $0.sessionID == chat.storedID }
            unboundEvents.removeAll { $0.sessionID == chat.runtimeID || $0.sessionID == chat.storedID }
            chat.running = snapshot["running"].bool || snapshot["info"]["running"].bool
            chat.adoptModel(snapshot)
            chat.status = chat.running ? "正在处理" : ""
            chat.cards = snapshot["open_requests"].array.map { item in PendingCard(id: item["id"].string, method: item["method"].string, params: item["params"], requestID: item["id"]) }
            for prompt in snapshot["prompts"].array {
                chat.cards.append(PendingCard(id: prompt["prompt_id"].string, method: prompt["kind"].string == "approval" ? "approval" : "clarify", params: prompt, viaRPC: true))
            }
            if !snapshot["pending_approval"].isNull, chat.cards.isEmpty {
                let p = snapshot["pending_approval"]
                chat.cards.append(PendingCard(id: p["request_id"].string, method: "approval", params: p, viaRPC: true))
            }
            restoreInflight(snapshot["inflight"]["assistant"].string, chat: chat)
            if !chat.running { chat.activity.clear() }
            else if chat.streamingID == nil { chat.activity.waiting() }
            // The socket is live as soon as binding is complete. A slow history/image page
            // must not hold streaming tokens or tool state in a buffer.
            chat.bufferingEvents = false
            let buffered = chat.buffered; chat.buffered = []
            for event in buffered { apply(event, chat: chat) }
            flushStreaming(chat)
            let waiting = unboundCards.filter { $0.params["session_id"].string == chat.runtimeID || $0.params["session_id"].string == chat.storedID }
            unboundCards.removeAll { $0.params["session_id"].string == chat.runtimeID || $0.params["session_id"].string == chat.storedID }
            for card in waiting { receive(card) }
            let page = try await api.request("/api/sessions/\(chat.storedID)/messages", profile: profile, query: [.init(name: "limit", value: "80"), .init(name: "order", value: "latest")])
            guard current() else { return }
            guard case .array = page["messages"] else { throw ClientError.message("Hermes 尚未返回有效消息，当前记录已保留。") }
            let rows = page["messages"].array
            let incoming = await TranscriptReconciler.decode(rows)
            guard current() else { return }
            let messages = TranscriptReconciler.merge(incoming, into: chat.messages, activeStreamID: chat.streamingID)
            let contentChanged = chat.messages != messages
            if contentChanged { chat.messages = messages }
            if !rows.isEmpty || chat.messages.isEmpty {
                chat.loadedRowIDs = Set(incoming.map { $0.serverID ?? $0.id })
                chat.offset = rows.count; chat.hasOlder = rows.count == 80
                chat.displayingCached = false
            }
            chat.lastSyncedAt = Date()
            if contentChanged { chat.revision += 1 }
            cacheCurrentState()
            if chat.avatar == nil, bots.first(where: { $0.profile == profile })?.hasAvatar == true {
                let asset = try? await api.call("profiles.get_asset", params: ["name": .string(profile), "asset": "avatar"], profile: profile)
                if current(), let encoded = asset?["data"].string { chat.avatar = Data(base64Encoded: encoded.components(separatedBy: ",").last ?? encoded) }
            }
        } catch {
            if current() {
                chat.bufferingEvents = false
                let pending = chat.buffered; chat.buffered = []
                for event in pending { apply(event, chat: chat) }
                flushStreaming(chat); chat.error = readable(error)
            }
        }
    }
    public func loadOlder(_ chat: BotConversation) async {
        guard let api = transport, phase == .connected, !chat.loading, !chat.opening, chat.hasOlder, !chat.storedID.isEmpty else { return }
        let epoch = connectionEpoch, sid = chat.storedID, serial = api.connectionSerial
        let request = UUID(); chat.historyRequest = request
        chat.loading = true
        defer { if chat.historyRequest == request { chat.loading = false; chat.historyRequest = nil } }
        do {
            let result = try await api.request("/api/sessions/\(chat.storedID)/messages", profile: chat.profile, query: [.init(name: "limit", value: "80"), .init(name: "order", value: "latest"), .init(name: "offset", value: String(chat.offset))])
            guard epoch == connectionEpoch, serial == api.connectionSerial, chat.historyRequest == request, conversations[chat.profile] === chat, sid == chat.storedID else { return }
            guard case .array = result["messages"] else { throw ClientError.message("历史消息暂未返回，已有记录已保留。") }
            let rows = result["messages"].array
            let older = await TranscriptReconciler.decode(rows, offset: chat.offset)
            guard epoch == connectionEpoch, serial == api.connectionSerial, chat.historyRequest == request, conversations[chat.profile] === chat, sid == chat.storedID else { return }
            let merged = TranscriptReconciler.merge(older, into: chat.messages, activeStreamID: chat.streamingID)
            if merged != chat.messages { chat.messages = merged; chat.revision += 1 }
            chat.offset += rows.count; chat.hasOlder = rows.count == 80
            chat.loadedRowIDs.formUnion(older.map { $0.serverID ?? $0.id })
            cacheCurrentState()
        } catch { if epoch == connectionEpoch, serial == api.connectionSerial, chat.historyRequest == request { chat.error = readable(error) } }
    }
    public func send(_ chat: BotConversation, prompt: String? = nil) async {
        guard !demo, let api = transport, phase == .connected, chat.canSubmit, !chat.uploading, !chat.switchingModel,
              !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.attachments.isEmpty else { return }
        let command = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandName = String(command.split(whereSeparator: { $0.isWhitespace }).first ?? "").lowercased()
        if prompt == nil, ["/new", "/reset", "/compact", "/compress"].contains(commandName) {
            guard command.lowercased() == commandName else { chat.error = "固定 Bot Chat 的上下文整理命令不接受额外参数，草稿已保留"; return }
            guard !chat.running else { chat.error = "助手仍在回复，请等待结束或先停止回复，再整理上下文"; return }
            guard chat.attachments.isEmpty else { chat.error = "请先发送或移除附件，再整理上下文"; return }
            if await compact(chat), chat.draft.trimmingCharacters(in: .whitespacesAndNewlines) == command { chat.draft = "" }
            return
        }
        if prompt == nil, SlashCommand.isInvocation(command) { await executeCommand(command, for: chat); return }
        let epoch = connectionEpoch, serial = api.connectionSerial, sid = chat.runtimeID
        chat.error = nil; chat.uploading = true
        defer { chat.uploading = false }
        let text = chat.draft, attachments = chat.attachments
        var outgoing = prompt ?? text
        do {
            for attachment in attachments {
                guard let url = attachment.localURL else { continue }
                let data = try await Task.detached { try Data(contentsOf: url) }.value
                if data.count > 25 * 1024 * 1024 { throw ClientError.message("\(attachment.name) 超过 25 MB，请缩小后再发送") }
                let type = UTType(filenameExtension: url.pathExtension)
                var p: [String: JSON] = ["session_id": .string(chat.runtimeID)]
                if type?.conforms(to: .image) == true {
                    p["content_base64"] = .string(data.base64EncodedString()); p["filename"] = .string(attachment.name)
                    _ = try await api.call("image.attach_bytes", params: p, profile: chat.profile)
                } else if type?.conforms(to: .pdf) == true {
                    p["content_base64"] = .string(data.base64EncodedString()); p["filename"] = .string(attachment.name)
                    _ = try await api.call("pdf.attach", params: p, profile: chat.profile)
                } else {
                    p["data_url"] = .string("data:\(type?.preferredMIMEType ?? "application/octet-stream");base64,\(data.base64EncodedString())"); p["name"] = .string(attachment.name)
                    let result = try await api.call("file.attach", params: p, profile: chat.profile)
                    guard !result["ref_text"].string.isEmpty else { throw ClientError.message("网关未返回文件引用") }
                    outgoing += "\n" + result["ref_text"].string
                }
            }
        } catch { chat.error = "附件未发送：" + readable(error); return }
        guard epoch == connectionEpoch, serial == api.connectionSerial, phase == .connected, sid == chat.runtimeID,
              conversations[chat.profile] === chat else {
            chat.error = "连接已变化，草稿和附件已保留，请等同步完成后再发送"; return
        }
        if outgoing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { outgoing = "请查看附件。" }
        var message = ChatMessage(role: "user", text: text.isEmpty ? "附件" : text)
        message.attachments = attachments; message.delivery = .sending
        chat.registerOutgoingEntrance(message.id)
        chat.messages.append(message); chat.draft = ""; chat.attachments = []; chat.running = true; chat.status = "正在发送"; chat.activity.clear(); chat.activity.waiting("正在发送"); chat.revision += 1
        cacheCurrentState()
        var p: [String: JSON] = ["session_id": .string(chat.runtimeID), "text": .string(outgoing), "queued": true]
        if api.sessionAuthority { p["submission_id"] = .string(message.id); p["clarify_batch"] = true }
        let admittedGeneration = chat.generation
        defer { cacheCurrentState() }
        do {
            let result = try await api.call("prompt.submit", params: p, profile: chat.profile, timeout: 45)
            guard epoch == connectionEpoch, conversations[chat.profile] === chat, !demo else { return }
            if let i = chat.messages.firstIndex(where: { $0.id == message.id }) {
                if chat.messages[i].delivery != .received { chat.messages[i].delivery = .accepted }
                if let rowID = result["user_row_id"].number { chat.messages[i].serverID = "row-\(Int(rowID))" }
            }
            guard serial == api.connectionSerial, sid == chat.runtimeID else { return }
            if let g = result["execution_generation"].number { chat.generation = max(chat.generation, Int(g)) }
            if chat.running { chat.status = result["status"].string == "queued" ? "已排队" : "正在处理" }
        } catch {
            guard epoch == connectionEpoch, conversations[chat.profile] === chat, !demo else { return }
            let uncertain: Bool
            if case ClientError.rpc = error { uncertain = false } else { uncertain = true }
            if let i = chat.messages.firstIndex(where: { $0.id == message.id }) {
                guard chat.messages[i].delivery != .received else { return }
                chat.messages[i].delivery = uncertain ? .uncertain : .failed
            }
            chat.error = uncertain ? "发送结果尚未确认。恢复连接后会重新读取历史，请先不要重复发送。" : readable(error)
            if chat.generation == admittedGeneration { chat.running = false; chat.status = ""; chat.activity.clear() }
        }
    }
    @discardableResult public func compact(_ chat: BotConversation) async -> Bool {
        guard let api = transport, !chat.running, chat.canSubmit else { return false }
        do {
            let result = try await api.call("session.compress", params: ["session_id": .string(chat.runtimeID)], profile: chat.profile)
            if result["compressed"] == .bool(false) || result["status"].string == "aborted" || result["lock_held"].bool {
                chat.error = result["message"].string.isEmpty ? "此次上下文整理未完成，请稍后重试" : result["message"].string
                return false
            }
            await open(profile: chat.profile, force: true); return true
        } catch { chat.error = readable(error); return false }
    }
    @discardableResult public func stop(_ chat: BotConversation) async -> Bool {
        guard let api = transport, phase == .connected else { return false }
        var p: [String: JSON] = ["session_id": .string(chat.runtimeID)]
        if api.sessionAuthority { p["execution_generation"] = .number(Double(chat.generation)) }
        do { _ = try await api.call("session.interrupt", params: p, profile: chat.profile); chat.status = "正在停止"; return true }
        catch { chat.error = readable(error); return false }
    }
    public func answer(_ card: PendingCard, chat: BotConversation, result: JSON) async throws {
        guard let api = transport else { throw ClientError.disconnected }
        if card.viaRPC {
            var p: [String: JSON] = ["session_id": .string(chat.runtimeID)]
            if api.sessionAuthority {
                p["execution_generation"] = card.params["execution_generation"].isNull ? .number(Double(chat.generation)) : card.params["execution_generation"]; p["prompt_id"] = .string(card.id)
                if card.isApproval { p["choice"] = result["choice"] }
                else { p["answer"] = result["answers"]["answer"].isNull ? result["answer"] : result["answers"]["answer"] }
            } else { p["request_id"] = .string(card.id); p["choice"] = result["choice"] }
            _ = try await api.call(card.isApproval ? "approval.respond" : "clarify.respond", params: p, profile: chat.profile)
        } else { try await api.respond(card.requestID, result: result) }
        chat.cards.removeAll { $0.id == card.id }
    }
    private func receive(_ card: PendingCard) {
        let sid = card.params["session_id"].string
        guard let chat = conversations.values.first(where: { $0.runtimeID == sid || $0.storedID == sid }) else {
            if !sid.isEmpty { unboundCards.append(card); unboundCards = Array(unboundCards.suffix(100)) }; return
        }
        chat.cards.removeAll { $0.id == card.id || (!$0.params["request_id"].string.isEmpty && $0.params["request_id"] == card.params["request_id"]) }
        chat.cards.append(card); chat.status = "等待你确认"
        if card.isApproval, !card.params["request_id"].string.isEmpty, let api = transport, !api.sessionAuthority {
            Task { _ = try? await api.call("approval.received", params: ["session_id": .string(chat.runtimeID), "request_id": card.params["request_id"]], profile: chat.profile) }
        }
        if notificationsEnabled { notify?(chat.profile, bots.first(where: { $0.profile == chat.profile })?.name ?? chat.profile, card.title) }
    }
    private func handle(_ event: GatewayEvent) {
        if event.type == "sessions.changed" || event.type == "profiles.changed" { Task { try? await loadBots() }; return }
        guard let chat = conversations.values.first(where: { (!event.sessionID.isEmpty && ($0.runtimeID == event.sessionID || $0.storedID == event.sessionID)) }) else {
            // A resume can announce its new runtime before the response binds it.
            if let opening = conversations.values.first(where: { $0.bufferingEvents && $0.profile == event.payload["profile"].string }) { opening.buffered.append(event) }
            else if !event.sessionID.isEmpty, conversations.values.contains(where: \.bufferingEvents) { unboundEvents.append(event); unboundEvents = Array(unboundEvents.suffix(2048)) }
            return
        }
        if chat.bufferingEvents { chat.buffered.append(event); return }
        apply(event, chat: chat)
    }
    private func queueStreaming(_ text: String, chat: BotConversation) {
        chat.activity.clear()
        if chat.streamingID == nil { appendStreaming(text, chat: chat); return }
        chat.pendingStreamText += text
        guard chat.streamFlushTask == nil else { return }
        chat.streamFlushTask = Task { @MainActor [weak self, weak chat] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self, let chat else { return }
            self.flushStreaming(chat)
        }
    }
    private func flushStreaming(_ chat: BotConversation) {
        chat.streamFlushTask?.cancel(); chat.streamFlushTask = nil
        guard !chat.pendingStreamText.isEmpty else { return }
        let text = chat.pendingStreamText; chat.pendingStreamText = ""
        appendStreaming(text, chat: chat)
    }
    private func appendStreaming(_ text: String, chat: BotConversation) {
        guard !text.isEmpty else { return }
        if let id = chat.streamingID, let index = chat.messages.firstIndex(where: { $0.id == id }) { chat.messages[index].text += text }
        else {
            var m = ChatMessage(role: "assistant", text: text); m.streaming = true
            chat.streamingID = m.id; chat.messages.append(m)
        }
        if !chat.running { chat.running = true }
        if chat.status != "正在回复" { chat.status = "正在回复" }
        chat.activity.clear(); chat.revision += 1
    }
    private func restoreInflight(_ text: String, chat: BotConversation) {
        if let id = chat.streamingID, let i = chat.messages.firstIndex(where: { $0.id == id }), chat.messages[i].serverID != nil {
            if text.isEmpty || chat.messages[i].text != text { chat.streamingID = nil }
        }
        if chat.running, !text.isEmpty {
            if let id = chat.streamingID, let i = chat.messages.firstIndex(where: { $0.id == id }) {
                chat.messages[i].text = text; chat.messages[i].streaming = true
            } else { appendStreaming(text, chat: chat) }
            chat.activity.clear()
        } else if !chat.running {
            // Keep the partial marker until persisted history can match and complete it.
            // It has no active spinner and is not considered the current streaming reply.
            chat.streamingID = nil
        }
    }
    private func finishStreaming(_ text: String, chat: BotConversation) {
        flushStreaming(chat)
        if let id = chat.streamingID, let index = chat.messages.firstIndex(where: { $0.id == id }) {
            if !text.isEmpty { chat.messages[index].text = text }
            chat.messages[index].streaming = false
            if chat.messages[index].serverID == nil { chat.messages[index].timestamp = Date() }
        } else if !text.isEmpty, chat.messages.last?.role != "assistant" || chat.messages.last?.text != text {
            chat.messages.append(ChatMessage(role: "assistant", text: text))
        }
        chat.streamingID = nil
    }
    private func apply(_ event: GatewayEvent, chat: BotConversation) {
        defer { if ["message.start", "message.delta", "message.interim", "message.complete", "session.info", "session.reclaimed", "error"].contains(event.type) { cacheCurrentState() } }
        if let seq = event.sequence { if seq <= chat.lastSequence { return }; chat.lastSequence = seq }
        chat.lastEventAt = Date()
        let p = event.payload
        if let g = p["execution_generation"].number {
            guard Int(g) >= chat.generation else { return }
            chat.generation = Int(g)
        }
        switch event.type {
        case "approval.request", "clarify.request":
            let id = p["prompt_id"].string
            guard !id.isEmpty else { return }
            chat.cards.removeAll { $0.id == id || $0.params["request_id"].string == id }
            chat.cards.append(PendingCard(id: id, method: event.type == "approval.request" ? "approval" : "clarify", params: p, viaRPC: true))
            chat.status = "等待你确认"
            if notificationsEnabled { notify?(chat.profile, bots.first(where: { $0.profile == chat.profile })?.name ?? chat.profile, "需要你确认") }
        case "approval.settled", "clarify.settled":
            chat.cards.removeAll { $0.id == p["prompt_id"].string || $0.params["request_id"].string == p["prompt_id"].string }
        case "message.start": finishStreaming("", chat: chat); chat.running = true; chat.status = "正在处理"; chat.activity.clear(); chat.activity.waiting()
        case "message.delta": if !p["text"].string.isEmpty { queueStreaming(p["text"].string, chat: chat) }
        case "message.interim": finishStreaming(p["text"].string, chat: chat); chat.activity.clear(); chat.revision += 1
        case "tool.start": finishStreaming("", chat: chat); chat.running = true; chat.status = "正在使用工具"; chat.activity.tool(p)
        case "tool.complete": if chat.running { chat.activity.tool(p, completed: true); chat.status = "正在处理" }
        case "tool.generating": if chat.running { chat.activity.status("正在准备工具", detail: p["name"].string) }
        case "reasoning.delta": if chat.running { chat.activity.reasoning(p["text"].string) }
        case "thinking.delta": if chat.running { chat.activity.thinking(p["text"].string) }
        case "agent.print": if chat.running, !p["text"].string.isEmpty { chat.activity.status("正在处理中", detail: p["text"].string) }
        case "message.complete":
            finishStreaming(p["text"].string, chat: chat); chat.running = false; chat.status = ""; chat.activity.clear(); chat.cards = []; chat.revision += 1
            if !p["error"].string.isEmpty { chat.error = p["error"].string }
            if selected != chat.profile { unread.insert(chat.profile) }
            if notificationsEnabled { notify?(chat.profile, bots.first(where: { $0.profile == chat.profile })?.name ?? chat.profile, String(p["text"].string.prefix(160))) }
            Task { [weak self] in await self?.open(profile: chat.profile, force: true) }
        case "session.info":
            chat.adoptModel(p)
            if !p["running"].isNull { chat.running = p["running"].bool; if !chat.running { chat.activity.clear() } }
            if !p["stored_session_id"].string.isEmpty { chat.storedID = p["stored_session_id"].string }
        case "session.updated": if ["", "applied", "committed", "deferred"].contains(p["status"].string) { chat.adoptModel(p) }
        case "session.reclaimed": finishStreaming("", chat: chat); chat.runtimeID = ""; chat.running = false; chat.activity.clear(); chat.error = "会话连接需要恢复，请点击重试"
        case "request.cancel", "approval.cancelled": chat.cards.removeAll { $0.id == p["id"].string || $0.id == p["request_id"].string || $0.id == p["prompt_id"].string }
        case "error": chat.error = p["message"].string; finishStreaming("", chat: chat); chat.running = false; chat.activity.clear(); chat.revision += 1
        case "status.update": if chat.running { chat.activity.status(p["kind"].string == "compacting" ? "正在整理上下文" : "正在处理中", detail: p["text"].string) }
        default: break
        }
    }
    /// Fixed write windows: a continuous stream cannot postpone the cache forever.
    public func cacheCurrentState() {
        guard !demo, cacheKey != nil, cacheTask == nil else { return }
        let owner = cacheOwner, epoch = connectionEpoch
        let request = UUID(); cacheWriteRequest = request
        cacheTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, self.cacheWriteRequest == request else { return }
            self.cacheTask = nil; self.cacheWriteRequest = nil
            guard !Task.isCancelled, self.connectionEpoch == epoch, self.cacheOwner == owner else { return }
            await self.flushCache()
        }
    }
    public func flushCache() async {
        guard !demo, let key = cacheKey else { return }
        cacheTask?.cancel(); cacheTask = nil; cacheWriteRequest = nil
        let owner = cacheOwner
        let chats = conversations.values.sorted { ($0.profile == selected ? 0 : 1, $0.profile) < ($1.profile == selected ? 0 : 1, $1.profile) }.prefix(16)
        let snapshots = chats.map { chat in
            ConversationSnapshot(profile: chat.profile, storedID: chat.storedID, messages: Array(chat.messages.reversed().lazy.filter { $0.role != "tool" }.prefix(240)).reversed().map { message in
                var copy = message
                if copy.delivery == .sending { copy.delivery = .uncertain }
                // Include any last buffered delta without changing layout during a cache write.
                if copy.id == chat.streamingID { copy.text += chat.pendingStreamText }
                copy.attachments = copy.attachments.compactMap { attachment in
                    var a = attachment; a.localURL = nil; a.imageData = nil; return a
                }
                return copy
            }, draft: chat.draft, scrollAnchor: chat.scrollAnchor, model: chat.model, provider: chat.provider)
        }
        await displayCache.save(WorkspaceSnapshot(bots: bots, selected: selected, conversations: snapshots), key: key, owner: owner)
    }
    public func search(_ query: String, chat: BotConversation) {
        chat.searchTask?.cancel(); chat.searchError = nil
        guard !query.isEmpty else { chat.searchResults = []; chat.searching = false; return }
        chat.searching = true
        chat.searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            if self.demo { chat.searchResults = chat.messages.filter { $0.text.localizedCaseInsensitiveContains(query) }; chat.searching = false; return }
            guard let api = self.transport, !chat.storedID.isEmpty else { chat.searching = false; return }
            do {
                var offset = 0, found: [ChatMessage] = []
                while !Task.isCancelled {
                    let result = try await api.request("/api/sessions/\(chat.storedID)/messages", profile: chat.profile, query: [.init(name: "limit", value: "500"), .init(name: "order", value: "latest"), .init(name: "offset", value: String(offset)), .init(name: "inline_images", value: "false")])
                    guard !Task.isCancelled else { return }
                    let rows = result["messages"].array
                    found += rows.enumerated().compactMap { ChatMessage.from($0.element, index: offset + $0.offset) }.filter { $0.role != "tool" && $0.text.localizedCaseInsensitiveContains(query) }
                    chat.searchResults = found; offset += rows.count
                    if rows.count < 500 { break }
                }
                chat.searching = false
            } catch { if !Task.isCancelled { chat.searchError = self.readable(error); chat.searching = false } }
        }
    }
    public func download(path: String, profile: String, to destination: URL) async throws {
        guard let api = transport else { throw ClientError.disconnected }
        let scoped = destination.startAccessingSecurityScopedResource()
        defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
        try await api.downloadFile(path: path, profile: profile, to: destination)
    }
    private func retire(_ chat: BotConversation) {
        chat.searchTask?.cancel(); chat.stagingTask?.cancel(); chat.streamFlushTask?.cancel()
        chat.pendingStreamText = ""; chat.activity.clear()
        for folder in chat.stagedFolders { try? FileManager.default.removeItem(at: folder) }
        chat.stagedFolders = []; chat.attachments = []
    }
    public func removeAttachment(_ id: String, from chat: BotConversation) {
        guard !chat.uploading, let item = chat.attachments.first(where: { $0.id == id }) else { return }
        chat.attachments.removeAll { $0.id == id }
        if let folder = item.localURL?.deletingLastPathComponent(), chat.stagedFolders.remove(folder) != nil {
            try? FileManager.default.removeItem(at: folder)
        }
    }
    @discardableResult public func stage(_ urls: [URL], for chat: BotConversation) -> Task<Void, Never>? {
        guard !chat.uploading, !chat.executingCommand, conversations[chat.profile] === chat else { return nil }
        chat.uploading = true
        let task = Task {
            defer { chat.uploading = false; chat.stagingTask = nil }
            for url in urls where url.isFileURL {
                guard !Task.isCancelled, conversations[chat.profile] === chat else { break }
                if chat.attachments.count >= 10 { chat.error = "一次最多添加 10 个附件"; break }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let item = try await Task.detached { () throws -> ChatAttachment in
                        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                        guard values.isDirectory != true else { throw ClientError.message("请添加文件，暂不支持文件夹") }
                        guard (values.fileSize ?? 0) <= 25 * 1024 * 1024 else { throw ClientError.message("单个附件不能超过 25 MB") }
                        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BotClient-Staged/\(UUID().uuidString)", isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        do {
                            let dest = folder.appendingPathComponent(url.lastPathComponent)
                            try FileManager.default.copyItem(at: url, to: dest)
                            let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
                            return ChatAttachment(name: url.lastPathComponent, localURL: dest, imageData: isImage ? try Data(contentsOf: dest) : nil, byteCount: values.fileSize)
                        } catch { try? FileManager.default.removeItem(at: folder); throw error }
                    }.value
                    guard !Task.isCancelled, conversations[chat.profile] === chat else {
                        if let folder = item.localURL?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: folder) }
                        break
                    }
                    if let folder = item.localURL?.deletingLastPathComponent() { chat.stagedFolders.insert(folder) }
                    chat.attachments.append(item)
                } catch { if !Task.isCancelled { chat.error = readable(error) } }
            }
        }
        chat.stagingTask = task
        return task
    }
    public func enterDemo() {
        cacheTask?.cancel(); cacheTask = nil
        let key = cacheKey, owner = cacheOwner
        Task { await displayCache.deactivate(owner: owner, key: key, remove: false) }
        cacheKey = nil; accountIdentity = nil; requiresLogin = false
        pinnedProfiles = defaults.stringArray(forKey: "pinned.demo") ?? []
        connectionEpoch += 1; credentialSaveTask?.cancel(); activeLogin = nil; activeRestore = nil; connecting = false
        pollTask?.cancel(); reconnectTask?.cancel()
        transport?.onEvent = nil; transport?.onRequest = nil; transport?.onCredentials = nil; transport?.onDisconnect = nil
        transport?.disconnect(); transport = nil
        conversations.values.forEach { retire($0) }
        conversations = [:]; selected = nil; unread = []; seen = [:]; lastActive = [:]
        unboundEvents = []; unboundCards = []; serverVersion = ""; loginError = nil
        demo = true; phase = .connected; banner = nil
        bots = [
            Bot(.object(["name": "hermes", "display_name": "Hermes", "description": "你的日常助手", "canonical_session": .object(["preview": "今天有什么想一起完成的？"])])),
            Bot(.object(["name": "product", "display_name": "产品助手", "description": "让想法变得清晰", "canonical_session": .object(["preview": "我把关键体验整理好了。"])])),
            Bot(.object(["name": "engineer", "display_name": "开发助手", "description": "专注实现与交付", "canonical_session": .object(["preview": "任务已完成，随时可以查看。"])]))
        ]
        let chat = conversation("hermes"); selected = "hermes"
        chat.messages = [ChatMessage(role: "assistant", text: "早上好。今天有什么想一起完成的？", timestamp: Date().addingTimeInterval(-600)), ChatMessage(role: "user", text: "我想做一个更简洁的 Mac 客户端，让每个 Bot 都像一个熟悉的联系人。", timestamp: Date().addingTimeInterval(-540)), ChatMessage(role: "assistant", text: "好，我们把注意力放回对话。\n\n左边是你的助手，右边是你们一直延续的消息。记忆与工作都留在远端 Hermes，打开这里，就能继续。", timestamp: Date().addingTimeInterval(-500))]
    }
    public func readable(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .appTransportSecurityRequiresSecureConnection: return "macOS 阻止了当前 HTTP 地址。请使用 HTTPS 网关；自建 HTTP 网关需在源码 Info.plist 中配置对应域名的 ATS 例外"
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .timedOut: return "暂时无法连接 Hermes，请检查网关地址、网络连接及网关运行状态"
            default: break
            }
        }
        return error.localizedDescription
    }
}
