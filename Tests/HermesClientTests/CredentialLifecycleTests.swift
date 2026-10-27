import Foundation
import XCTest
@testable import HermesClient

/// Deliberately ignores cancellation once enqueued, like an in-flight Security call.
/// Reads, saves and synchronous delete-enqueues complete in FIFO order.
@MainActor private final class DelayedCredentialStorage: CredentialStorage {
    private enum Kind { case read, save, delete }
    private struct Pending { let kind: Kind; let complete: () -> Void }
    private var pending: [Pending] = []
    var values: [String: Credentials] = [:]
    var holdReads = false
    var holdSaves = false
    var preserveOnDelete = false
    var readFailure: Error?
    var saveFailure: Error?
    private(set) var readAccounts: [String] = []
    private(set) var saveAccounts: [String] = []
    private(set) var deleteAccounts: [String] = []
    private(set) var completed: [String] = []
    var pendingCount: Int { pending.count }

    func read(_ account: String) async throws -> Credentials? {
        readAccounts.append(account)
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(kind: .read) {
                self.completed.append("read")
                if let error = self.readFailure { continuation.resume(throwing: error) }
                else { continuation.resume(returning: self.values[account]) }
            })
            drain()
        }
    }
    func save(_ credentials: Credentials, account: String) async throws {
        saveAccounts.append(account)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pending.append(Pending(kind: .save) {
                self.completed.append("save")
                if let error = self.saveFailure { continuation.resume(throwing: error) }
                else { self.values[account] = credentials; continuation.resume() }
            })
            drain()
        }
    }
    func delete(_ account: String) {
        deleteAccounts.append(account)
        pending.append(Pending(kind: .delete) {
            self.completed.append("delete")
            if !self.preserveOnDelete { self.values[account] = nil }
        })
        drain()
    }
    func releaseReads() { holdReads = false; drain() }
    func releaseSaves() { holdSaves = false; drain() }
    func finishAll() { holdReads = false; holdSaves = false; drain() }
    private func drain() {
        while let first = pending.first {
            if first.kind == .read && holdReads || first.kind == .save && holdSaves { return }
            pending.removeFirst().complete()
        }
    }
}

@MainActor final class CredentialLifecycleTests: XCTestCase {
    private typealias Context = (store: ChatStore, vault: DelayedCredentialStorage, defaults: UserDefaults, address: GatewayAddress, domain: String)
    private func fixtureCredentials(access: String = "fixture-access", refresh: String = "fixture-refresh") throws -> Credentials {
        try Credentials(.object(["access_token": .string(access), "refresh_token": .string(refresh), "provider": "basic"]))
    }
    private func context(suffix: String = "") throws -> Context {
        guard let raw = ProcessInfo.processInfo.environment["HERMES_FIXTURE_URL"] else {
            throw XCTSkip("Credential 生命周期测试需要本机 HTTP/WS fixture")
        }
        let address = try GatewayAddress(raw + suffix)
        let domain = "CredentialLifecycleTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(address.url.absoluteString, forKey: "gateway")
        defaults.set("fixture", forKey: "username")
        let vault = DelayedCredentialStorage()
        vault.values[address.key] = try fixtureCredentials()
        return (ChatStore(defaults: defaults, credentials: vault), vault, defaults, address, domain)
    }
    private func cleanup(_ c: Context) {
        c.store.logout(); c.vault.finishAll(); c.defaults.removePersistentDomain(forName: c.domain)
    }
    private func waitUntil(_ message: String, condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(6)
        while !condition(), Date() < end { try await Task.sleep(for: .milliseconds(5)) }
        guard condition() else { XCTFail(message); throw ClientError.timeout(message) }
    }
    private func socketAttempts(_ c: Context) async throws -> Double {
        let api = GatewayTransport(address: c.address, credentials: try fixtureCredentials())
        return try await api.request("/test/state")["socket_attempts"].number ?? 0
    }
    private func assertSignedOut(_ store: ChatStore, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(store.phase, .signedOut, file: file, line: line)
        XCTAssertFalse(store.connecting, file: file, line: line)
        XCTAssertNil(store.transport, file: file, line: line)
        XCTAssertTrue(store.conversations.isEmpty, file: file, line: line)
    }

    func testSlowRestoreLeavesMainActorResponsiveAndDoesNotDuplicateRead() async throws {
        let c = try context(); defer { cleanup(c) }
        c.vault.holdReads = true
        let restoring = Task { await c.store.restore() }
        try await waitUntil("restore 应进入可挂起的凭据读取") { c.vault.readAccounts.count == 1 }
        let mainActorPulse = Task { @MainActor in c.store.filter = "主线程仍可运行"; return true }
        let pulseRan = await mainActorPulse.value
        XCTAssertTrue(pulseRan); XCTAssertEqual(c.store.filter, "主线程仍可运行")
        XCTAssertEqual(c.store.phase, .signedOut)
        await c.store.restore()
        XCTAssertEqual(c.vault.readAccounts, [c.address.key], "并发 restore 不应重复排队读取")
        c.vault.releaseReads()
        await restoring.value
        XCTAssertEqual(c.store.phase, .connected)
        XCTAssertEqual(c.store.bots.count, 2)
    }

    func testLogoutRejectsLateReadAndDisablesRestoreEvenIfDeleteRetainsOldCredentials() async throws {
        let c = try context(); defer { cleanup(c) }
        c.vault.holdReads = true; c.vault.preserveOnDelete = true
        let before = try await socketAttempts(c)
        let restoring = Task { await c.store.restore() }
        try await waitUntil("读取应等待释放") { c.vault.readAccounts.count == 1 }
        c.store.logout()
        assertSignedOut(c.store)
        XCTAssertTrue(c.defaults.bool(forKey: "disableRestore." + c.address.key), "退出必须同步禁止后续自动恢复")
        XCTAssertEqual(c.vault.deleteAccounts, [c.address.key])
        c.vault.releaseReads()
        await restoring.value
        assertSignedOut(c.store)
        XCTAssertNotNil(c.vault.values[c.address.key], "此假存储模拟钥匙串删除失败")
        let relaunched = ChatStore(defaults: c.defaults, credentials: c.vault)
        await relaunched.restore()
        XCTAssertEqual(c.vault.readAccounts.count, 1, "新实例必须在读取旧令牌前拒绝恢复")
        assertSignedOut(relaunched)
        let after = try await socketAttempts(c)
        XCTAssertEqual(after, before)
    }

    func testEnteringDemoRejectsLateCredentialRead() async throws {
        let c = try context(); defer { cleanup(c) }
        c.vault.holdReads = true
        let before = try await socketAttempts(c)
        let restoring = Task { await c.store.restore() }
        try await waitUntil("读取应等待释放") { c.vault.readAccounts.count == 1 }
        c.store.enterDemo()
        c.vault.releaseReads()
        await restoring.value
        XCTAssertTrue(c.store.demo); XCTAssertEqual(c.store.phase, .connected)
        XCTAssertEqual(c.store.selected, "hermes"); XCTAssertNil(c.store.transport)
        XCTAssertEqual(c.vault.saveAccounts.count, 0)
        let after = try await socketAttempts(c)
        XCTAssertEqual(after, before, "示例模式不能因迟到读取启动真实连接")
    }

    func testAuthenticatedLoginCompletesWhileSavingIsSuspendedAndOnlySuccessEnablesRestore() async throws {
        let c = try context(); defer { cleanup(c) }
        c.vault.holdSaves = true
        let login = Task { await c.store.login(password: "fixture-password") }
        try await waitUntil("已认证会话不能等待慢钥匙串才能连接") { c.store.phase == .connected && !c.store.connecting }
        await login.value
        try await waitUntil("凭据保存应已在后台排队") { c.vault.saveAccounts.count == 1 }
        XCTAssertEqual(c.store.bots.count, 2)
        XCTAssertTrue(c.defaults.bool(forKey: "disableRestore." + c.address.key))
        XCTAssertEqual(c.vault.pendingCount, 1)
        c.vault.releaseSaves()
        try await waitUntil("只有当前保存成功后才能允许恢复") { !c.defaults.bool(forKey: "disableRestore." + c.address.key) }
        XCTAssertEqual(c.vault.values[c.address.key]?.accessToken, "fixture-access")
    }

    func testSaveFailureKeepsAuthenticatedConnectionAndBlocksOldKeychainRestore() async throws {
        let c = try context(); defer { cleanup(c) }
        c.vault.values[c.address.key] = try fixtureCredentials(access: "old-keychain-token", refresh: "")
        c.vault.saveFailure = ClientError.message("fixture keychain locked")
        await c.store.login(password: "fixture-password")
        try await waitUntil("保存失败稍后应显示可理解的提示") { c.store.banner?.contains("未能保存") == true }
        XCTAssertEqual(c.store.phase, .connected); XCTAssertFalse(c.store.connecting)
        XCTAssertNil(c.store.loginError)
        XCTAssertTrue(c.defaults.bool(forKey: "disableRestore." + c.address.key))
        XCTAssertEqual(c.vault.values[c.address.key]?.accessToken, "old-keychain-token")
        let relaunched = ChatStore(defaults: c.defaults, credentials: c.vault)
        await relaunched.restore()
        assertSignedOut(relaunched)
        XCTAssertTrue(c.vault.readAccounts.isEmpty, "保存失败不能重新启用旧钥匙串令牌")
        let me = try await c.store.transport?.request("/api/auth/me")
        XCTAssertEqual(me?["user_id"].string, "fixture")
    }

    func testQueuedReadSaveAndDeleteCannotReviveLoggedOutSessionOrClearRestoreBlock() async throws {
        let c = try context(); defer { cleanup(c) }
        c.vault.holdReads = true; c.vault.holdSaves = true
        let restoring = Task { await c.store.restore() }
        try await waitUntil("旧 restore 读取应排队") { c.vault.readAccounts.count == 1 }
        await c.store.login(password: "fixture-password")
        try await waitUntil("登录保存应排在旧读取后面") { c.vault.saveAccounts.count == 1 }
        c.store.logout()
        assertSignedOut(c.store)
        XCTAssertTrue(c.defaults.bool(forKey: "disableRestore." + c.address.key))
        XCTAssertEqual(c.vault.pendingCount, 3)
        c.vault.releaseReads()
        await restoring.value
        assertSignedOut(c.store)
        c.vault.releaseSaves()
        try await waitUntil("串行删除最终应完成") { c.vault.completed.last == "delete" }
        await Task.yield()
        XCTAssertEqual(c.vault.completed, ["read", "save", "delete"])
        XCTAssertNil(c.vault.values[c.address.key])
        XCTAssertTrue(c.defaults.bool(forKey: "disableRestore." + c.address.key), "迟到的保存成功不得撤销 logout 标记")
        XCTAssertNil(c.store.banner); XCTAssertNil(c.store.loginError)
        assertSignedOut(c.store)
        await c.store.restore()
        XCTAssertEqual(c.vault.readAccounts.count, 1)
    }

    func testLateRefreshSaveFailureAfterLogoutDoesNotPublishBanner() async throws {
        let c = try context(); defer { cleanup(c) }
        try await c.store.establish(address: c.address, credentials: fixtureCredentials())
        c.vault.holdSaves = true
        c.vault.saveFailure = ClientError.message("fixture late save failure")
        c.store.transport?.onCredentials?(try fixtureCredentials(access: "fixture-rotated"))
        try await waitUntil("刷新凭据保存应已启动") { c.vault.saveAccounts.count == 1 }
        c.store.logout()
        c.vault.releaseSaves()
        try await waitUntil("旧保存和删除应完成") { c.vault.pendingCount == 0 }
        await Task.yield()
        assertSignedOut(c.store)
        XCTAssertNil(c.store.banner)
        XCTAssertTrue(c.defaults.bool(forKey: "disableRestore." + c.address.key))
    }

    func testOldTransportCredentialCallbackIsIgnoredAfterNewLogin() async throws {
        let c = try context(); defer { cleanup(c) }
        try await c.store.establish(address: c.address, credentials: fixtureCredentials())
        let oldCallback = try XCTUnwrap(c.store.transport?.onCredentials)
        c.store.logout()
        await c.store.login(password: "fixture-password")
        try await waitUntil("新登录凭据应已保存") { c.vault.saveAccounts.count == 1 && !c.defaults.bool(forKey: "disableRestore." + c.address.key) }
        oldCallback(try fixtureCredentials(access: "stale-transport-token"))
        await Task.yield()
        XCTAssertEqual(c.vault.saveAccounts.count, 1)
        XCTAssertEqual(c.vault.values[c.address.key]?.accessToken, "fixture-access")
        XCTAssertEqual(c.store.phase, .connected)
    }

    func testMissingOrUnreadableCredentialsStayOnLoginPage() async throws {
        let c = try context(); defer { cleanup(c) }
        c.vault.values = [:]
        await c.store.restore()
        assertSignedOut(c.store); XCTAssertNil(c.store.loginError)
        c.vault.readFailure = ClientError.message("fixture read denied")
        await c.store.restore()
        assertSignedOut(c.store)
        XCTAssertTrue(c.store.loginError?.contains("fixture read denied") == true)
    }

    func testWrongPasswordReturnsVisibleErrorAndAllowsManualRetry() async throws {
        let c = try context(); defer { cleanup(c) }
        await c.store.login(password: "wrong")
        XCTAssertEqual(c.store.phase, .signedOut); XCTAssertFalse(c.store.connecting)
        XCTAssertNotNil(c.store.loginError); XCTAssertTrue(c.vault.saveAccounts.isEmpty)
        await c.store.login(password: "fixture-password")
        XCTAssertEqual(c.store.phase, .connected); XCTAssertNil(c.store.loginError)
        try await waitUntil("重试登录凭据应保存") { !c.vault.saveAccounts.isEmpty }
    }

    func testRejectedSocketDuringLoginShowsErrorOnLoginPage() async throws {
        let c = try context(suffix: "/reject"); defer { cleanup(c) }
        await c.store.login(password: "fixture-password")
        XCTAssertEqual(c.store.phase, .signedOut); XCTAssertFalse(c.store.connecting)
        XCTAssertNotNil(c.store.loginError, "认证后建立连接失败也应有可见错误，不能静默返回登录页")
        XCTAssertTrue(c.vault.saveAccounts.isEmpty)
    }

    func testUnauthorizedRestoredCredentialsShowErrorOnLoginPage() async throws {
        let c = try context(); defer { cleanup(c) }
        c.vault.values[c.address.key] = try fixtureCredentials(access: "invalid-access", refresh: "")
        await c.store.restore()
        XCTAssertEqual(c.store.phase, .signedOut)
        XCTAssertNotNil(c.store.loginError, "旧令牌被拒绝时必须告知用户重新登录")
    }

    func testEnteringDemoDuringLoginCannotPersistLateAuthenticatedCredentials() async throws {
        let c = try context(); defer { cleanup(c) }
        let login = Task { await c.store.login(password: "fixture-password") }
        try await waitUntil("登录应进入远程会话连接阶段") { c.store.phase == .connecting }
        c.store.enterDemo()
        await login.value
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(c.store.demo); XCTAssertEqual(c.store.selected, "hermes")
        XCTAssertFalse(c.store.connecting)
        XCTAssertTrue(c.vault.saveAccounts.isEmpty, "已取消的登录不能在 demo epoch 中保存真实凭据")
        XCTAssertTrue(c.defaults.bool(forKey: "disableRestore." + c.address.key), "demo 后迟到保存不得重新启用自动恢复")
    }
}
