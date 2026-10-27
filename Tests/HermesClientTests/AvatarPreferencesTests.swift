import Foundation
import XCTest
@testable import HermesClient

@MainActor final class AvatarPreferencesTests: XCTestCase {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "AvatarTests.\(UUID().uuidString)")!
    }
    func testSavedStyleSurvivesRelaunchAndKeepsOtherBotUnchanged() {
        let defaults = defaults(), first = AvatarLibrary(defaults: defaults)
        let writer = AvatarLibrary.key(gateway: "http://127.0.0.1:9119", user: "alice", profile: "writer")
        let ops = AvatarLibrary.key(gateway: "http://127.0.0.1:9119", user: "alice", profile: "ops")
        let prior = first.style(for: ops, profile: "ops")
        let chosen = AvatarStyle(shape: .heart, color: .pink, expression: .wink, animated: false, seed: UInt64.max)
        first.set(chosen, for: writer)
        let reopened = AvatarLibrary(defaults: defaults)
        XCTAssertEqual(reopened.style(for: writer, profile: "writer"), chosen)
        XCTAssertEqual(reopened.style(for: ops, profile: "ops"), prior)
    }
    func testNamespaceSeparatesProfilesUsersGatewaysAndTupleBoundaries() {
        let key = AvatarLibrary.key
        let a = key("http://a:9119", "a", "b|c")
        XCTAssertNotEqual(a, key("http://a:9119", "a|b", "c"))
        XCTAssertNotEqual(a, key("http://a:9119", "b", "b|c"))
        XCTAssertNotEqual(a, key("http://b:9119", "a", "b|c"))
        XCTAssertNotEqual(a, key("http://a:9120", "a", "b|c"))
        XCTAssertEqual(a, key("a:9119/", "a", "b|c"))
    }
    func testCorruptEntryDoesNotEraseValidBots() throws {
        let defaults = defaults()
        let chosen = AvatarStyle.collection[3]
        defaults.set(["good": try JSONEncoder().encode(chosen), "bad": Data("{broken".utf8)], forKey: "botAvatarStyles.v1")
        let library = AvatarLibrary(defaults: defaults)
        XCTAssertEqual(library.style(for: "good", profile: "good"), chosen)
        XCTAssertEqual(library.style(for: "bad", profile: "bad"), .defaultStyle(profile: "bad"))
        library.set(.collection[5], for: "new")
        XCTAssertEqual(AvatarLibrary(defaults: defaults).style(for: "good", profile: "good"), chosen)
    }
    func testResetOnlyClearsChosenBot() {
        let defaults = defaults(), library = AvatarLibrary(defaults: defaults)
        library.set(.collection[0], for: "writer"); library.set(.collection[1], for: "ops")
        library.reset("writer")
        let reopened = AvatarLibrary(defaults: defaults)
        XCTAssertEqual(reopened.style(for: "writer", profile: "writer"), .defaultStyle(profile: "writer"))
        XCTAssertEqual(reopened.style(for: "ops", profile: "ops"), .collection[1])
    }
    func testDeterministicDefaultsAndGenerationAcrossFullSeedRange() throws {
        for seed: UInt64 in [0, 1, UInt64.max, 0x8000000000000000] {
            let style = AvatarStyle.generated(seed: seed)
            XCTAssertEqual(style, .generated(seed: seed))
            XCTAssertEqual(try JSONDecoder().decode(AvatarStyle.self, from: JSONEncoder().encode(style)), style)
        }
        XCTAssertEqual(AvatarStyle.defaultStyle(profile: "写作助手"), .defaultStyle(profile: "写作助手"))
        XCTAssertGreaterThan(Set((0 ..< 100).map { AvatarStyle.generated(seed: UInt64($0)).color }).count, 5)
        XCTAssertGreaterThan(Set((0 ..< 100).map { AvatarStyle.generated(seed: UInt64($0)).shape }).count, 5)
    }
    func testPreviewDraftDoesNotPersistUntilSave() {
        let defaults = defaults(), library = AvatarLibrary(defaults: defaults)
        let before = library.style(for: "writer", profile: "writer")
        var draft = before; draft.color = .pink; draft.animated = false
        XCTAssertEqual(AvatarLibrary(defaults: defaults).style(for: "writer", profile: "writer"), before)
        draft.source = .server
        library.set(draft, for: "writer")
        XCTAssertEqual(AvatarLibrary(defaults: defaults).style(for: "writer", profile: "writer").source, .server)
        XCTAssertFalse(AvatarLibrary(defaults: defaults).style(for: "writer", profile: "writer").animated)
    }
}
