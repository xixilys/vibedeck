import Foundation

/// 应用内语言覆盖；跟随系统时仍尊重 AppleLanguages（也用于本地检查）。
enum AppLanguage: String, CaseIterable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let defaultsKey = "vg.language"

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
    }

    var isChinese: Bool {
        switch self {
        case .system: return Locale.preferredLanguages.first?.hasPrefix("zh") == true
        case .simplifiedChinese: return true
        case .english: return false
        }
    }

    var locale: Locale {
        switch self {
        case .system: return Locale(identifier: Locale.preferredLanguages.first ?? "en")
        case .simplifiedChinese: return Locale(identifier: "zh-Hans")
        case .english: return Locale(identifier: "en")
        }
    }

    var displayName: String {
        switch self {
        case .system: return L("跟随系统", "System")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}

/// 新界面文字沿用仓库约定的中英双语入口。
func L(_ chinese: String, _ english: String) -> String {
    AppLanguage.current.isChinese ? chinese : english
}

/// 界面缩放。默认字号偏小是最常见的反馈，菜单里可选档位，写进 UserDefaults 后即时生效。
enum UITheme {
    static let scaleKey = "fontScale"

    /// Keep the menu readable while allowing the requested compact-to-large range.
    static var fontScale: CGFloat {
        let value = UserDefaults.standard.double(forKey: scaleKey)
        return value >= 0.85 && value <= 1.3 ? CGFloat(value) : 1.0
    }

    /// 菜单档位（标题, 倍率）。
    static var presets: [(title: String, value: Double)] {
        [
            (L("小", "Small"), 0.85), (L("较小", "Compact"), 0.9), (L("标准", "Standard"), 1.0),
            (L("大", "Large"), 1.15), (L("特大", "Extra Large"), 1.3),
        ]
    }
}

/// Compact token counts used throughout the panel.
func formatTokens(_ count: Int64, chinese: Bool? = nil) -> String {
    let isChinese = chinese ?? AppLanguage.current.isChinese
    let magnitude = abs(Double(count))
    let units: [(suffix: String, divisor: Double)] = isChinese
        ? [("", 1), ("万", 10_000), ("亿", 100_000_000)]
        : [("", 1), ("K", 1_000), ("M", 1_000_000), ("B", 1_000_000_000)]
    var unitIndex = units.indices.last(where: { magnitude >= units[$0].divisor }) ?? 0
    var scaled = magnitude / units[unitIndex].divisor
    let roundedTenths = floor(scaled * 10 + 0.5) / 10
    if unitIndex + 1 < units.count {
        let nextUnitValue = units[unitIndex + 1].divisor / units[unitIndex].divisor
        if roundedTenths >= nextUnitValue { unitIndex += 1 }
    }
    let suffix = units[unitIndex].suffix
    let divisor = units[unitIndex].divisor

    let locale = Locale(identifier: isChinese ? "zh_CN" : "en_US")
    if divisor == 1 {
        return CachedNumberFormatter.decimal(locale: locale, fraction: 0).string(from: NSNumber(value: count)) ?? String(count)
    }
    let formatter = CachedNumberFormatter.decimal(locale: locale, fraction: 1, minimumFraction: 0)
    scaled = magnitude / divisor
    let number = formatter.string(from: NSNumber(value: scaled)) ?? String(format: "%.1f", scaled)
    return (count < 0 ? "−" : "") + number + suffix
}

enum UIFormat {
    private static var locale: Locale {
        AppLanguage.current.locale
    }

    private static var isChinese: Bool {
        AppLanguage.current.isChinese
    }

    /// Formatters are expensive to build and the panel asks for dozens per frame; cache per locale and style.
    private static let cacheLock = NSLock()
    private static var relativeCache: [String: RelativeDateTimeFormatter] = [:]
    private static var durationCache: [String: DateComponentsFormatter] = [:]

    private static func relative(_ seconds: TimeInterval, style: RelativeDateTimeFormatter.UnitsStyle) -> String {
        let key = locale.identifier + ":\(style.rawValue)"
        cacheLock.lock(); defer { cacheLock.unlock() }
        let formatter = relativeCache[key] ?? {
            let made = RelativeDateTimeFormatter()
            made.locale = locale
            made.unitsStyle = style
            relativeCache[key] = made
            return made
        }()
        return formatter.localizedString(fromTimeInterval: seconds)
    }

    static func ago(_ seconds: Int) -> String {
        relative(-Double(max(0, seconds)), style: .full)
    }

    static func agoShort(_ seconds: Int) -> String {
        relative(-Double(max(0, seconds)), style: .abbreviated)
    }

    static func countdown(to timestamp: TimeInterval?, now: TimeInterval = Date().timeIntervalSince1970) -> String? {
        guard let timestamp else { return nil }
        let remaining = timestamp - now
        guard remaining > 0 else { return L("已重置", "Reset") }
        guard remaining >= 60 else { return L("不足1分钟", "<1 min") }
        let long = remaining >= 86_400
        let key = locale.identifier + (long ? ":d" : ":h")
        cacheLock.lock(); defer { cacheLock.unlock() }
        let formatter = durationCache[key] ?? {
            var calendar = Calendar.current
            calendar.locale = locale
            let made = DateComponentsFormatter()
            made.calendar = calendar
            made.allowedUnits = long ? [.day, .hour] : [.hour, .minute]
            made.maximumUnitCount = 2
            made.unitsStyle = isChinese ? .full : .abbreviated
            made.zeroFormattingBehavior = .dropAll
            durationCache[key] = made
            return made
        }()
        return formatter.string(from: remaining)
    }

    /// Translate only known generic plan labels; account-specific plan names pass through.
    static func tier(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "个人 OAuth": return L("个人 OAuth", "Personal OAuth")
        case "已登录": return L("已登录", "Signed in")
        case "未登录": return L("未登录", "Not signed in")
        case "标准": return L("标准", "Standard")
        case "订阅": return L("订阅", "Subscription")
        case "三方": return L("三方", "Third-party")
        case "副池": return L("副池", "Secondary pool")
        case "本地": return L("本地", "Local")
        case "OAuth", "API Key", "Pro", "Team": return value
        default: return value
        }
    }

    /// Translate known scanner-generated metadata while preserving provider/model identifiers.
    /// Unknown Chinese diagnostics stay available in the hover text rather than being guessed.
    static func metadata(_ raw: String) -> String {
        guard !isChinese else { return raw }

        let exact: [String: String] = [
            "Codex 会话记录": "Codex session logs",
            "Grok 会话记录": "Grok session logs",
            "Claude 会话记录": "Claude session logs",
            "Codex 日志库": "Codex log database",
            "Codex 会话库": "Codex session database",
            "Codex 生成的图片": "Codex generated images",
            "Grok 下载": "Grok downloads",
            "Codex 插件": "Codex plugins",
            "Claude 插件": "Claude plugins",
            "本窗口均": "Window average",
            "已开启": "Enabled",
            "未开启": "Disabled",
            "运行中": "Running",
            "等 Claude Code 下一轮对话刷新额度": "Waiting for the next Claude Code turn to refresh quota",
            "未配置 statusLine，无额度": "statusLine is not configured; no quota available",
            "只有跑 Claude/GPT 模型时才会刷新；耗尽后无法再刷，只能等重置": "Refreshes only after running Claude/GPT models. Once exhausted, it cannot refresh until reset.",
            "grok 自己的 billing 日志，不必产生对话就会刷": "Grok's own billing log refreshes without a conversation.",
            "端侧运行 · 0 额度消耗": "Runs locally · no quota consumed",
            "端侧运行 · 无已加载模型": "Runs locally · no model loaded",
            "IDE 进程在线 · 本地无档位/额度数据": "IDE process is running · no local plan or quota data",
            "Antigravity · 无额度数据 (agy-hud 未刷新)": "Antigravity · no quota data (agy-hud has not refreshed)",
            "xAI · 无额度数据 (grok 未跑过)": "xAI · no quota data (Grok has not run)",
            "未取得新额度，保留上次读数": "Quota missing; showing last reading",
            "限速档位字段": "Rate limit tier field",
            "组织类型": "Organization type",
            "计费方式": "Billing type",
            "角色": "Role",
            "额外用量": "Extra usage",
            "订阅开始": "Subscription started",
            "套餐字段": "Plan field",
            "订阅有效期至": "Subscription valid until",
            "鉴权方式": "Authentication method",
            "默认模型": "Default model",
            "三方池说明": "Third-party pool notes",
            "订阅档位（服务端原值）": "Subscription tier (provider value)",
            "CLI 版本": "CLI version",
            "额度来源": "Quota source"
        ]
        if let value = exact[raw] { return value }
        if tier(raw) != raw { return tier(raw) }

        if raw.hasPrefix("走 "), raw.hasSuffix("，无订阅额度") {
            let host = raw.dropFirst("走 ".count).dropLast("，无订阅额度".count)
            return "Using \(host); no subscription quota"
        }
        if raw.hasPrefix("已加载: ") {
            return "Loaded: \(raw.dropFirst("已加载: ".count))"
        }
        if let groups = capture(#"^(\d+) 会话$"#, in: raw) { return "\(groups[0]) sessions" }
        if let groups = capture(#"^(\d+) 模型$"#, in: raw) { return "\(groups[0]) models" }
        if let groups = capture(#"^已用 (\d+)%$"#, in: raw) { return "\(groups[0])% used" }
        if let groups = capture(#"^近 (\d+) 分钟$"#, in: raw) { return "In the last \(groups[0]) minutes" }
        if let groups = capture(#"^(.+)（(\d+) 天前）$"#, in: raw) { return "\(groups[0]) (\(groups[1]) days ago)" }
        if let groups = capture(#"^(.+)（还剩 (\d+) 天）$"#, in: raw) { return "\(groups[0]) (\(groups[1]) days left)" }
        if let groups = capture(#"^(.*?) · 上下文 (.+?) · 输出 (.+?)(?: · 命中 (.+))?$"#, in: raw) {
            let cache = groups.count > 3 ? " · cache \(groups[3])" : ""
            return "\(groups[0]) · Context \(groups[1]) · Output \(groups[2])\(cache)"
        }

        return !raw.unicodeScalars.contains { 0x4e00...0x9fff ~= $0.value }
            ? raw
            : "Details available on hover"
    }

    private static func capture(_ pattern: String, in value: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
    }
}
