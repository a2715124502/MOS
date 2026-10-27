import XCTest
@testable import HermesClient

final class ContractTests: XCTestCase {
    func testGatewayAddressKeepsReverseProxyPrefixAndRejectsEmbeddedCredentials() throws {
        let a = try GatewayAddress("https://example.org/hermes/api/status?token=not-kept")
        XCTAssertEqual(a.endpoint("/api/ws", query: [.init(name: "ticket", value: "a+b/")]).absoluteString, "https://example.org/hermes/api/ws?ticket=a+b/")
        XCTAssertThrowsError(try GatewayAddress("https://username:password@example.org"))
        XCTAssertThrowsError(try GatewayAddress("file:///tmp"))
        XCTAssertEqual(try GatewayAddress("192.0.2.1:9119").url.absoluteString, "http://192.0.2.1:9119")
    }
    func testCanonicalRegistryNeverFallsBackToLatestSessionOrLegacyPointer() {
        let rows: [JSON] = [.object(["id": "latest", "title": "其他对话"]), .object(["id": "root", "root_title": "Bot Chat", "title": "compressed", "resolved_id": "tip"])]
        XCTAssertEqual(Bot.canonical(from: rows)?["resolved_id"].string, "tip")
        XCTAssertNil(Bot.canonical(from: [rows[0]]))
        let bot = Bot(.object(["name": "ops", "ui_meta": .object(["hermes-bots": .object(["chat": "wrong"])]), "last_session": .object(["id": "latest"])]))
        XCTAssertTrue(bot.canonicalID.isEmpty)
    }
    func testBotUsesCanonicalPreviewEvenWhenOtherSessionsExist() {
        let bot = Bot(.object(["name": "ops", "display_name": "运维", "canonical_session": .object(["id": "root", "resolved_id": "tip", "preview": "固定会话", "last_active": 123]), "last_session": .object(["preview": "其他会话"])]))
        XCTAssertEqual(bot.name, "运维"); XCTAssertEqual(bot.preview, "固定会话"); XCTAssertEqual(bot.resolvedID, "tip")
    }
    func testHistoryDoesNotExposeReasoningOrHiddenMessages() {
        XCTAssertNil(ChatMessage.from(.object(["role": "assistant", "reasoning": "不要显示", "content": ""])))
        XCTAssertNil(ChatMessage.from(.object(["role": "user", "display_kind": "hidden", "content": "隐藏消息"])))
        XCTAssertNil(ChatMessage.from(.object(["role": "assistant", "text": "NO_REPLY"])))
        let row = ChatMessage.from(.object(["role": "assistant", "id": 25, "timestamp": 1700000000, "content": .array([.object(["type": "text", "text": "最终回复"])]), "reasoning": "内部思考"]))
        XCTAssertEqual(row?.text, "最终回复"); XCTAssertEqual(row?.id, "row-25")
    }
    func testCredentialsRotationKeepsRefreshWhenOmitted() throws {
        let old = try Credentials(.object(["access_token": "old", "refresh_token": "refresh", "provider": "basic"]))
        let new = try Credentials(.object(["access_token": "new"]), previous: old)
        XCTAssertEqual(new.refreshToken, "refresh"); XCTAssertEqual(new.provider, "basic")
    }
    func testJSONKeepsRPCIDTypesAndNulls() throws {
        let v = try JSON.parse(Data(#"{"id":"request-1","params":{"flag":true,"num":42,"none":null}}"#.utf8))
        XCTAssertEqual(v["id"].string, "request-1"); XCTAssertTrue(v["params"]["flag"].bool)
        XCTAssertEqual(v["params"]["num"].number, 42); XCTAssertTrue(v["params"]["none"].isNull)
        XCTAssertEqual(try JSON.parse(Data(v.text.utf8)), v)
    }
}
