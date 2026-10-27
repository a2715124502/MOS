import Foundation
import XCTest
@testable import HermesClient

@MainActor private final class AuditCredentialStorage: CredentialStorage {
    func read(_ account: String) async throws -> Credentials? { nil }
    func save(_ credentials: Credentials, account: String) async throws {}
    func delete(_ account: String) {}
}

@MainActor final class AvatarAuditTests: XCTestCase {
    func testOneNonDataPreferenceCannotDiscardOtherBotsSavedAvatars() throws {
        let domain = "AvatarAuditTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let gateway = "http://127.0.0.1:19201"
        let writer = AvatarLibrary.key(gateway: gateway, user: "fixture", profile: "writer")
        let ops = AvatarLibrary.key(gateway: gateway, user: "fixture", profile: "ops")
        let chosen = AvatarStyle.collection[4]
        let encoded = try JSONEncoder().encode(chosen)
        // Simulate one malformed/older preference beside a valid current entry.
        defaults.set([writer: encoded, ops: "not encoded AvatarStyle"] as [String: Any], forKey: "botAvatarStyles.v1")
        let library = AvatarLibrary(defaults: defaults)
        XCTAssertEqual(library.style(for: writer, profile: "writer"), chosen, "单个非 Data 条目不能让其他 Bot 的有效头像回退为默认")
        library.set(.collection[2], for: ops)
        XCTAssertEqual(AvatarLibrary(defaults: defaults).style(for: writer, profile: "writer"), chosen, "保存另一个 Bot 的头像不能把未加载的有效条目永久抹掉")
    }

    func testDemoChosenDuringLoginReleasesTheLiveGatewayConnection() async throws {
        guard let raw = ProcessInfo.processInfo.environment["HERMES_FIXTURE_URL"] else {
            throw XCTSkip("本项审核需要本机 HTTP/WS fixture")
        }
        let domain = "AvatarAuditTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(raw, forKey: "gateway"); defaults.set("fixture", forKey: "username")
        let store = ChatStore(defaults: defaults, credentials: AuditCredentialStorage())
        defer { store.logout() }
        let login = Task { await store.login(password: "fixture-password") }
        defer { login.cancel() }
        let end = Date().addingTimeInterval(6)
        while store.phase != .connecting, Date() < end { try await Task.sleep(for: .milliseconds(5)) }
        guard store.phase == .connecting else { XCTFail("未进入登录连接阶段"); return }
        store.enterDemo()
        await login.value
        XCTAssertTrue(store.demo)
        XCTAssertEqual(store.selected, "hermes")
        XCTAssertFalse(store.transport?.ready ?? false, "界面已声明示例模式时，已取消登录的网关 WebSocket 不能继续保持活动")
    }
}
