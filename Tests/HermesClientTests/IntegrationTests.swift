import XCTest
@testable import HermesClient

@MainActor final class IntegrationTests: XCTestCase {
    func gateway(legacy: Bool = false) throws -> GatewayAddress {
        guard let raw = ProcessInfo.processInfo.environment["HERMES_FIXTURE_URL"] else { throw XCTSkip("本地合同网关未启动；见 README 的完整测试步骤") }
        return try GatewayAddress(raw + (legacy ? "/legacy" : ""))
    }
    func waitUntil(_ description: String, timeout: Double = 8, condition: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(condition(), description)
    }
    func testNativePasswordPKCEAndInvalidPassword() async throws {
        let address = try gateway()
        do { _ = try await GatewayTransport.login(address: address, username: "fixture", password: "wrong"); XCTFail("错误密码不能登录") }
        catch { XCTAssertNotNil(error as? ClientError) }
        let creds = try await GatewayTransport.login(address: address, username: "fixture", password: "fixture-password")
        XCTAssertEqual(creds.accessToken, "fixture-access")
        let api = GatewayTransport(address: address, credentials: creds)
        let me = try await api.request("/api/auth/me")
        XCTAssertEqual(me["user_id"].string, "fixture")
    }
    func testWebSocketProfileRoutingApprovalsClarifyPagingAndFileTransfer() async throws {
        let address = try gateway()
        let creds = try await GatewayTransport.login(address: address, username: "fixture", password: "fixture-password")
        let store = ChatStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try await store.establish(address: address, credentials: creds)
        defer { store.logout() }
        XCTAssertEqual(store.bots.count, 2)
        await store.select("writer")
        let chat = store.conversation("writer")
        XCTAssertEqual(chat.storedID, "writer-tip"); XCTAssertEqual(chat.runtimeID, "writer-runtime")
        XCTAssertEqual(chat.messages.count, 80); XCTAssertTrue(chat.hasOlder)
        await store.loadOlder(chat); await store.loadOlder(chat)
        XCTAssertGreaterThanOrEqual(chat.messages.count, 205, "分页应完整读取固定 Bot Chat 的全部历史")
        XCTAssertEqual(Set(chat.messages.map(\.id)).count, chat.messages.count, "相邻分页不能重复插入历史行")
        XCTAssertFalse(chat.hasOlder)
        XCTAssertTrue(chat.messages.first?.text.hasPrefix("writer 历史消息 1") == true)
        await store.select("ops")
        XCTAssertEqual(store.current?.storedID, "ops-tip")
        chat.draft = "测试审批"
        await store.send(chat)
        try await waitUntil("审批应路由到原 writer 对话") { !chat.cards.isEmpty }
        XCTAssertTrue(store.conversation("ops").cards.isEmpty)
        await store.open(profile: "writer", force: true)
        XCTAssertEqual(chat.cards.first?.method, "approval", "刷新历史必须恢复仍在等待的原生审批卡片")
        if let card = chat.cards.first { try await store.answer(card, chat: chat, result: .object(["choice": "once"])) }
        try await waitUntil("审批后应收到完整回复") { !chat.running && chat.messages.contains(where: { $0.text == "已完成：测试审批" }) }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(chat.messages.contains(where: { $0.text == "writer 历史消息 1" }), "刷新回复不能清掉已加载的较早历史")
        chat.draft = "测试提问"; await store.send(chat)
        try await waitUntil("补充问题卡片应出现") { chat.cards.first?.method == "clarify" }
        if let card = chat.cards.first { try await store.answer(card, chat: chat, result: .object(["answers": .object(["topic": "A"])])) }
        try await waitUntil("补充问题后完成") { !chat.running && chat.messages.contains(where: { $0.text == "已完成：测试提问" }) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("fixture attachment".utf8).write(to: file)
        store.stage([file], for: chat)
        try await waitUntil("附件应完成本地暂存") { !chat.uploading && !chat.attachments.isEmpty }
        chat.draft = "查看附件"; await store.send(chat)
        try await waitUntil("附件消息应往返完成") { !chat.running }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dest) }
        try await store.download(path: "/fixture/file.txt", profile: "writer", to: dest)
        XCTAssertEqual(try String(contentsOf: dest, encoding: .utf8), "fixture attachment")
        store.search("历史消息 1", chat: chat)
        try await waitUntil("应搜索当前 Bot 的全部历史") { !chat.searching }
        XCTAssertGreaterThan(chat.searchResults.count, 50)
        XCTAssertTrue(chat.searchResults.allSatisfy { $0.text.contains("writer") })
    }
    func testLegacyGatewayAndRequestTimeoutReleasePendingCall() async throws {
        let address = try gateway(legacy: true)
        let creds = try await GatewayTransport.login(address: address, username: "fixture", password: "fixture-password")
        let api = GatewayTransport(address: address, credentials: creds)
        try await api.connect(); defer { api.disconnect() }
        XCTAssertFalse(api.sessionAuthority)
        do { _ = try await api.call("test.no_response", timeout: 0.1); XCTFail("应超时") }
        catch { if case ClientError.timeout = error {} else { XCTFail("意外错误 \(error)") } }
        let pong = try await api.call("ping")
        XCTAssertTrue(pong["pong"].bool)
    }
    func testReconnectReadsAuthoritativeHistoryWithoutResending() async throws {
        let address = try gateway()
        let creds = try await GatewayTransport.login(address: address, username: "fixture", password: "fixture-password")
        let store = ChatStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try await store.establish(address: address, credentials: creds); defer { store.logout() }
        await store.select("writer")
        let chat = store.conversation("writer")
        let prompt = "断线恢复-" + UUID().uuidString
        chat.draft = prompt; await store.send(chat)
        try await waitUntil("断线后应恢复相同 Bot Chat 的最终消息", timeout: 12) { store.phase == .connected && chat.messages.contains(where: { $0.text == "已完成：" + prompt }) }
        XCTAssertEqual(chat.messages.filter { $0.role == "user" && $0.text == prompt }.count, 1)
        XCTAssertEqual(chat.storedID, "writer-tip")
    }
    func testWhitespaceAndRepeatedSendDoNotSubmitDuplicatePrompts() async throws {
        let address = try gateway()
        let creds = try await GatewayTransport.login(address: address, username: "fixture", password: "fixture-password")
        let store = ChatStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try await store.establish(address: address, credentials: creds); defer { store.logout() }
        await store.select("writer")
        let chat = store.conversation("writer")
        let api = GatewayTransport(address: address, credentials: creds)
        let before = try await api.request("/test/state")["log"].array.filter { $0["method"].string == "prompt.submit" }.count

        let priorUserMessages = chat.messages.filter { $0.role == "user" }.count
        chat.draft = " \n\t "
        await store.send(chat)
        XCTAssertEqual(chat.draft, " \n\t ", "空白输入应保留在编辑器中")
        XCTAssertEqual(chat.messages.filter { $0.role == "user" }.count, priorUserMessages)

        let prompt = "重复发送保护-" + UUID().uuidString
        chat.draft = prompt
        let firstSend = Task { await store.send(chat) }
        let repeatedSend = Task { await store.send(chat) }
        await firstSend.value
        await repeatedSend.value
        try await waitUntil("唯一一次提交应收到完整回复") { !chat.running && chat.messages.contains(where: { $0.text == "已完成：" + prompt }) }

        let after = try await api.request("/test/state")["log"].array.filter { $0["method"].string == "prompt.submit" }.count
        XCTAssertEqual(after - before, 1, "等待首次提交确认时的重复触发不能再次提交")
        XCTAssertEqual(chat.messages.filter { $0.role == "user" && $0.text == prompt }.count, 1)
    }
    func testModernGenerationFencedCardsAndSettlementOnAnotherClient() async throws {
        let address = try gateway()
        let creds = try await GatewayTransport.login(address: address, username: "fixture", password: "fixture-password")
        let store = ChatStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try await store.establish(address: address, credentials: creds); defer { store.logout() }
        await store.select("ops")
        let chat = store.conversation("ops")
        _ = try await store.transport?.call("test.controls", params: ["kind": "approval"], profile: "ops")
        try await waitUntil("现代审批事件应生成卡片") { chat.cards.contains(where: { $0.id == "modern-approval" }) }
        if let card = chat.cards.first { XCTAssertTrue(card.viaRPC); try await store.answer(card, chat: chat, result: .object(["choice": "once"])) }
        XCTAssertTrue(chat.cards.isEmpty)
        _ = try await store.transport?.call("test.controls", params: ["kind": "clarify"], profile: "ops")
        try await waitUntil("现代补充问题应生成卡片") { chat.cards.contains(where: { $0.id == "modern-clarify" }) }
        if let card = chat.cards.first { try await store.answer(card, chat: chat, result: .object(["answers": .object(["answer": "A"])])) }
        XCTAssertTrue(chat.cards.isEmpty)
        _ = try await store.transport?.call("test.controls", params: ["kind": "approval"], profile: "ops")
        _ = try await store.transport?.call("test.controls", params: ["kind": "approval", "settled": true], profile: "ops")
        try await waitUntil("其他客户端处理后卡片应撤回") { chat.cards.isEmpty }
    }
    func testTokenRefreshIsSharedAcrossConcurrentRequests() async throws {
        let address = try gateway()
        let valid = try await GatewayTransport.login(address: address, username: "fixture", password: "fixture-password")
        let baseline = try await GatewayTransport(address: address, credentials: valid).request("/test/state")["refreshes"].number ?? 0
        let expired = try Credentials(.object(["access_token": "expired", "refresh_token": "fixture-refresh", "expires_at": 0, "provider": "basic"]))
        let api = GatewayTransport(address: address, credentials: expired)
        async let a = api.request("/api/auth/me")
        async let b = api.request("/api/auth/me")
        async let c = api.request("/api/auth/me")
        let responses = try await [a, b, c]
        XCTAssertTrue(responses.allSatisfy { $0["user_id"].string == "fixture" })
        let state = try await api.request("/test/state")
        XCTAssertEqual(state["refreshes"].number, baseline + 1)
    }
    func testContextCommandsKeepDraftWhileBusyOrWhenCompressionFails() async throws {
        let address = try gateway()
        let creds = try await GatewayTransport.login(address: address, username: "fixture", password: "fixture-password")
        let store = ChatStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try await store.establish(address: address, credentials: creds); defer { store.logout() }
        await store.select("writer")
        let chat = store.conversation("writer")
        chat.running = true; chat.draft = "/new"
        await store.send(chat)
        XCTAssertEqual(chat.draft, "/new"); XCTAssertNotNil(chat.error)
        chat.running = false
        _ = try await store.transport?.call("test.fail_compress", profile: "writer")
        chat.draft = "/compact"; await store.send(chat)
        XCTAssertEqual(chat.draft, "/compact"); XCTAssertTrue(chat.error?.contains("compression failed") == true)
        await store.send(chat)
        XCTAssertEqual(chat.draft, ""); XCTAssertEqual(chat.storedID, "writer-tip")
    }
    func testChangingGatewayDoesNotCarryConversationDraftsToTheOtherHost() async throws {
        let address = try gateway(), secondAddress = try gateway(legacy: true)
        let creds = try await GatewayTransport.login(address: address, username: "fixture", password: "fixture-password")
        let store = ChatStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try await store.establish(address: address, credentials: creds); defer { store.logout() }
        await store.select("writer"); store.current?.draft = "只属于第一个网关"
        let first = store.conversation("writer")
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("只属于第一个网关的暂存附件".utf8).write(to: source)
        let switchStage = store.stage([source], for: first)
        try await store.establish(address: secondAddress, credentials: creds)
        await switchStage?.value
        XCTAssertFalse(store.conversation("writer") === first)
        XCTAssertEqual(store.conversation("writer").draft, "")
        XCTAssertTrue(store.conversation("writer").attachments.isEmpty, "切换网关后不能把旧网关暂存中的附件带入新会话")
        XCTAssertEqual(first.attachments.count, 0, "切换网关应取消旧会话的异步暂存")
        XCTAssertTrue(first.stagedFolders.isEmpty)

        let second = store.conversation("writer")
        let logoutStage = store.stage([source], for: second)
        store.addressText = secondAddress.url.absoluteString
        store.logout()
        await logoutStage?.value
        XCTAssertEqual(store.phase, .signedOut)
        XCTAssertTrue(store.conversations.isEmpty, "退出后的暂存不能重新填充客户端会话")
        XCTAssertEqual(second.attachments.count, 0, "退出应取消旧会话的异步暂存")
        XCTAssertTrue(second.stagedFolders.isEmpty)
    }
    func testCompletedStagingCleansCopiesOnRemovalAndLogoutWithoutDeletingSource() async throws {
        let address = try gateway()
        let creds = try await GatewayTransport.login(address: address, username: "fixture", password: "fixture-password")
        let store = ChatStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try await store.establish(address: address, credentials: creds); defer { store.logout() }
        await store.select("writer")
        let chat = store.conversation("writer")
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data("fixture source must remain".utf8).write(to: source)

        let removalStage = store.stage([source], for: chat)
        await removalStage?.value
        XCTAssertEqual(chat.attachments.count, 1)
        let removedCopy = try XCTUnwrap(chat.attachments.first?.localURL)
        let removedFolder = removedCopy.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: removedCopy.path))
        store.removeAttachment(chat.attachments[0].id, from: chat)
        XCTAssertTrue(chat.attachments.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedFolder.path), "移除附件应删除客户端创建的暂存目录")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "移除暂存副本不能删除用户源文件")

        let logoutStage = store.stage([source], for: chat)
        await logoutStage?.value
        let logoutCopy = try XCTUnwrap(chat.attachments.first?.localURL)
        let logoutFolder = logoutCopy.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: logoutCopy.path))
        store.addressText = address.url.absoluteString
        store.logout()
        XCTAssertFalse(FileManager.default.fileExists(atPath: logoutFolder.path), "退出应清理已完成暂存创建的目录")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "退出清理不能删除用户源文件")
    }
    func testMissingCompletionEventDoesNotLeaveBotWorkingForever() async throws {
        let address = try gateway()
        let creds = try await GatewayTransport.login(address: address, username: "fixture", password: "fixture-password")
        let store = ChatStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try await store.establish(address: address, credentials: creds); defer { store.logout() }
        await store.select("writer")
        let chat = store.conversation("writer")
        _ = try await store.transport?.call("test.silent_finish", profile: "writer")
        try await waitUntil("运行事件应出现") { chat.running }
        try await waitUntil("没有新消息或完成事件也应恢复服务器的空闲状态", timeout: 10) { !chat.running }
        XCTAssertEqual(chat.storedID, "writer-tip")
    }
    func testReplyFromUnopenedBotCanNotifyWithoutStartingItsRuntime() async throws {
        let address = try gateway()
        let creds = try await GatewayTransport.login(address: address, username: "fixture", password: "fixture-password")
        let store = ChatStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try await store.establish(address: address, credentials: creds); defer { store.logout() }
        XCTAssertNil(store.conversations["ops"])
        var profiles: [String] = []
        store.notificationsEnabled = true; store.notify = { profile, _, _ in profiles.append(profile) }
        _ = try await store.transport?.call("test.external_reply", profile: "ops")
        try await store.loadBots()
        try await waitUntil("未打开的助手有后台回复也应通知") { profiles.contains("ops") }
        XCTAssertNil(store.conversations["ops"], "通知不应启动这个 Bot 的会话运行时")
    }
    func testInitialSocketFailureReturnsToLoginWithoutBackgroundReconnectLoop() async throws {
        let address = try gateway()
        let creds = try await GatewayTransport.login(address: address, username: "fixture", password: "fixture-password")
        let api = GatewayTransport(address: address, credentials: creds)
        let before = try await api.request("/test/state")["socket_attempts"].number ?? 0
        let store = ChatStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        defer { store.logout() }
        do { try await store.establish(address: GatewayAddress(address.url.absoluteString + "/reject"), credentials: creds); XCTFail("连接应失败") }
        catch { XCTAssertEqual(store.phase, .signedOut) }
        try await Task.sleep(for: .milliseconds(350))
        let after = try await api.request("/test/state")["socket_attempts"].number ?? 0
        XCTAssertEqual(after, before + 1)
        XCTAssertEqual(store.phase, .signedOut)
    }
    func testFullLegacyConversationCanSendAndStreamOnTheSameBotChat() async throws {
        let address = try gateway(legacy: true)
        let creds = try await GatewayTransport.login(address: address, username: "fixture", password: "fixture-password")
        let store = ChatStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        try await store.establish(address: address, credentials: creds); defer { store.logout() }
        await store.select("ops")
        let chat = store.conversation("ops")
        XCTAssertFalse(store.transport?.sessionAuthority ?? true)
        chat.draft = "旧协议原生消息验证"; await store.send(chat)
        try await waitUntil("旧协议也应完成同一 Bot Chat 的流式回复") { !chat.running && chat.messages.contains(where: { $0.text == "已完成：旧协议原生消息验证" }) }
        XCTAssertEqual(chat.storedID, "ops-tip")
    }
}
