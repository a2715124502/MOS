import Foundation
import CryptoKit
import Observation

public enum AvatarShape: String, Codable, CaseIterable, Sendable {
    case pebble, squircle, triangle, flower, star, heart, cloud, circle
    public var title: String {
        switch self {
        case .pebble: return "软糖"
        case .squircle: return "方块"
        case .triangle: return "山丘"
        case .flower: return "小花"
        case .star: return "星星"
        case .heart: return "爱心"
        case .cloud: return "云朵"
        case .circle: return "圆圆"
        }
    }
}
public enum AvatarColor: String, Codable, CaseIterable, Sendable {
    case vermilion, yellow, violet, pink, charcoal, orange, green, blue, mint, slate
    public var title: String {
        switch self {
        case .vermilion: return "朱红"
        case .yellow: return "明黄"
        case .violet: return "紫罗兰"
        case .pink: return "桃粉"
        case .charcoal: return "墨黑"
        case .orange: return "橘子"
        case .green: return "草绿"
        case .blue: return "湛蓝"
        case .mint: return "薄荷"
        case .slate: return "雾灰"
        }
    }
    public var rgb: UInt32 {
        switch self {
        case .vermilion: return 0xFF4B26
        case .yellow: return 0xFFD51A
        case .violet: return 0x8847FA
        case .pink: return 0xFA6299
        case .charcoal: return 0x24252A
        case .orange: return 0xFF920E
        case .green: return 0x13C96A
        case .blue: return 0x137DF4
        case .mint: return 0x54D7BC
        case .slate: return 0x96979E
        }
    }
}
public enum AvatarExpression: String, Codable, CaseIterable, Sendable {
    case curious, cheerful, sleepy, wink, sparkle
    public var title: String {
        switch self {
        case .curious: return "好奇"
        case .cheerful: return "开心"
        case .sleepy: return "慵懒"
        case .wink: return "眨眨眼"
        case .sparkle: return "星星眼"
        }
    }
}
public enum AvatarSource: String, Codable, Sendable { case character, server }

public enum AvatarKind: String, Codable, CaseIterable, Sendable {
    case girl, geometric
    public var title: String { self == .girl ? "复古漫画" : "几何伙伴" }
}
public enum GirlHairstyle: String, Codable, CaseIterable, Sendable {
    case bob, pixie, long, ponytail, bun, waves
    public var title: String {
        switch self {
        case .bob: return "短波波"
        case .pixie: return "清爽短发"
        case .long: return "长直发"
        case .ponytail: return "高马尾"
        case .bun: return "丸子头"
        case .waves: return "微卷长发"
        }
    }
}
public enum GirlFacing: String, Codable, CaseIterable, Sendable {
    case left, front, right
    public var title: String { self == .front ? "正面" : self == .left ? "朝左" : "朝右" }
}

public struct AvatarStyle: Codable, Equatable, Sendable {
    public var kind: AvatarKind
    public var hairstyle: GirlHairstyle
    public var facing: GirlFacing
    public var shape: AvatarShape
    public var color: AvatarColor
    public var expression: AvatarExpression
    public var animated: Bool
    public var seed: UInt64
    public var source: AvatarSource
    public init(shape: AvatarShape = .pebble, color: AvatarColor = .charcoal,
                expression: AvatarExpression = .curious, animated: Bool = true,
                seed: UInt64 = 0, source: AvatarSource = .character, kind: AvatarKind = .girl,
                hairstyle: GirlHairstyle = .bob, facing: GirlFacing = .front) {
        self.kind = kind; self.hairstyle = hairstyle; self.facing = facing
        self.shape = shape; self.color = color; self.expression = expression
        self.animated = animated; self.seed = seed; self.source = source
    }
    private enum CodingKeys: String, CodingKey {
        case kind, hairstyle, facing, shape, color, expression, animated, seed, source
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shape = try c.decodeIfPresent(AvatarShape.self, forKey: .shape) ?? .pebble
        color = try c.decodeIfPresent(AvatarColor.self, forKey: .color) ?? .charcoal
        expression = try c.decodeIfPresent(AvatarExpression.self, forKey: .expression) ?? .curious
        animated = try c.decodeIfPresent(Bool.self, forKey: .animated) ?? true
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? 0
        source = try c.decodeIfPresent(AvatarSource.self, forKey: .source) ?? .character
        // Old geometric details remain available when switching the style back.
        kind = try c.decodeIfPresent(AvatarKind.self, forKey: .kind) ?? .girl
        hairstyle = try c.decodeIfPresent(GirlHairstyle.self, forKey: .hairstyle) ?? GirlHairstyle.allCases[Int(seed % UInt64(GirlHairstyle.allCases.count))]
        facing = try c.decodeIfPresent(GirlFacing.self, forKey: .facing) ?? .front
    }
    public static func generated(seed: UInt64) -> AvatarStyle {
        // A stable generator: identities survive process restarts and future platforms.
        var value = seed
        func next(_ count: Int) -> Int {
            value = value &+ 0x9E3779B97F4A7C15
            var z = value
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return Int((z ^ (z >> 31)) % UInt64(count))
        }
        return AvatarStyle(shape: AvatarShape.allCases[next(AvatarShape.allCases.count)],
                           color: AvatarColor.allCases[next(AvatarColor.allCases.count)],
                           expression: AvatarExpression.allCases[next(AvatarExpression.allCases.count)], seed: seed,
                           hairstyle: GirlHairstyle.allCases[next(GirlHairstyle.allCases.count)],
                           facing: GirlFacing.allCases[next(GirlFacing.allCases.count)])
    }
    public static func random() -> AvatarStyle { generated(seed: UInt64.random(in: .min ... .max)) }
    public static func defaultStyle(profile: String) -> AvatarStyle {
        let seed = SHA256.hash(data: Data(profile.utf8)).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        var style = generated(seed: seed)
        style.color = .charcoal; style.expression = .curious
        return style
    }
    public static let collection: [AvatarStyle] = [
        .init(color: .charcoal, expression: .curious, seed: 1, hairstyle: .bob, facing: .right),
        .init(color: .slate, expression: .sleepy, seed: 2, hairstyle: .long, facing: .front),
        .init(color: .vermilion, expression: .cheerful, seed: 3, hairstyle: .ponytail, facing: .left),
        .init(color: .violet, expression: .wink, seed: 4, hairstyle: .waves, facing: .right),
        .init(color: .charcoal, expression: .sparkle, seed: 5, hairstyle: .pixie, facing: .front),
        .init(color: .blue, expression: .curious, seed: 6, hairstyle: .bun, facing: .left)
    ]
}

/// Local presentation only. Never changes a Hermes profile, SOUL, memory or session.
@Observable @MainActor public final class AvatarLibrary {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey = "botAvatarStyles.v1"
    private var styles: [String: AvatarStyle]
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A damaged/future entry must not erase the other Bots' preferences.
        let rows = defaults.dictionary(forKey: storageKey) ?? [:]
        styles = rows.compactMapValues { value in
            guard let data = value as? Data else { return nil }
            return try? JSONDecoder().decode(AvatarStyle.self, from: data)
        }
    }
    nonisolated public static func key(gateway: String, user: String, profile: String) -> String {
        let canonical = (try? GatewayAddress(gateway).url.absoluteString) ?? gateway
        let data = (try? JSONEncoder().encode([canonical, user, profile])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public func style(for key: String, profile: String) -> AvatarStyle { styles[key] ?? .defaultStyle(profile: profile) }
    public func set(_ style: AvatarStyle, for key: String) {
        styles[key] = style; persist()
    }
    public func reset(_ key: String) { styles.removeValue(forKey: key); persist() }
    private func persist() {
        defaults.set(styles.compactMapValues { try? JSONEncoder().encode($0) }, forKey: storageKey)
    }
}
