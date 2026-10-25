import Foundation
import os

/// 「降智」检测：思路来自 is-gpt-nerfed（kiyoakii/is-gpt-nerfed，MIT）的被动扫描 —— 0 token，只读本机日志。
///
/// · Codex：逐轮看 `turn_context` 请求的模型 / 推理级别、`thread_settings_applied`（你自己改设置会留下这一条）、
///   `token_count.info.model_context_window`。没改设置却换了更弱的模型、降了推理级别、跑了隐藏的内部模型（如 gpt-reserve）、
///   上下文窗口变小 —— 都记为「硬证据」。
/// · Claude Code：主对话里 assistant 的模型在没有 `/model` 命令的情况下变了（例如用量到阈值后 Opus → Sonnet）；
///   来回交替（opusplan 这类自动路由）降为提示；API 错误 / 过载比例偏高单独提示。
/// · 指纹检测：装了 is-gpt-nerfed 就读它的 `~/.codex/is-gpt-nerfed/probes.jsonl`（ModelTrace 随机数指纹，会消耗少量 token，由它自己调度）。
/// · 行为统计：今天每次请求的平均输出、思考占比明显低于近两周中位数 —— 只作参考，不下结论。
public struct NerfFinding: Identifiable, Equatable {
    public enum Severity: Int, Comparable {
        case good = 0, info = 1, soft = 2, hard = 3
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    public var id: String
    public var source: String
    public var severity: Severity
    public var title: String
    public var detail: String
    public var timestamp: TimeInterval
    public var session: String = ""
}

public struct ProbeVerdict: Identifiable, Equatable {
    public var id: String
    public var finished: TimeInterval
    public var expected: String
    public var prediction: String
    public var probability: Double?
    public var verdict: String
    public var direction: String
    public var thread: String
    public var mode: String
}

public struct NerfReport: Equatable {
    public enum Status: Int, Comparable {
        case unknown = 0, ok = 1, watch = 2, alert = 3
        public static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }
    public var status: Status = .unknown
    public var headline = "还没有可检查的会话"
    public var findings: [NerfFinding] = []
    public var probes: [ProbeVerdict] = []
    public var probeInstalled = false
    public var sessionsScanned = 0
    public var turnsScanned = 0
    /// 「Codex」→「gpt-6-astra · xhigh」
    public var currentModels: [String: String] = [:]
    public var capturedAt: TimeInterval = 0
    public var hardCount: Int { findings.filter { $0.severity == .hard }.count }
}

public final class NerfDetector {
    public static let shared = NerfDetector()

    static let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    // MARK: 模型比较（移植 is-gpt-nerfed 的 compare_models，并让 Claude 先比档位再比代数）

    public struct CatalogEntry {
        var visibility = ""
        var contextWindow: Int? = nil
        var priority: Int? = nil
        var upgrade: String? = nil
        var maxEffort: Int? = nil
    }

    public struct Comparison: Equatable {
        public var direction: String      // upgrade / downgrade / lateral
        public var confidence: String     // high / medium / low
        public var reason: String
    }

    static func normalizeModel(_ slug: String?) -> String {
        let s = (slug ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if let slash = s.firstIndex(of: "/") { return String(s[s.index(after: slash)...]) }
        return s
    }

    /// gpt-6-astra → (6,0)，gpt-5.6-sol → (5,6)，claude-opus-4-8 → (4,8)
    static func modelVersion(_ slug: String) -> (Int, Int)? {
        guard let re = try? NSRegularExpression(pattern: #"(?:^|-)(\d+)(?:[.\-](\d{1,2}))?(?=$|-)"#),
              let m = re.firstMatch(in: slug, range: NSRange(slug.startIndex..., in: slug)) else { return nil }
        let ns = slug as NSString
        let major = Int(ns.substring(with: m.range(at: 1))) ?? 0
        let minor = m.range(at: 2).location != NSNotFound ? (Int(ns.substring(with: m.range(at: 2))) ?? 0) : 0
        guard major < 1000 else { return nil }      // 日期后缀不算版本
        return (major, minor)
    }

    /// 0 nano，1 mini/spark/lite/small/flash/reserve/auto-review/haiku，2 普通/sonnet，3 pro/ultra/opus，4 fable/mythos
    static func modelSize(_ slug: String) -> Int {
        if slug.hasPrefix("claude") {
            if slug.contains("haiku") { return 1 }
            if slug.contains("sonnet") { return 2 }
            if slug.contains("opus") { return 3 }
            if slug.contains("fable") || slug.contains("mythos") { return 4 }
            return 2
        }
        var size = 2
        for (tag, value) in [("nano", 0), ("mini", 1), ("spark", 1), ("lite", 1), ("small", 1), ("flash", 1), ("reserve", 1), ("auto-review", 1)]
            where slug.contains(tag) { size = min(size, value) }
        if slug.range(of: #"(^|-)(pro|ultra)($|-)"#, options: .regularExpression) != nil { size = 3 }
        return size
    }

    static func compare(_ old: String?, _ new: String?, catalog: [String: CatalogEntry] = [:], hidden: Set<String> = []) -> Comparison {
        let a = normalizeModel(old), b = normalizeModel(new)
        func out(_ d: String, _ c: String, _ r: String) -> Comparison { Comparison(direction: d, confidence: c, reason: r) }
        if a == b { return out("lateral", "high", "同一个模型") }
        let ea = catalog[a], eb = catalog[b]
        if let up = ea?.upgrade, normalizeModel(up) == b { return out("upgrade", "high", "Codex 模型目录把 \(b) 列为 \(a) 的后继") }
        if let up = eb?.upgrade, normalizeModel(up) == a { return out("downgrade", "high", "Codex 模型目录把 \(a) 列为 \(b) 的后继") }
        let hiddenA = hidden.contains(a) || ea?.visibility == "hide", hiddenB = hidden.contains(b) || eb?.visibility == "hide"
        if hiddenB && !hiddenA { return out("downgrade", "high", "\(b) 是 Codex 不公开列出的内部模型") }
        if hiddenA && !hiddenB { return out("upgrade", "medium", "从内部模型 \(a) 换回来了") }
        let va = modelVersion(a), vb = modelVersion(b), sa = modelSize(a), sb = modelSize(b)
        let claude = a.hasPrefix("claude") && b.hasPrefix("claude")
        func fmt(_ v: (Int, Int)) -> String { v.1 == 0 ? "\(v.0)" : "\(v.0).\(v.1)" }
        if claude, sa != sb {
            return out(sb > sa ? "upgrade" : "downgrade", "high", sb > sa ? "换到更大的档位" : "换到更小的档位")
        }
        if let va, let vb, va != vb {
            let newer = vb > va
            let reason = "\(newer ? "更新" : "更旧")的一代（\(fmt(vb)) vs \(fmt(va))）"
            return out(newer ? "upgrade" : "downgrade", sa == sb ? "high" : "medium", sa == sb ? reason : reason + "，档位也不同")
        }
        if sa != sb { return out(sb > sa ? "upgrade" : "downgrade", "high", sb > sa ? "更大的档位" : "更小的档位") }
        if let pa = ea?.priority, let pb = eb?.priority, pa != pb {
            return out(pb < pa ? "upgrade" : "downgrade", "medium", "Codex 目录排序 \(b) 在 \(a) \(pb < pa ? "之前" : "之后")")
        }
        if let ma = ea?.maxEffort, let mb = eb?.maxEffort, ma != mb {
            return out(mb > ma ? "upgrade" : "downgrade", "low", "支持的最高推理级别\(mb > ma ? "更高" : "更低")")
        }
        if let ca = ea?.contextWindow, let cb = eb?.contextWindow, ca != cb {
            return out(cb > ca ? "upgrade" : "downgrade", "low", "上下文窗口\(cb > ca ? "更大" : "更小")")
        }
        return out("lateral", "low", "同代同档，目录里没有先后")
    }

    static func effortIndex(_ e: String?) -> Int? { e.flatMap { efforts.firstIndex(of: $0.lowercased()) } }

    // MARK: 状态

    private struct Applied { var model: String?; var effort: String?; var tier: String? }

    private struct CodexScan {
        var offset: UInt64 = 0
        var model: String?
        var effort: String?
        var ctx: Int?
        var tier: String?
        var applied = Applied()
        var turns = 0
        var cwd = ""
        var lastTS: TimeInterval = 0
        var findings: [NerfFinding] = []
    }

    private struct ClaudeScan {
        var offset: UInt64 = 0
        var model: String?
        var pendingUserSwitch = false
        var turns = 0
        var errors = 0
        var errorsRecent: [TimeInterval] = []
        var turnsRecent: [TimeInterval] = []
        var cwd = ""
        var lastTS: TimeInterval = 0
        var pairs: [String: Int] = [:]
        var findings: [NerfFinding] = []
    }

    private let home: String
    private let queue = DispatchQueue(label: "io.github.xixilys.vibedeck.nerf", qos: .utility)
    private let lock = NSLock()
    private let log = Logger(subsystem: "io.github.xixilys.vibedeck", category: "nerf")
    private var codex: [String: CodexScan] = [:]
    private var claude: [String: ClaudeScan] = [:]
    private var catalog: (at: TimeInterval, entries: [String: CatalogEntry]) = (0, [:])
    private var report = NerfReport()
    private var timer: DispatchSourceTimer?
    private let iso = ISO8601DateFormatter()
    private let isoPlain = ISO8601DateFormatter()

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.home = home
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoPlain.formatOptions = [.withInternetDateTime]
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 3, repeating: 60)
            t.setEventHandler { [weak self] in self?.refresh(history: UsageHistory.shared.snapshot()) }
            self.timer = t
            t.resume()
        }
    }

    public func snapshot() -> NerfReport {
        lock.lock(); defer { lock.unlock() }
        return report
    }

    /// 同步扫一次（自测 / 面板刷新按钮）。
    @discardableResult
    public func refreshNow(history: UsageHistory.Snapshot? = nil) -> NerfReport {
        queue.sync { refresh(history: history) }
        return snapshot()
    }

    private func refresh(history: UsageHistory.Snapshot? = nil) {
        let now = Date().timeIntervalSince1970
        let horizon = now - 48 * 3600
        loadCatalogIfStale(now)
        let hidden = Set(catalog.entries.filter { $0.value.visibility == "hide" }.map { $0.key })

        // Codex rollouts（近 48 小时动过的）
        var seenCodex = Set<String>()
        for path in recentFiles(under: ["\(home)/.codex/sessions"], since: horizon) {
            seenCodex.insert(path)
            var st = codex[path] ?? CodexScan()
            scanCodex(path: path, state: &st, hidden: hidden)
            codex[path] = st
        }
        codex = codex.filter { seenCodex.contains($0.key) }

        var seenClaude = Set<String>()
        for path in recentFiles(under: ["\(home)/.claude/projects", "\(home)/.config/claude/projects"], since: horizon) {
            seenClaude.insert(path)
            var st = claude[path] ?? ClaudeScan()
            scanClaude(path: path, state: &st)
            claude[path] = st
        }
        claude = claude.filter { seenClaude.contains($0.key) }

        var r = NerfReport()
        r.capturedAt = now
        r.sessionsScanned = codex.values.filter { $0.turns > 0 }.count + claude.values.filter { $0.turns > 0 }.count
        r.turnsScanned = codex.values.reduce(0) { $0 + $1.turns } + claude.values.reduce(0) { $0 + $1.turns }
        var findings: [NerfFinding] = codex.values.flatMap { $0.findings }
        for st in claude.values {
            for var f in st.findings {
                // 同一对模型来回切 ≥3 次：多半是 opusplan 之类的自动路由，不算静默降级
                if let pair = f.id.components(separatedBy: "|pair=").last, (st.pairs[pair] ?? 0) >= 3, f.severity >= .soft {
                    f.severity = .info
                    f.title = "模型来回切换（像 opusplan 自动路由）"
                }
                findings.append(f)
            }
        }
        // Claude API 错误 / 过载比例（近 24 小时）
        let dayAgo = now - 86400
        let errs = claude.values.reduce(0) { $0 + $1.errorsRecent.filter { $0 >= dayAgo }.count }
        let turns = claude.values.reduce(0) { $0 + $1.turnsRecent.filter { $0 >= dayAgo }.count }
        if errs >= 5, Double(errs) / Double(max(1, errs + turns)) >= 0.1 {
            findings.append(NerfFinding(id: "claude-errors", source: "Claude", severity: .soft,
                                        title: "API 错误 / 过载偏多",
                                        detail: "近 24 小时 \(errs) 次错误，占 \(Int(Double(errs) * 100 / Double(errs + turns)))%",
                                        timestamp: now))
        }
        // 当前模型
        if let latest = codex.values.filter({ $0.model != nil }).max(by: { $0.lastTS < $1.lastTS }), let m = latest.model {
            r.currentModels["Codex"] = m + (latest.effort.map { " · \($0)" } ?? "")
        }
        if let latest = claude.values.filter({ $0.model != nil }).max(by: { $0.lastTS < $1.lastTS }), let m = latest.model {
            r.currentModels["Claude"] = m
        }
        // is-gpt-nerfed 的指纹结论
        let probeDir = "\(home)/.codex/is-gpt-nerfed"
        r.probeInstalled = FileManager.default.fileExists(atPath: probeDir)
        r.probes = readProbes("\(probeDir)/probes.jsonl", since: now - 7 * 86400)
        var latestByThread: [String: ProbeVerdict] = [:]
        for p in r.probes where latestByThread[p.thread].map({ $0.finished < p.finished }) ?? true { latestByThread[p.thread] = p }
        for p in latestByThread.values where p.finished >= horizon {
            let sev: NerfFinding.Severity
            switch p.verdict.uppercased() {
            case "DOWNGRADED!": sev = .hard
            case "MISMATCH": sev = p.direction == "upgrade" ? .good : .hard
            case "SUSPICIOUS": sev = .soft
            case "MATCH": continue
            default: sev = .info
            }
            let prob = p.probability.map { String(format: "%.0f%%", $0 * 100) } ?? "?"
            findings.append(NerfFinding(id: "probe|\(p.id)", source: "指纹检测", severity: sev,
                                        title: Self.verdictTitle(p), detail: "选的是 \(p.expected)，指纹更像 \(p.prediction)（\(prob)）",
                                        timestamp: p.finished, session: p.mode == "fresh" ? "新会话" : ""))
        }
        // 行为统计（只作参考）
        if let h = history { findings += Self.behaviorSignals(h, now: now) }

        // 同一变化会同时出现在主会话和子代理文件里：标题 + 细节 + 项目相同的只留最新一条
        var newest: [String: NerfFinding] = [:]
        for f in findings where f.timestamp >= horizon {
            let key = "\(f.source)|\(f.title)|\(f.detail)|\(f.session)"
            if let old = newest[key], old.timestamp >= f.timestamp { continue }
            newest[key] = f
        }
        r.findings = Array(newest.values).sorted {
            $0.severity != $1.severity ? $0.severity > $1.severity : $0.timestamp > $1.timestamp
        }
        let recent = r.findings.filter { $0.timestamp >= dayAgo }
        if recent.contains(where: { $0.severity == .hard }) {
            r.status = .alert
            r.headline = recent.first { $0.severity == .hard }?.title ?? "发现降级证据"
        } else if recent.contains(where: { $0.severity == .soft }) {
            r.status = .watch
            r.headline = recent.first { $0.severity == .soft }?.title ?? "有可疑迹象"
        } else if r.turnsScanned > 0 || !r.probes.isEmpty {
            r.status = .ok
            r.headline = "没发现模型被换、推理被降或上下文被缩"
        }
        lock.lock(); report = r; lock.unlock()
    }

    static func verdictTitle(_ p: ProbeVerdict) -> String {
        switch p.verdict.uppercased() {
        case "DOWNGRADED!": return "指纹：已降配"
        case "MISMATCH": return p.direction == "upgrade" ? "指纹：被升配" : (p.direction == "downgrade" ? "指纹：被降配" : "指纹：模型被换")
        case "SUSPICIOUS": return "指纹：可疑"
        case "UNLISTED": return "指纹：未收录的模型"
        case "INVALID": return "指纹：本次无结果"
        default: return "指纹：\(p.verdict)"
        }
    }

    /// 今天每次请求的平均输出 / 思考占比 vs 近 14 天中位数（请求数够多才比）。
    static func behaviorSignals(_ h: UsageHistory.Snapshot, now: TimeInterval) -> [NerfFinding] {
        let today = UsageHistory.dayKey(timestamp: now)
        var out: [NerfFinding] = []
        for source in ["Codex", "Claude"] {
            guard let t = h.days.first(where: { $0.date == today })?.sources[source], t.turns >= 30 else { continue }
            let past = h.days.filter { $0.date < today }.suffix(14).compactMap { $0.sources[source] }.filter { $0.turns >= 30 }
            guard past.count >= 3 else { continue }
            func median(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
            let avgOut = Double(t.out) / Double(t.turns)
            let baseOut = median(past.map { Double($0.out) / Double($0.turns) })
            if baseOut > 0, avgOut / baseOut < 0.55 {
                out.append(NerfFinding(id: "behavior-out-\(source)", source: "行为统计", severity: .soft,
                                       title: "\(source) 回答明显变短",
                                       detail: "今天每次请求平均输出 \(Int(avgOut)) token，近两周中位数 \(Int(baseOut))（仅供参考）",
                                       timestamp: now))
            }
            if source == "Codex", t.out > 0 {
                let share = Double(t.think) / Double(t.out)
                let baseShare = median(past.filter { $0.out > 0 }.map { Double($0.think) / Double($0.out) })
                if baseShare >= 0.1, share / baseShare < 0.5 {
                    out.append(NerfFinding(id: "behavior-think-codex", source: "行为统计", severity: .soft,
                                           title: "Codex 思考占比下降",
                                           detail: String(format: "今天思考占输出 %.0f%%，近两周中位数 %.0f%%（仅供参考）", share * 100, baseShare * 100),
                                           timestamp: now))
                }
            }
        }
        return out
    }

    // MARK: 读文件

    private func recentFiles(under roots: [String], since: TimeInterval) -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        for root in roots where fm.fileExists(atPath: root) {
            guard let en = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                let mt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
                if mt >= since { out.append(url.path) }
            }
        }
        return out
    }

    /// 从上次的位置读到文件末尾最后一个换行；单次最多 64MB（超大文件分几轮追上）。
    private func readNew(_ path: String, offset: inout UInt64) -> [Data] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < offset { offset = 0 }
        guard size > offset else { return [] }
        do { try fh.seek(toOffset: offset) } catch { return [] }
        guard let data = try? fh.read(upToCount: Int(min(size - offset, 64 << 20))),
              let lastNL = data.lastIndex(of: 0x0A) else { return [] }
        let chunk = data[data.startIndex...lastNL]
        offset += UInt64(chunk.count)
        return chunk.split(separator: 0x0A).map { Data($0) }
    }

    private func ts(_ raw: Any?) -> TimeInterval {
        guard var text = raw as? String else { return Date().timeIntervalSince1970 }
        if let range = text.range(of: #"\.\d{4,}"#, options: .regularExpression) { text.replaceSubrange(range, with: text[range].prefix(4)) }
        return (iso.date(from: text) ?? isoPlain.date(from: text))?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
    }

    private static let codexMarkers = ["\"turn_context\"", "\"thread_settings_applied\"", "\"token_count\"", "\"session_meta\""].map { Data($0.utf8) }

    private func scanCodex(path: String, state st: inout CodexScan, hidden: Set<String>) {
        let file = (path as NSString).lastPathComponent
        for line in readNew(path, offset: &st.offset) {
            guard Self.codexMarkers.contains(where: { line.range(of: $0) != nil }),
                  let j = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let p = j["payload"] as? [String: Any] else { continue }
            let type = j["type"] as? String ?? ""
            let t = ts(j["timestamp"])
            let project = (st.cwd as NSString).lastPathComponent
            func add(_ kind: String, _ sev: NerfFinding.Severity, _ title: String, _ detail: String) {
                let id = "\(file)|\(kind)|\(detail)|\(Int(t))"
                guard !st.findings.contains(where: { $0.id == id }) else { return }
                st.findings.append(NerfFinding(id: id, source: "Codex", severity: sev, title: title, detail: detail, timestamp: t, session: project))
            }
            switch type {
            case "session_meta":
                if let cwd = p["cwd"] as? String { st.cwd = cwd }
            case "turn_context":
                st.turns += 1
                st.lastTS = t
                if let cwd = p["cwd"] as? String, st.cwd.isEmpty { st.cwd = cwd }
                let settings = (p["collaboration_mode"] as? [String: Any])?["settings"] as? [String: Any] ?? [:]
                let effort = (settings["reasoning_effort"] as? String) ?? (p["reasoning_effort"] as? String) ?? (p["effort"] as? String)
                if let model = p["model"] as? String, !model.isEmpty {
                    if hidden.contains(model.lowercased()) || model.lowercased().contains("reserve") {
                        add("hidden_model", .hard, "内部隐藏模型回答了本轮", "\(model) 不是你能选的公开模型")
                    }
                    if let old = st.model, old != model {
                        let cmp = Self.compare(old, model, catalog: catalog.entries, hidden: hidden)
                        let good = cmp.direction == "upgrade" && cmp.confidence != "low"
                        if st.applied.model == model {
                            // 走了设置（thread_settings_applied）= 多半是你自己切的：只提示，不影响总状态
                            add("applied_model_change", good ? .good : .info,
                                cmp.direction == "downgrade" ? "设置里换成了更弱的模型（是你改的吗？）" : "设置里换了模型",
                                "\(old) → \(model)：\(cmp.reason)")
                        } else {
                            add("silent_model_change", cmp.direction == "downgrade" ? .hard : (good ? .good : .soft),
                                cmp.direction == "downgrade" ? "没改设置，模型被换成更弱的" : (good ? "没改设置，模型升级了" : "没改设置，模型变了"),
                                "\(old) → \(model)：\(cmp.reason)")
                        }
                    }
                    st.model = model
                }
                if let effort, !effort.isEmpty {
                    if let old = st.effort, old != effort {
                        let lower = (Self.effortIndex(effort) ?? 0) < (Self.effortIndex(old) ?? 0)
                        if st.applied.effort == effort {
                            add("applied_effort_change", lower ? .soft : .info, lower ? "设置里调低了推理级别" : "设置里调整了推理级别", "\(old) → \(effort)")
                        } else {
                            add("silent_effort_change", lower ? .hard : .soft, lower ? "没改设置，推理级别被调低" : "没改设置，推理级别变了", "\(old) → \(effort)")
                        }
                    }
                    st.effort = effort
                }
            case "event_msg":
                let et = p["type"] as? String ?? ""
                if et == "thread_settings_applied" {
                    let s = p["thread_settings"] as? [String: Any] ?? [:]
                    st.applied = Applied(model: s["model"] as? String, effort: s["reasoning_effort"] as? String, tier: s["service_tier"] as? String)
                    if let tier = s["service_tier"] as? String {
                        if let old = st.tier, old != tier { add("service_tier_change", .info, "服务档位变化（只影响速度）", "\(old) → \(tier)") }
                        st.tier = tier
                    }
                } else if et == "token_count", let ctx = (p["info"] as? [String: Any])?["model_context_window"] as? Int, ctx > 0 {
                    if let old = st.ctx, old != ctx {
                        add("context_window_change", ctx < old ? .hard : .info, ctx < old ? "上下文窗口被缩小" : "上下文窗口变大", "\(old) → \(ctx)")
                    }
                    st.ctx = ctx
                }
            default:
                break
            }
        }
    }

    private func scanClaude(path: String, state st: inout ClaudeScan) {
        let file = (path as NSString).lastPathComponent
        let modelCommand = Data("<command-name>/model</command-name>".utf8)
        for line in readNew(path, offset: &st.offset) {
            let isUserSwitch = line.range(of: modelCommand) != nil
            guard isUserSwitch || line.range(of: Data("\"assistant\"".utf8)) != nil,
                  let j = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let cwd = j["cwd"] as? String { st.cwd = cwd }
            let type = j["type"] as? String ?? ""
            if type == "user" || isUserSwitch { if isUserSwitch { st.pendingUserSwitch = true }; continue }
            guard type == "assistant", j["isSidechain"] as? Bool != true, let msg = j["message"] as? [String: Any] else { continue }
            let t = ts(j["timestamp"])
            if j["isApiErrorMessage"] as? Bool == true {
                st.errors += 1
                st.errorsRecent.append(t)
                if st.errorsRecent.count > 500 { st.errorsRecent.removeFirst(st.errorsRecent.count - 500) }
                continue
            }
            guard let model = msg["model"] as? String, !model.isEmpty, !model.contains("synthetic") else { continue }
            st.turns += 1
            st.lastTS = t
            st.turnsRecent.append(t)
            if st.turnsRecent.count > 2000 { st.turnsRecent.removeFirst(st.turnsRecent.count - 2000) }
            if let old = st.model, old != model {
                let cmp = Self.compare(old, model)
                let pair = [old, model].sorted().joined(separator: "↔")
                st.pairs[pair, default: 0] += 1
                let project = (st.cwd as NSString).lastPathComponent
                let id = "\(file)|claude_model|\(Int(t))|pair=\(pair)"
                let sev: NerfFinding.Severity
                let title: String
                if st.pendingUserSwitch {
                    sev = .info
                    title = "你用 /model 换了模型"
                } else {
                    sev = cmp.direction == "downgrade" ? .hard : (cmp.direction == "upgrade" ? .good : .soft)
                    title = cmp.direction == "downgrade" ? "没用 /model，模型被换成更弱的" : "没用 /model，模型变了"
                }
                st.findings.append(NerfFinding(id: id, source: "Claude", severity: sev, title: title,
                                               detail: "\(old) → \(model)：\(cmp.reason)", timestamp: t, session: project))
            }
            st.model = model
            st.pendingUserSwitch = false
        }
    }

    private func loadCatalogIfStale(_ now: TimeInterval) {
        guard now - catalog.at > 600 else { return }
        var entries: [String: CatalogEntry] = [:]
        let path = "\(home)/.codex/models_cache.json"
        if let data = FileManager.default.contents(atPath: path),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            var models: [[String: Any]] = []
            if let list = root["models"] as? [[String: Any]] { models = list }
            else if let dict = root["models"] as? [String: [String: Any]] { models = Array(dict.values) }
            for m in models {
                guard let slug = m["slug"] as? String else { continue }
                var e = CatalogEntry()
                e.visibility = (m["visibility"] as? String ?? "").lowercased()
                e.contextWindow = m["context_window"] as? Int
                e.priority = m["priority"] as? Int
                e.upgrade = m["upgrade"] as? String
                let levels = (m["supported_reasoning_levels"] as? [Any] ?? []).compactMap { level -> Int? in
                    if let d = level as? [String: Any] { return Self.effortIndex(d["effort"] as? String) }
                    return Self.effortIndex(level as? String)
                }
                e.maxEffort = levels.max()
                entries[slug.lowercased()] = e
            }
        }
        catalog = (now, entries)
    }

    private func readProbes(_ path: String, since: TimeInterval) -> [ProbeVerdict] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var out: [ProbeVerdict] = []
        for line in text.split(separator: "\n").suffix(400) {
            guard let d = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let verdict = o["verdict"] as? String else { continue }
            let finished = ts(o["finished"])
            guard finished >= since else { continue }
            out.append(ProbeVerdict(id: o["id"] as? String ?? UUID().uuidString, finished: finished,
                                    expected: o["expected"] as? String ?? "?", prediction: o["prediction"] as? String ?? "?",
                                    probability: (o["probability"] as? NSNumber)?.doubleValue, verdict: verdict,
                                    direction: o["direction"] as? String ?? "", thread: o["thread_id"] as? String ?? "",
                                    mode: o["mode"] as? String ?? ""))
        }
        return out.sorted { $0.finished > $1.finished }
    }
}
