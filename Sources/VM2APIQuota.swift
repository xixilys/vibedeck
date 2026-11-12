import Foundation
import Combine

/// Quotas that live on the vm2api box (default: jp-elaina). vm2api exposes two independent credentials per VM:
/// Codex OAuth windows through its quota-reader cache, and Claude accounts through the accounts DB. Both are
/// ordinary logins used by this person, so both are collected and shown as ordinary subscription cards.
enum VM2APIQuota {
    static let hostsKey = "vm2apiHosts"
    static let legacyHostsKey = "claudeVMQuotaHosts"
    static let codexPathKey = "vm2apiCodexQuotaPath"
    static let legacyCodexPathKey = "claudeVMQuotaPath"
    static let dbPathKey = "vm2apiDBPath"
    static let defaultHost = "jp-elaina"
    static let defaultCodexPath = "/opt/vm2api-quota-reader/reader-state.json"
    static let defaultDBPath = "/opt/vm2api/data/kin.db"

    enum Provider: String, CaseIterable, Equatable {
        case claude, codex
        var title: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "Codex"
            }
        }
        /// Provider name used by account observation tooling.
        var accountProvider: String {
            switch self {
            case .claude: return "anthropic"
            case .codex: return "openai"
            }
        }
    }

    struct Sample: Codable, Equatable {
        var at: TimeInterval
        var pct: Double
    }

    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    struct Envelope: Equatable {
        var accounts: [Account]
        var codexError: String
        var claudeError: String
    }

    struct Account: Identifiable, Equatable {
        var vmID: String
        var host: String
        var provider: Provider
        var fiveHour: QuotaWindow?
        var sevenDay: QuotaWindow?
        var note: String = ""
        var variant: String = ""
        var id: String { "vm2api:\(provider.rawValue):\(host):\(vmID)" }
        var title: String { provider.title + " · " + vmID }
        var hasWindows: Bool { fiveHour != nil || sevenDay != nil }
        /// A window that has already reset is not a current quota; cards use this to decide whether
        /// they have something live to show or belong in the compact "no current quota" row.
        func hasCurrentWindow(now: TimeInterval) -> Bool {
            [fiveHour, sevenDay].contains { quota in
                guard let quota else { return false }
                return !quota.isExpired(now: now)
            }
        }
        var capturedAt: TimeInterval {
            [fiveHour?.capturedAt, sevenDay?.capturedAt].compactMap { $0 }.max() ?? 0
        }

        /// Ordinary quota card, so vm2api accounts sit in the same grid as local subscriptions.
        func card(now: TimeInterval) -> AccountPresentation {
            var card = AccountPresentation(id: id, account: nil, usage: nil, quotas: observations(now: now))
            card.planTitle = title
            card.planNote = note.isEmpty ? nil : note
            card.keepsExpiredWindows = true
            card.signedInSources = [provider.title + " · vm2api"]
            return card
        }

        func observations(now: TimeInterval) -> [AccountQuotaObservation] {
            func observation(_ quota: QuotaWindow?, window: String) -> AccountQuotaObservation? {
                guard let quota, let captured = quota.capturedAt else { return nil }
                let start = quota.windowSeconds > 0 ? quota.resetsAt.map { $0 - quota.windowSeconds } : nil
                let expired = quota.isExpired(now: now)
                let trusted = !expired && captured <= now + 60 && now - captured <= 600
                return AccountQuotaObservation(account: nil, source: provider.title + " · vm2api",
                                               provider: provider.accountProvider,
                                               pool: provider.rawValue + "-" + vmID,
                                               window: window, startedAt: start, resetAt: quota.resetsAt,
                                               capturedAt: captured,
                                               usedPercent: expired ? 0 : (quota.rawUsedPercent ?? Double(quota.usedPct)),
                                               trusted: trusted)
            }
            return [observation(fiveHour, window: "5h"), observation(sevenDay, window: "week")].compactMap { $0 }
        }
    }

    // MARK: - Configuration

    static func configuredHosts(defaults: UserDefaults = .standard) -> [String] {
        let raw = (defaults.string(forKey: hostsKey) ?? defaults.string(forKey: legacyHostsKey)) ?? defaultHost
        var seen = Set<String>()
        return raw.split { ", ;\n\t".contains($0) }.compactMap { item in
            let host = item.trimmingCharacters(in: .whitespaces)
            guard ProcessScanner.isValidSSHHost(host), seen.insert(host).inserted else { return nil }
            return host
        }
    }

    static func configuredCodexPath(defaults: UserDefaults = .standard) -> String {
        validPath(defaults.string(forKey: codexPathKey) ?? defaults.string(forKey: legacyCodexPathKey) ?? defaultCodexPath,
                  fallback: defaultCodexPath)
    }

    static func configuredDBPath(defaults: UserDefaults = .standard) -> String {
        validPath(defaults.string(forKey: dbPathKey) ?? defaultDBPath, fallback: defaultDBPath)
    }

    private static func validPath(_ raw: String, fallback: String) -> String {
        guard raw.range(of: #"^[A-Za-z0-9_./~-]+$"#, options: .regularExpression) != nil else { return fallback }
        return raw
    }

    // MARK: - Remote read

    /// One SSH round-trip reads the Codex cache and queries vm2api's accounts DB. Both reads are read-only.
    static func fetch(host: String, codexPath: String, dbPath: String) -> Result<Envelope, Failure> {
        guard ProcessScanner.isValidSSHHost(host) else { return .failure(Failure(L("无效 SSH 目标", "Invalid SSH target"))) }
        let command = "python3 - '\(codexPath)' '\(dbPath)'"
        switch RemoteCollector.runRemote(host: host, command: command, stdin: Data(remoteScript.utf8),
                                         timeout: 18, maxBytes: 2 * 1024 * 1024) {
        case .failure(let error):
            return .failure(Failure(error.message))
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(Failure(L("服务器没有返回额度", "The server returned no quota"))) }
            guard let data = trimmed.data(using: .utf8) else { return .failure(Failure(L("额度不是文本", "Quota is not text"))) }
            return parse(data, host: host)
        }
    }

    /// Reads `/opt/vm2api-quota-reader/reader-state.json` and a read-only snapshot of `kin.db`.
    /// Kept as a literal so the remote host needs only python3, exactly like the existing collector.
    static let remoteScript = #"""
import json, sqlite3, sys
codex_path, db_path = sys.argv[1], sys.argv[2]
out = {"codex": None, "claude": None, "codex_error": "", "claude_error": ""}
try:
    with open(codex_path, "r", encoding="utf-8") as handle:
        out["codex"] = json.load(handle)
except Exception as error:
    out["codex_error"] = str(error)[:240]
try:
    con = sqlite3.connect("file:" + db_path + "?mode=ro", uri=True, timeout=4)
    con.row_factory = sqlite3.Row
    rows = []
    for row in con.execute(
            "select vm_id,email,name,type,status,schedulable,extra,updated_at,last_used_at,"
            "session_window_status,rate_limit_reset_at from accounts "
            "where deleted_at is null and platform='claude'"):
        item = dict(row)
        try:
            item["extra"] = json.loads(item["extra"]) if item["extra"] else {}
        except Exception:
            item["extra"] = {}
        rows.append(item)
    out["claude"] = rows
except Exception as error:
    out["claude_error"] = str(error)[:240]
print(json.dumps(out, ensure_ascii=False, separators=(",", ":")))
"""#

    // MARK: - Parsing

    static func parse(_ data: Data, host: String, now: TimeInterval = Date().timeIntervalSince1970) -> Result<Envelope, Failure> {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(Failure(L("额度格式不认识", "Unrecognised quota payload")))
        }
        var accounts: [Account] = []
        var codexError = (root["codex_error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var claudeError = (root["claude_error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let codex = root["codex"] as? [String: Any] {
            let parsed = parseCodex(codex, host: host, now: now)
            accounts += parsed.accounts
            if parsed.accounts.isEmpty && !parsed.error.isEmpty { codexError = parsed.error }
        } else if codexError.isEmpty {
            codexError = L("没有 Codex 额度数据", "No Codex quota data")
        }
        if let rows = root["claude"] as? [[String: Any]] {
            let parsed = parseClaude(rows, host: host, now: now)
            accounts += parsed.accounts
            if parsed.accounts.isEmpty && !parsed.error.isEmpty { claudeError = parsed.error }
        } else if claudeError.isEmpty {
            claudeError = L("没有 Claude 账号数据", "No Claude account data")
        }
        guard !accounts.isEmpty else {
            return .failure(Failure([codexError, claudeError].filter { !$0.isEmpty }.joined(separator: "；")))
        }
        // Sort by provider (Claude first) then VM id, matching the subscription groups.
        let sorted = accounts.sorted { a, b in
            if a.provider != b.provider { return a.provider == .claude }
            if a.host != b.host { return a.host < b.host }
            return a.vmID.localizedStandardCompare(b.vmID) == .orderedAscending
        }
        return .success(Envelope(accounts: sorted, codexError: codexError, claudeError: claudeError))
    }

    private static func parseCodex(_ root: [String: Any], host: String, now: TimeInterval) -> (accounts: [Account], error: String) {
        guard let vms = root["vms"] as? [String: Any] else {
            return ([], L("Codex 额度格式不认识", "Unrecognised Codex quota"))
        }
        func number(_ value: Any?) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        func window(_ raw: Any?, seconds: Double) -> QuotaWindow? {
            guard let row = raw as? [String: Any],
                  let used = number(row["used_percent"]), used >= 0, used <= 100 else { return nil }
            let reset = number(row["reset_at"]).flatMap { $0 > 0 && $0 <= 253402300799 ? $0 : nil }
            let observed = number(row["observed_at"]).flatMap { $0 > 0 && $0 <= 253402300799 ? $0 : nil }
            return QuotaWindow(usedPct: Int(used.rounded()), resetsAt: reset, capturedAt: observed,
                               windowSeconds: seconds, rawUsedPercent: used)
        }
        var accounts: [Account] = []
        for (vmID, value) in vms {
            guard vmID.count <= 80, vmID.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil else { continue }
            let row = value as? [String: Any] ?? [:]
            let confirmed = row["confirmed"] as? [String: Any] ?? [:]
            let five = window(confirmed["five_hour"], seconds: 5 * 3600)
            let week = window(confirmed["seven_day"], seconds: 7 * 86400)
            var account = Account(vmID: vmID, host: host, provider: .codex, fiveHour: five, sevenDay: week)
            if !account.hasWindows { account.note = L("没有确认读数", "No confirmed reading") }
            if let captured = account.fiveHour?.capturedAt, captured > now + 300 { account.fiveHour = nil }
            if let captured = account.sevenDay?.capturedAt, captured > now + 300 { account.sevenDay = nil }
            if !account.hasWindows { account.note = L("没有确认读数", "No confirmed reading") }
            accounts.append(account)
        }
        if accounts.isEmpty { return ([], L("Codex 额度里没有 VM", "No Codex VMs")) }
        return (accounts, "")
    }

    private static func parseClaude(_ rows: [[String: Any]], host: String, now: TimeInterval) -> (accounts: [Account], error: String) {
        // The DB can hold more than one credential row for a VM; keep the one with the freshest usable reading.
        var best: [String: (account: Account, score: (Int, TimeInterval))] = [:]
        for row in rows {
            guard let account = claudeAccount(row, host: host) else { continue }
            let score = (account.hasWindows ? 1 : 0, account.capturedAt)
            if let old = best[account.vmID] {
                if score.0 != old.score.0 { if score.0 < old.score.0 { continue } }
                else if score.1 <= old.score.1 { continue }
            }
            best[account.vmID] = (account, score)
        }
        if best.isEmpty { return ([], L("Claude 账号列表为空", "No Claude accounts")) }
        return (best.values.map(\.account), "")
    }

    private static func claudeAccount(_ row: [String: Any], host: String) -> Account? {
        guard let vmID = (row["vm_id"] as? String)?.trimmingCharacters(in: .whitespaces), !vmID.isEmpty,
              vmID.count <= 80, vmID.range(of: #"^[A-Za-z0-9_.:-]+$"#, options: .regularExpression) != nil else { return nil }
        let extra: [String: Any] = {
            if let dict = row["extra"] as? [String: Any] { return dict }
            if let text = row["extra"] as? String, let data = text.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return dict }
            return [:]
        }()
        let unified = extra["unified"] as? [String: Any] ?? [:]
        let headers = unified["headers"] as? [String: Any] ?? [:]
        let history = extra["window_history"] as? [String: Any] ?? [:]
        let updated = isoEpoch(row["updated_at"]) ?? isoEpoch(unified["updated_at"])
        let lastUsed = isoEpoch(row["last_used_at"])

        func number(_ value: Any?) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        func percent(_ value: Double) -> QuotaWindow? {
            let pct = min(100, max(0, value))
            return QuotaWindow(usedPct: Int(pct.rounded()), resetsAt: nil, capturedAt: nil,
                               windowSeconds: 0, rawUsedPercent: pct)
        }
        func epoch(_ value: Any?) -> TimeInterval? {
            if let n = number(value), n > 0, n <= 253402300799 { return n }
            if let text = value as? String, let n = Double(text), n > 0, n <= 253402300799 { return n }
            return isoEpoch(value)
        }
        func makeWindow(_ raw: Any?, seconds: Double, captured: TimeInterval?) -> QuotaWindow? {
            guard let dict = raw as? [String: Any], let ratio = number(dict["utilization"]), ratio >= 0 else { return nil }
            let pct = min(100, max(0, ratio * 100))
            let reset = epoch(dict["reset"])
            return QuotaWindow(usedPct: Int(pct.rounded()), resetsAt: reset, capturedAt: captured,
                               windowSeconds: seconds, rawUsedPercent: pct)
        }
        let sampled = isoEpoch(headers["sampled_at"])
        func headerWindow(_ key: String, seconds: Double) -> QuotaWindow? {
            makeWindow(headers[key], seconds: seconds, captured: sampled)
        }
        func historyWindow(_ key: String, seconds: Double) -> QuotaWindow? {
            guard let current = (history[key] as? [String: Any])?["current"] as? [String: Any],
                  let ratio = number(current["used_ratio"]), ratio >= 0 else { return nil }
            let pct = min(100, max(0, ratio * 100))
            let reset = isoEpoch(current["reset"])
            return QuotaWindow(usedPct: Int(pct.rounded()), resetsAt: reset, capturedAt: lastUsed ?? updated,
                               windowSeconds: seconds, rawUsedPercent: pct)
        }
        func officialWindow(_ key: String, seconds: Double) -> QuotaWindow? {
            guard let official = unified[key] as? [String: Any],
                  let ratio = number(official["utilization"]), ratio >= 0 else { return nil }
            // A reset-less zero is "never observed", not a confirmed empty window. SQLite/JSON nulls
            // bridge to NSNull, which is non-nil, so test the value explicitly.
            let resetValue = official["reset"]
            let hasReset = resetValue != nil && !(resetValue is NSNull)
            guard hasReset || ratio > 0 else { return nil }
            return makeWindow(official, seconds: seconds, captured: isoEpoch(unified["updated_at"]) ?? updated)
        }
        let five = headerWindow("5h", seconds: 5 * 3600) ?? historyWindow("5h", seconds: 5 * 3600)
            ?? officialWindow("5h", seconds: 5 * 3600)
        let week = headerWindow("7d", seconds: 7 * 86400) ?? historyWindow("7d", seconds: 7 * 86400)
            ?? officialWindow("7d", seconds: 7 * 86400)
        var account = Account(vmID: vmID, host: host, provider: .claude, fiveHour: five, sevenDay: week,
                              variant: (row["type"] as? String) ?? "")
        let status = ((row["session_window_status"] as? String) ?? "").lowercased()
        if status.contains("revok") || status.contains("expir") {
            account.note = L("OAuth 已失效", "OAuth expired")
        } else if let state = row["status"] as? String, state != "active" {
            account.note = L("已停用", "Disabled")
        } else if let schedulable = row["schedulable"] as? NSNumber, schedulable.intValue == 0 {
            account.note = L("不可调度", "Not schedulable")
        } else if !account.hasWindows {
            account.note = L("Claude 无样本", "No Claude sample")
        }
        return account
    }

    static func isoEpoch(_ value: Any?) -> TimeInterval? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date.timeIntervalSince1970 }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)?.timeIntervalSince1970
    }

    /// Keep seven days without growing the file: 5-minute buckets for a day, 30-minute for two more, 2-hour after.
    static func downsample(_ samples: [Sample], now: TimeInterval) -> [Sample] {
        guard samples.count > 2 else { return samples }
        var buckets: [Int: Sample] = [:]
        for sample in samples.sorted(by: { $0.at < $1.at }) {
            guard sample.at.isFinite, sample.pct.isFinite, sample.at > 0, sample.at <= now + 300 else { continue }
            let age = max(0, now - sample.at)
            let width: TimeInterval = age <= 6 * 3600 ? 300 : age <= 48 * 3600 ? 1800 : 7200
            let key = Int(sample.at / width)
            if let old = buckets[key], old.at >= sample.at { continue }
            buckets[key] = sample
        }
        return buckets.values.sorted { $0.at < $1.at }.filter { now - $0.at <= 7 * 86400 }
    }

    static func selfTest() {
        let fixture = #"""
        {"codex":{"vms":{"vm-03":{"confirmed":{"five_hour":{"used_percent":0,"reset_at":1793394751,"observed_at":1793376752},"seven_day":{"used_percent":100,"reset_at":1793774339,"observed_at":1793376752}}},"vm-04":{"confirmed":{}}}},
         "claude":[
          {"vm_id":"vm-01","type":"oauth","status":"active","schedulable":1,"updated_at":"2026-11-02T20:09:44.958Z","last_used_at":"2026-11-02T20:09:44.955Z","session_window_status":"allowed","extra":{"unified":{"5h":{"utilization":0,"reset":null},"7d":{"utilization":0,"reset":null},"headers":{"5h":{"utilization":0.56,"reset":"1793653200"},"7d":{"utilization":0.9,"reset":"1793991600"},"sampled_at":"2026-11-02T20:09:44.957Z"},"updated_at":"2026-11-02T20:09:44.957Z"}}},
          {"vm_id":"vm-03","type":"oauth","status":"active","schedulable":1,"updated_at":"2026-10-21T03:31:05.102Z","extra":{"unified":{"5h":{"utilization":0,"reset":null},"7d":{"utilization":0,"reset":null}}}},
          {"vm_id":"vm-08","type":"oauth","status":"active","schedulable":1,"updated_at":"2026-11-02T04:03:50.367Z","extra":{}},
          {"vm_id":"vm-08","type":"oauth","status":"active","schedulable":1,"updated_at":"2026-11-03T09:14:10.269Z","last_used_at":"2026-11-03T09:14:10.266Z","extra":{"unified":{"headers":{"5h":{"utilization":0.01,"reset":"1793710800"},"7d":{"utilization":0.04,"reset":"1794211200"},"sampled_at":"2026-11-03T09:14:10.268Z"}}}}
         ],"codex_error":"","claude_error":""}
        """#
        switch parse(Data(fixture.utf8), host: "jp-elaina", now: 1_800_000_000) {
        case .failure(let error):
            preconditionFailure("vm2api fixture: \(error.message)")
        case .success(let envelope):
            precondition(envelope.accounts.count == 5, "three Claude VMs + two Codex VMs, duplicate vm-08 collapsed")
            let claude = envelope.accounts.filter { $0.provider == .claude }
            let codex = envelope.accounts.filter { $0.provider == .codex }
            precondition(claude.count == 3 && codex.count == 2)
            let one = claude.first { $0.vmID == "vm-01" }!
            precondition(one.fiveHour?.usedPct == 56 && one.sevenDay?.usedPct == 90)
            precondition(one.fiveHour?.resetsAt == 1_793_653_200)
            let three = claude.first { $0.vmID == "vm-03" }!
            precondition(!three.hasWindows && !three.note.isEmpty)
            let eight = claude.first { $0.vmID == "vm-08" }!
            precondition(eight.fiveHour?.usedPct == 1 && eight.sevenDay?.usedPct == 4, "freshest duplicate wins")
            let codexThree = codex.first { $0.vmID == "vm-03" }!
            precondition(codexThree.sevenDay?.usedPct == 100 && codexThree.fiveHour?.windowSeconds == 18000)
            precondition(codex.first { $0.vmID == "vm-04" }?.hasWindows == false)
        }
        let minutes = 7 * 24 * 60
        var samples: [Sample] = []
        samples.reserveCapacity(minutes)
        for minute in 0..<minutes {
            samples.append(Sample(at: 1_800_000_000 - Double(minutes - minute) * 60, pct: Double(minute % 100)))
        }
        let kept = downsample(samples, now: 1_800_000_000)
        precondition(kept.count > 100 && kept.count < samples.count / 2)
        precondition(kept.last?.at == samples.last?.at)
    }
}

/// Observable cache for vm2api. One SSH round-trip reads Codex's quota cache and vm2api's Claude accounts;
/// the UI only reads the published snapshot. History is sampled in the background so 24-hour deltas exist
/// even when the panel stayed closed.
final class VM2APIQuotaStore: ObservableObject {
    static let shared = VM2APIQuotaStore()

    struct Snapshot: Equatable {
        var accounts: [VM2APIQuota.Account] = []
        var hosts: [String] = []
        var fetchedAt: TimeInterval = 0
        var attemptedAt: TimeInterval = 0
        var error = ""
        var codexError = ""
        var claudeError = ""
    }

    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var history: [String: [String: [VM2APIQuota.Sample]]] = [:]

    private let worker = DispatchQueue(label: "vibedeck.vm2api-quota", qos: .utility)
    private let lock = NSLock()
    private var inFlight = false
    private var lastAttempt: TimeInterval = 0
    private let cacheURL: URL
    private let legacyURL: URL
    private var loadedHistory = false
    private var timer: Timer?

    init(cacheURL: URL? = nil) {
        let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/vibedeck")
        self.cacheURL = cacheURL ?? config.appendingPathComponent("vm2api-quotas.json")
        self.legacyURL = config.appendingPathComponent("claude-vm-quotas.json")
    }

    func start() {
        guard timer == nil else { return }
        refreshIfNeeded(force: true)
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in self?.refreshIfNeeded() }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refreshIfNeeded(force: Bool = false) {
        let now = Date().timeIntervalSince1970
        let hosts = VM2APIQuota.configuredHosts()
        lock.lock()
        let due = !inFlight && (force || now - lastAttempt >= 60)
        if due { inFlight = true; lastAttempt = now }
        lock.unlock()
        guard due else { return }
        loadHistoryIfNeeded()
        let codexPath = VM2APIQuota.configuredCodexPath()
        let dbPath = VM2APIQuota.configuredDBPath()
        worker.async { [weak self] in
            guard let self else { return }
            var accounts: [VM2APIQuota.Account] = []
            var errors: [String] = []
            var codexErrors: [String] = []
            var claudeErrors: [String] = []
            var succeeded = false
            for host in hosts {
                switch VM2APIQuota.fetch(host: host, codexPath: codexPath, dbPath: dbPath) {
                case .success(let envelope):
                    accounts += envelope.accounts
                    succeeded = true
                    if !envelope.codexError.isEmpty { codexErrors.append("\(host)：\(envelope.codexError)") }
                    if !envelope.claudeError.isEmpty { claudeErrors.append("\(host)：\(envelope.claudeError)") }
                case .failure(let error):
                    errors.append("\(host)：\(error.message)")
                }
            }
            let merged = Self.unique(accounts)
            var message = errors.joined(separator: "；")
            if hosts.isEmpty { message = L("没有配置 vm2api 主机", "No vm2api host configured") }
            let codexMessage = codexErrors.joined(separator: "；")
            let claudeMessage = claudeErrors.joined(separator: "；")
            DispatchQueue.main.async {
                self.lock.lock(); self.inFlight = false; self.lock.unlock()
                var next = self.snapshot
                next.hosts = hosts
                next.attemptedAt = now
                if succeeded {
                    next.accounts = merged
                    next.fetchedAt = now
                    next.error = message
                    next.codexError = codexMessage
                    next.claudeError = claudeMessage
                } else {
                    next.error = message
                }
                if next != self.snapshot { self.snapshot = next }
                if succeeded { self.mergeHistory(merged) }
            }
        }
    }

    private static func unique(_ accounts: [VM2APIQuota.Account]) -> [VM2APIQuota.Account] {
        var byID: [String: VM2APIQuota.Account] = [:]
        for account in accounts { byID[account.id] = account }
        return byID.values.sorted { a, b in
            if a.provider != b.provider { return a.provider == .claude }
            if a.host != b.host { return a.host < b.host }
            return a.vmID.localizedStandardCompare(b.vmID) == .orderedAscending
        }
    }

    private func loadHistoryIfNeeded() {
        lock.lock()
        let needed = !loadedHistory
        if needed { loadedHistory = true }
        lock.unlock()
        guard needed else { return }
        if let data = try? Data(contentsOf: cacheURL),
           let decoded = try? JSONDecoder().decode([String: [String: [VM2APIQuota.Sample]]].self, from: data) {
            DispatchQueue.main.async { self.history = decoded }
            return
        }
        // The old cache only held Codex VM readings; move them under their new provider-qualified keys.
        guard let data = try? Data(contentsOf: legacyURL),
              let old = try? JSONDecoder().decode([String: [String: [VM2APIQuota.Sample]]].self, from: data),
              !old.isEmpty else { return }
        var migrated: [String: [String: [VM2APIQuota.Sample]]] = [:]
        for (key, windows) in old {
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            migrated["vm2api:codex:\(parts[0]):\(parts[1])"] = windows
        }
        DispatchQueue.main.async { self.history = migrated }
    }

    private func mergeHistory(_ accounts: [VM2APIQuota.Account]) {
        let now = Date().timeIntervalSince1970
        var changed = false
        for account in accounts {
            for (window, quota) in [("5h", account.fiveHour), ("week", account.sevenDay)] {
                guard let quota, let at = quota.capturedAt, at > 0 else { continue }
                let pct = quota.rawUsedPercent ?? Double(quota.usedPct)
                guard pct.isFinite else { continue }
                var samples = history[account.id]?[window] ?? []
                if let last = samples.last, at <= last.at + 1, abs(last.pct - pct) < 0.01 { continue }
                samples.append(.init(at: at, pct: pct))
                history[account.id, default: [:]][window] = VM2APIQuota.downsample(samples, now: now)
                changed = true
            }
        }
        if changed { saveHistory() }
    }

    private func saveHistory() {
        let copy = history
        let url = cacheURL
        worker.async {
            guard let data = try? JSONEncoder().encode(copy) else { return }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try data.write(to: url, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch { /* History is a convenience; live quotas still work. */ }
        }
    }
}
