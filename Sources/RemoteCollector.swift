import Foundation
import Darwin
import CoreFoundation

/// 远程用量采集：把本机 Resources/vibauge-collector.py 经 ssh 的 stdin 送到远端执行，
/// 收回 opencode 的 JSONL 用量行。远端无需安装任何东西 —— 只要有个 python3。
enum RemoteCollector {
    private static let discoveryLock = NSLock()
    private static var discovered: [(target: String, label: String)] = []
    private static var discoveryAt: TimeInterval = 0
    private static var discoveryInFlight = false

    /// UI reads only cached labels; discovery never starts a subprocess on the caller's thread.
    static func displayName(for target: String) -> String {
        discoveryLock.lock(); defer { discoveryLock.unlock() }
        return discovered.first { $0.target == target }?.label ?? target
    }

    static func parseHerdrMachines(_ text: String) -> [(target: String, label: String)]? {
        guard let data = text.data(using: .utf8),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        var seen = Set<String>()
        return rows.compactMap { row in
            guard let enabled = row["enabled"] as? NSNumber,
                  CFGetTypeID(enabled) == CFBooleanGetTypeID(), enabled.boolValue,
                  let target = row["target"] as? String, ProcessScanner.isValidSSHHost(target),
                  seen.insert(target).inserted else { return nil }
            let label = (row["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (target, label.isEmpty ? target : label)
        }
    }

    static func refreshDiscoveryIfDue(force: Bool = false, completion: (() -> Void)? = nil) {
        discoveryLock.lock()
        let now = Date().timeIntervalSince1970
        guard !discoveryInFlight, force || now - discoveryAt >= 60 else {
            discoveryLock.unlock(); completion?(); return
        }
        discoveryInFlight = true
        discoveryAt = now
        discoveryLock.unlock()
        DispatchQueue.global(qos: .utility).async {
            defer {
                discoveryLock.lock(); discoveryInFlight = false; discoveryLock.unlock()
                completion?()
            }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let candidates = ["\(home)/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"]
            guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
                  case .success(let text) = runProcess(executable: path, arguments: ["machine", "list", "--json"], timeout: 5, maxBytes: 1024 * 1024),
                  let machines = parseHerdrMachines(text) else { return }
            discoveryLock.lock(); discovered = machines; discoveryLock.unlock()
        }
    }
    /// 拉取失败的原因，一句话，直接显示在面板上。
    struct RemoteFailure: Error {
        let message: String
    }

    /// 采集脚本，随 app bundle 一起分发。
    static func script() -> String? {
        guard let url = Bundle.main.url(forResource: "vibedeck-collector", withExtension: "py") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// `remoteHosts`（空格 / 逗号 / 分号分隔）加上旧的单机 `codexRemoteHost`；逐个校验并去重。
    static func hosts() -> [String] {
        var raw: [String] = []
        for key in ["remoteHosts", "codexRemoteHost"] {
            guard let value = UserDefaults.standard.string(forKey: key) else { continue }
            raw += value.split { ", ;\n\t".contains($0) }.map(String.init)
        }
        discoveryLock.lock(); raw += discovered.map { $0.target }; discoveryLock.unlock()
        var seen = Set<String>()
        return raw.compactMap { candidate in
            let host = candidate.trimmingCharacters(in: .whitespaces)
            guard ProcessScanner.isValidSSHHost(host), seen.insert(host).inserted else { return nil }
            return host
        }
    }

    /// 拉一台主机的 opencode 用量。失败返回一句短原因，调用方保留上次记录。
    static func pullUsage(host: String, since: Int64) -> Result<(records: [UsageHistory.Record], maxUpdated: Int64), RemoteFailure> {
        guard let script = script() else { return .failure(RemoteFailure(message: "读不到采集脚本")) }
        let output: String
        switch run(host: host, script: script, arguments: ["--since", String(max(0, since))]) {
        case .success(let text): output = text
        case .failure(let reason): return .failure(reason)
        }
        let parsed = parse(jsonl: output, source: "OpenCode · \(host)")
        guard parsed.ok else { return .failure(RemoteFailure(message: "远端没返回成功哨兵")) }
        return .success((parsed.records, parsed.maxUpdated))
    }

    /// 纯函数：解析采集脚本的 JSONL。坏行直接跳过，最后一行是 `{"__ok__":…}` 哨兵。
    static func parse(jsonl: String, source: String) -> (records: [UsageHistory.Record], maxUpdated: Int64, ok: Bool) {
        var rows: [OpenCodeUsage.Row] = []
        var maxUpdated: Int64 = 0
        var ok = false
        for line in jsonl.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let sentinel = object["__ok__"] as? Bool {
                ok = sentinel
                maxUpdated = max(maxUpdated, (object["max_u"] as? NSNumber)?.int64Value ?? 0)
                continue
            }
            guard let id = object["id"] as? String, !id.isEmpty,
                  let createdAt = (object["t"] as? NSNumber)?.doubleValue else { continue }
            maxUpdated = max(maxUpdated, (object["u"] as? NSNumber)?.int64Value ?? 0)
            func count(_ key: String) -> Int64 {
                guard let number = object[key] as? NSNumber, number.int64Value > 0 else { return 0 }
                return number.int64Value
            }
            rows.append(OpenCodeUsage.Row(
                id: id, session: object["s"] as? String, provider: object["p"] as? String ?? "",
                model: object["m"] as? String ?? "", createdAt: createdAt,
                input: count("in"), output: count("out"), reasoning: count("r"),
                cacheRead: count("cr"), cacheWrite: count("cw"), seconds: finiteNumber(object["seconds"])))
        }
        return (Array(OpenCodeUsage.records(rows: rows, source: source).values), maxUpdated, ok)
    }

    /// 跑一段远端 shell 命令。带墙钟超时与输出上限 —— 老 execute() 会一直阻塞到 EOF 且不限大小。
    /// `command` 由本模块自己拼，host 已经过 isValidSSHHost 校验；stderr 直接丢弃，免得没人读的管道写满把子进程卡死。
    static func runRemote(host: String, command: String, stdin: Data? = nil,
                          timeout: TimeInterval = 25, maxBytes: Int = 64 * 1024 * 1024) -> Result<String, RemoteFailure> {
        guard ProcessScanner.isValidSSHHost(host) else { return .failure(RemoteFailure(message: L("无效 SSH 目标", "Invalid SSH target"))) }
        return runProcess(executable: "/usr/bin/ssh", arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=4", "-o", "ServerAliveInterval=5",
                             "--", host, command], stdin: stdin, timeout: timeout, maxBytes: maxBytes)
    }

    private static func runProcess(executable: String, arguments: [String], stdin: Data? = nil,
                                   timeout: TimeInterval, maxBytes: Int) -> Result<String, RemoteFailure> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        // A failed SSH peer can close stdin before the script is written.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let deadline = DispatchTime.now() + timeout
        do { try process.run() } catch { return .failure(RemoteFailure(message: L("采集进程无法启动", "Cannot start collector"))) }
        if let stdin {
            DispatchQueue.global(qos: .utility).async {
                try? input.fileHandleForWriting.write(contentsOf: stdin)
                try? input.fileHandleForWriting.close()
            }
        }

        let box = Output()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            var buffer = Data()
            while true {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                if buffer.count >= maxBytes { break }
            }
            box.data = buffer
            finished.signal()
        }
        let waited = finished.wait(timeout: deadline)
        if waited == .timedOut || box.data.count >= maxBytes {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return .failure(RemoteFailure(message: waited == .timedOut ? L("采集超时（\(Int(timeout))s）", "Collection timed out (\(Int(timeout))s)") : L("采集输出超过上限", "Collection output exceeded limit")))
        }
        guard exited.wait(timeout: deadline) == .success else {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return .failure(RemoteFailure(message: L("采集超时（\(Int(timeout))s）", "Collection timed out (\(Int(timeout))s)")))
        }
        guard process.terminationStatus == 0 else {
            // A device without opencode is not a connection failure; say what it is.
            if String(decoding: box.data, as: UTF8.self).contains("db not found") {
                return .failure(RemoteFailure(message: L("此设备未安装 opencode", "opencode not installed on this device")))
            }
            return .failure(RemoteFailure(message: L("采集退出码 \(process.terminationStatus)", "Collector exit code \(process.terminationStatus)")))
        }
        return .success(String(decoding: box.data, as: UTF8.self))
    }

    /// 采集器：脚本走 stdin，免得把整段脚本塞进 shell 引号里。
    /// 超时给到 60s：远端库可能几十 GB，冷缓存下第一次全表扫描会慢。
    static func run(host: String, script: String, arguments: [String], timeout: TimeInterval = 60) -> Result<String, RemoteFailure> {
        runRemote(host: host, command: "python3 - " + arguments.joined(separator: " "), stdin: Data(script.utf8), timeout: timeout)
    }

    // MARK: Claude / Codex 逐条记录（WSL / Linux 远程日统计）

    /// 拉一台主机上 mtime > since 的 Claude / Codex 日志里的逐条请求。输出是压缩过的一行 base64。
    /// 首次（since = 0）要扫全部历史，超时放宽到 150s。
    struct CLIRecordBatch {
        var records: [UsageHistory.Record] = []
        var maxMtime: Int64 = 0
        var ok: Bool = false
        var turnLatencies: [TurnLatencySample] = []
        var sessionAccounts: [String: AccountIdentity] = [:]
    }

    static func pullCLIRecords(host: String, since: Int64, includeIdentityBackfill: Bool = false) -> Result<CLIRecordBatch, RemoteFailure> {
        guard let script = script() else { return .failure(RemoteFailure(message: "读不到采集脚本")) }
        let arguments = ["--records", "--since", String(max(0, since)), "--gz"] + (includeIdentityBackfill ? ["--identity-backfill"] : [])
        switch run(host: host, script: script, arguments: arguments,
                   timeout: since == 0 ? 150 : 60) {
        case .failure(let reason): return .failure(reason)
        case .success(let text):
            guard let jsonl = inflate(text) else { return .failure(RemoteFailure(message: "远端输出解不开（采集脚本太旧？）")) }
            let parsed = parseCLIRecords(jsonl: jsonl, host: host)
            guard parsed.ok else { return .failure(RemoteFailure(message: "远端没返回成功哨兵")) }
            return .success(parsed)
        }
    }

    /// `{` 开头 = 明文 JSONL；否则是 base64(raw deflate)。
    static func inflate(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.isEmpty { return trimmed }
        guard let blob = Data(base64Encoded: trimmed),
              let raw = try? (blob as NSData).decompressed(using: .zlib) else { return nil }
        return String(decoding: raw as Data, as: UTF8.self)
    }

    /// 纯函数：解析 `--records` 的 JSONL。来源记成 `Claude · host` / `Codex · host`，id 加种类前缀免得撞车。
    static func parseCLIRecords(jsonl: String, host: String) -> CLIRecordBatch {
        var batch = CLIRecordBatch()
        for line in jsonl.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let sentinel = o["__ok__"] as? Bool {
                batch.ok = sentinel
                batch.maxMtime = max(batch.maxMtime, (o["max_mtime"] as? NSNumber)?.int64Value ?? 0)
                continue
            }
            let account = parseAccountIdentity(o)
            if o["k"] as? String == "account_session", o["cli"] as? String == "codex",
               let session = o["s"] as? String, !session.isEmpty, let account {
                batch.sessionAccounts[session] = account
                continue
            }
            if o["k"] as? String == "codex_turn" || o["k"] as? String == "claude_turn" {
                guard let turnID = o["turn_id"] as? String, !turnID.isEmpty,
                      let completion = epoch(o["t"]), let milliseconds = finiteNumber(o["ttft_ms"]), milliseconds >= 0 else { continue }
                let tool = o["k"] as? String == "claude_turn" ? "Claude" : "Codex"
                let source = host.isEmpty ? tool : tool + " · " + host
                let model = (o["m"] as? String).flatMap { $0.isEmpty || $0 == "?" ? nil : $0 }
                let failed = (o["failed"] as? Bool ?? false) || (o["error"] != nil && !(o["error"] is NSNull))
                batch.turnLatencies.append(TurnLatencySample(turnID: turnID, source: source, timestamp: completion,
                    milliseconds: milliseconds, startedAt: epoch(o["started_at"]), model: model, account: account, failed: failed))
                continue
            }
            guard let kind = o["k"] as? String, kind == "claude" || kind == "codex",
                  let id = o["id"] as? String, !id.isEmpty,
                  let t = epoch(o["t"]) else { continue }
            func n(_ key: String) -> Int64 { max(0, (o[key] as? NSNumber)?.int64Value ?? 0) }
            let label = kind == "claude" ? "Claude" : "Codex"
            let source = host.isEmpty ? label : label + " · " + host
            let model = (o["m"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?"
            let usage = UsageHistory.ModelTotals(ctx: n("in"), cacheRead: n("cr"), cacheWrite: n("cw"), out: n("out"), think: n("th"))
            let c1 = n("c1")
            var record = UsageHistory.Record(id: kind + ":" + id, source: source, timestamp: t, model: model, usage: usage,
                                               session: o["s"] as? String, cw1h: c1 > 0 ? c1 : nil, tier: o["tier"] as? String,
                                               timing: finiteNumber(o["seconds"]).map { PerformanceTiming(seconds: $0) })
            record.account = account
            batch.records.append(record)
        }
        return batch
    }

    /// 面板上的「设备」：ssh 主机 + 挂载目录标签（去重，ssh 在前）。
    static func devices() -> [String] {
        var out = hosts()
        for root in UsageHistory.mountRoots() where !out.contains(root.label) { out.append(root.label) }
        return out
    }

    /// 远端「今日」汇总（采集器 `--summary` 模式的输出）。
    struct Summary {
        struct Today {
            var ctx: Int64 = 0
            var cacheRead: Int64 = 0
            var cacheWrite: Int64 = 0
            var out: Int64 = 0
            var think: Int64 = 0
            var requests: Int = 0
        }
        /// key = "opencode" / "codex" / "claude"（远端没有的 CLI 直接不出现在这里）
        var today: [String: Today] = [:]
        /// 原样带回的 ~/.claude/claude-usage.json（没有就是 nil）
        var claudeUsage: [String: Any]?
        var platforms: [DetectedLLMRuntime] = []
        /// nil: unsupported/unavailable, []: a successful empty process inventory.
        var codexProcesses: [CodexProcessInfo]?
        var codexProcessesLimited: Bool = true
        /// Current CLI login facts, never inferred from quota/session history.
        var accountPresence: [AccountPresence]?
    }

    static func pullSummary(host: String) -> Result<Summary, RemoteFailure> {
        guard let script = script() else { return .failure(RemoteFailure(message: "读不到采集脚本")) }
        switch run(host: host, script: script, arguments: ["--summary"]) {
        case .failure(let error): return .failure(error)
        case .success(let text):
            guard let summary = parseSummary(text, host: host) else { return .failure(RemoteFailure(message: "远端汇总无法解析")) }
            return .success(summary)
        }
    }

    /// Separate cheap snapshots from the historical --summary scan.
    static func pullQuotas(host: String) -> Result<[DetectedLLMRuntime], RemoteFailure> {
        guard let script = script() else { return .failure(RemoteFailure(message: "读不到采集脚本")) }
        switch run(host: host, script: script, arguments: ["--quotas"], timeout: 15) {
        case .failure(let error): return .failure(error)
        case .success(let text):
            guard let rows = parseQuotas(text) else { return .failure(RemoteFailure(message: L("远端额度无法解析", "Cannot parse remote quotas"))) }
            return .success(rows)
        }
    }

    /// JSON booleans bridge to NSNumber too; reject them and all nonfinite values.
    static func finiteNumber(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    static func parseAccountIdentity(_ fields: [String: Any], prefix: String = "account_") -> AccountIdentity? {
        guard let provider = fields[prefix + "provider"] as? String,
              let subject = fields[prefix + "id"] as? String else { return nil }
        return AccountIdentity(provider: provider, accountID: subject, workspaceID: fields[prefix + "workspace"] as? String)
    }

    private static func epoch(_ value: Any?) -> TimeInterval? {
        // Beyond year 9999 cannot be represented reliably by downstream date formatters.
        finiteNumber(value).flatMap { $0 > 0 && $0 <= 253402300799 ? $0 : nil }
    }

    static func parseQuotaWindow(_ value: Any?, capturedAt: TimeInterval? = nil) -> QuotaWindow? {
        guard let raw = value as? [String: Any], let used = finiteNumber(raw["used_percentage"]),
              (0...100).contains(used) else { return nil }
        let reset = epoch(raw["resets_at"])
        let captured = epoch(raw["captured_at"]) ?? epoch(capturedAt)
        let seconds = finiteNumber(raw["window_seconds"]).flatMap { $0 > 0 ? $0 : nil } ?? 0
        return QuotaWindow(usedPct: Int(used.rounded()), resetsAt: reset, capturedAt: captured, windowSeconds: seconds, rawUsedPercent: used)
    }

    static func parseQuotas(_ text: String) -> [DetectedLLMRuntime]? {
        var platforms: [String: Any]?
        var ok = false
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let sentinel = raw["__ok__"] as? NSNumber, CFGetTypeID(sentinel) == CFBooleanGetTypeID() { ok = sentinel.boolValue }
            if let summary = raw["__summary__"] as? [String: Any], let entries = summary["platforms"] as? [String: Any] { platforms = entries }
        }
        guard ok, let platforms else { return nil }
        return [("claude", "Claude"), ("codex", "Codex"), ("grok", "Grok"), ("agy", "Antigravity")].compactMap { key, name in
            guard let row = platforms[key] as? [String: Any] else { return nil }
            let quota = row["quota"] as? [String: Any] ?? [:]
            let captured = epoch(row["captured_at"])
            let sessions = finiteNumber(row["sessions"]).flatMap { $0 >= 0 && $0 < Double(Int.max) && $0.rounded(.towardZero) == $0 ? Int($0) : nil }
            let sessionUnknown = row["note"] as? String == "session_count_unavailable" || sessions == nil
            let extraName = quota["secondary_name"] as? String ?? ""
            let runtime = DetectedLLMRuntime(
                name: name, isRunning: !sessionUnknown && (sessions ?? 0) > 0,
                tier: row["tier"] as? String ?? "",
                detail: sessionUnknown ? L("会话数未知", "Sessions unknown") : L("\(sessions ?? 0) 会话", "\(sessions ?? 0) sessions"),
                fiveHour: parseQuotaWindow(quota["five_hour"], capturedAt: captured),
                sevenDay: parseQuotaWindow(quota["seven_day"], capturedAt: captured),
                secondaryPoolName: extraName,
                secondaryFiveHour: parseQuotaWindow(quota["secondary_five_hour"], capturedAt: captured),
                secondarySevenDay: parseQuotaWindow(quota["secondary_seven_day"], capturedAt: captured),
                isFullWidth: !extraName.isEmpty,
                quotaSubtitle: L("未采集到额度", "Quota unavailable"),
                account: parseAccountIdentity(row), secondaryAccount: parseAccountIdentity(row, prefix: "secondary_account_"))
            return runtime
        }
    }

    /// 纯函数：解析 `--summary` 的输出。哨兵说失败就返回 nil。
    static func parseSummary(_ text: String, host: String = "") -> Summary? {
        var parsed: Summary?
        var ok = false
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if object["__ok__"] != nil {
                ok = (object["__ok__"] as? Bool) ?? false
                continue
            }
            guard let raw = object["__summary__"] as? [String: Any] else { continue }
            var summary = Summary()
            if let today = raw["today"] as? [String: Any] {
                for (key, value) in today {
                    guard let entry = value as? [String: Any] else { continue }
                    func count(_ name: String) -> Int64 { max(0, (entry[name] as? NSNumber)?.int64Value ?? 0) }
                    summary.today[key] = Summary.Today(
                        ctx: count("ctx"), cacheRead: count("cache_read"), cacheWrite: count("cache_write"),
                        out: count("out"), think: count("think"),
                        requests: Int(max(0, (entry["requests"] as? NSNumber)?.intValue ?? 0)))
                }
            }
            summary.claudeUsage = raw["claude_usage"] as? [String: Any]
            summary.platforms = parseQuotas(text) ?? []
            summary.accountPresence = parseAccountPresence(raw["account_presence"], host: host)
            summary.codexProcesses = parseCodexProcesses(raw["codex_processes"], host: host)
            if summary.codexProcesses != nil,
               let limited = raw["codex_processes_limited"] as? NSNumber,
               CFGetTypeID(limited) == CFBooleanGetTypeID() {
                summary.codexProcessesLimited = limited.boolValue || summary.codexProcesses!.contains { $0.observationLimited }
            }
            parsed = summary
        }
        return ok ? parsed : nil
    }

    /// Remote identity is the configured SSH host, never a host name supplied by the peer.
    static func parseCodexProcesses(_ value: Any?, host: String) -> [CodexProcessInfo]? {
        guard ProcessScanner.isValidSSHHost(host), let rows = value as? [[String: Any]], rows.count <= 256,
              JSONSerialization.isValidJSONObject(rows), let data = try? JSONSerialization.data(withJSONObject: rows),
              let decoded = try? JSONDecoder().decode([CodexProcessInfo].self, from: data) else { return nil }
        func pathValid(_ path: String?) -> Bool {
            guard let path else { return true }
            return path.utf8.count <= 4096 && !path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        var instances = Set<String>()
        var sessionIDs = Set<String>()
        var result: [CodexProcessInfo] = []
        for row in decoded {
            let parts = row.instanceID.split(separator: ":", omittingEmptySubsequences: false)
            guard row.source == .linuxProc, row.pid > 0, row.pid <= Int32.max, row.parentPID >= 0, row.parentPID <= Int32.max,
                  parts.count == 3, parts[0] == String(row.pid), UUID(uuidString: String(parts[1])) != nil,
                  let ticks = UInt64(parts[2]), ticks > 0,
                  instances.insert(row.instanceID).inserted,
                  row.startedAt.isFinite, row.startedAt > 0, row.startedAt <= 253402300799,
                  row.sampledAt.isFinite, row.sampledAt >= row.startedAt, row.sampledAt <= 253402300799,
                  row.memMB.isFinite, row.memMB >= 0, pathValid(row.cwd), row.sessions.count <= 64 else { return nil }
            for session in row.sessions {
                guard UUID(uuidString: session.id) != nil, sessionIDs.insert(session.id.lowercased()).inserted,
                      pathValid(session.cwd), [.active, .idle, .unknown].contains(session.state),
                      (session.state == .active && session.basis == .turnStarted ||
                       session.state == .idle && session.basis == .turnEnded ||
                       session.state == .unknown && [.noLifecycleEvidence, .partialObservation].contains(session.basis)) else { return nil }
                if let at = session.observedAt {
                    guard at.isFinite, at >= row.startedAt, at <= row.sampledAt + 5 else { return nil }
                } else if session.state != .unknown { return nil }
            }
            let expected: CodexStateBasis
            switch row.state {
            case .active:
                guard row.sessions.contains(where: { $0.state == .active }) else { return nil }
                expected = .turnStarted
            case .idle:
                guard !row.observationLimited, !row.sessions.isEmpty, row.sessions.allSatisfy({ $0.state == .idle }) else { return nil }
                expected = .turnEnded
            case .stopped: expected = .kernelStopped
            case .unresponsive: expected = .kernelZombie
            case .unknown: expected = row.observationLimited ? .partialObservation : .noLifecycleEvidence
            }
            guard row.basis == expected else { return nil }
            result.append(CodexProcessInfo(deviceID: host, source: .linuxProc, instanceID: row.instanceID, pid: row.pid,
                                           parentPID: row.parentPID, role: row.role, cwd: row.cwd, startedAt: row.startedAt,
                                           sampledAt: row.sampledAt, memMB: row.memMB, state: row.state, basis: row.basis,
                                           sessions: row.sessions, observationLimited: row.observationLimited))
        }
        return result.sorted { $0.pid < $1.pid }
    }

    static func codexProcessCollectorSelfTest() {
        let row: [String: Any] = ["device_id": "forged-device", "source": "linuxProc", "instance_id": "123:00000000-0000-0000-0000-000000000001:10",
                                  "pid": 123, "parent_pid": 1, "role": "appServer", "started_at": 100.0, "sampled_at": 200.0,
                                  "mem_mb": 10.0, "state": "unknown", "basis": "noLifecycleEvidence", "sessions": [], "observation_limited": false]
        let parsed = parseCodexProcesses([row], host: "wsl")!
        precondition(parsed.count == 1 && parsed[0].deviceID == "wsl" && parsed[0].sampledAt == 200)
        var worker = row
        worker["role"] = "worker"; worker["parent_pid"] = 42
        precondition(parseCodexProcesses([worker], host: "devbox")?[0].role == .worker)
        precondition(parseCodexProcesses([], host: "wsl")?.isEmpty == true)
        precondition(parseCodexProcesses(nil, host: "wsl") == nil)
        precondition(parseCodexProcesses([row], host: "") == nil)
        precondition(parseCodexProcesses([row, row], host: "wsl") == nil)
        var active = row
        active["state"] = "active"; active["basis"] = "turnStarted"
        active["sessions"] = [["id": "00000000-0000-0000-0000-000000000002", "state": "active", "basis": "turnStarted", "observed_at": 150.0]]
        precondition(parseCodexProcesses([active], host: "wsl")?[0].sessions.count == 1)
        var stale = active
        stale["sessions"] = [["id": "00000000-0000-0000-0000-000000000002", "state": "active", "basis": "turnStarted", "observed_at": 99.0]]
        precondition(parseCodexProcesses([stale], host: "wsl") == nil)
        for (key, value) in [("pid", true as Any), ("source", "localKernel"), ("started_at", 300), ("state", "idle"), ("instance_id", "123:old") ] {
            var bad = row; bad[key] = value
            precondition(parseCodexProcesses([bad], host: "wsl") == nil)
        }
        let wire = "{\"__summary__\":{\"today\":{\"codex\":{\"ctx\":7,\"requests\":1}},\"codex_processes\":[],\"codex_processes_limited\":false}}\n{\"__ok__\":true}"
        let summary = parseSummary(wire, host: "wsl")!
        precondition(summary.today["codex"]?.ctx == 7 && summary.codexProcesses?.isEmpty == true && !summary.codexProcessesLimited)
        precondition(parseSummary("{\"__summary__\":{}}\n{\"__ok__\":true}", host: "wsl")?.codexProcesses == nil)
        precondition(parseSummary(wire.replacingOccurrences(of: "true}", with: "false}"), host: "wsl") == nil)
    }

    static func parseAccountPresence(_ value: Any?, host: String) -> [AccountPresence]? {
        guard ProcessScanner.isValidSSHHost(host), let rows = value as? [[String: Any]], rows.count <= 2,
              JSONSerialization.isValidJSONObject(rows), let data = try? JSONSerialization.data(withJSONObject: rows),
              let decoded = try? JSONDecoder().decode([AccountPresence].self, from: data) else { return nil }
        var tools = Set<String>()
        var result: [AccountPresence] = []
        for row in decoded {
            guard ["Codex", "Claude"].contains(row.tool), tools.insert(row.tool).inserted,
                  row.sampledAt.isFinite, row.sampledAt > 0, row.sampledAt <= 253402300799 else { return nil }
            if let account = row.account {
                guard account.accountID.utf8.count <= 512, (account.workspaceID?.utf8.count ?? 0) <= 512,
                      row.state == .loggedIn, row.basis == .cliStatus,
                      row.tool == "Codex" && row.method == "chatgpt" && account.provider == "openai" ||
                      row.tool == "Claude" && row.method == "claudeAi" && account.provider == "anthropic" else { return nil }
            }
            switch row.state {
            case .loggedOut:
                guard row.account == nil, row.method == nil, row.basis == .cliStatus else { return nil }
            case .unknown:
                guard row.account == nil, row.method == nil, row.basis == .statusUnavailable else { return nil }
            case .loggedIn:
                let methods = row.tool == "Codex" ? ["chatgpt", "apiKey"] : ["claudeAi", "apiKey", "external"]
                if let method = row.method {
                    guard methods.contains(method) else { return nil }
                    if row.account == nil {
                        guard [.identityUnavailable, .profileMismatch].contains(row.basis),
                              row.basis != .profileMismatch || method == "chatgpt" || method == "claudeAi" else { return nil }
                    }
                } else {
                    // The sole no-method sign-in variant: confirmed first-party
                    // Claude status with an unrecognized method and no bound ID.
                    guard row.tool == "Claude", row.account == nil, row.basis == .identityUnavailable else { return nil }
                }
            }
            result.append(AccountPresence(deviceID: host, tool: row.tool, state: row.state, account: row.account,
                                          sampledAt: row.sampledAt, basis: row.basis, method: row.method))
        }
        return result.sorted { $0.tool < $1.tool }
    }

    static func accountPresenceCollectorSelfTest() {
        let current: [String: Any] = ["device_id": "forged", "tool": "Codex", "state": "loggedIn",
                                      "account": ["provider": "openai", "accountID": "fixture-current"],
                                      "sampled_at": 100, "basis": "cliStatus", "method": "chatgpt"]
        let parsed = parseAccountPresence([current], host: "devbox")!
        precondition(parsed[0].deviceID == "devbox" && parsed[0].isIdentifiedLogin)
        precondition(parseAccountPresence(nil, host: "wsl") == nil)
        precondition(parseAccountPresence([current, current], host: "wsl") == nil)
        for (key, value) in [("state", "loggedOut" as Any), ("tool", "Unknown"), ("method", "apiKey"), ("basis", "profileMismatch"), ("sampled_at", true)] {
            var bad = current; bad[key] = value
            precondition(parseAccountPresence([bad], host: "wsl") == nil)
        }
        let unknown: [String: Any] = ["device_id": "old", "tool": "Claude", "state": "unknown", "sampled_at": 100, "basis": "statusUnavailable"]
        precondition(parseAccountPresence([unknown], host: "wsl")?[0].state == .unknown)
        let unavailableIdentity: [String: Any] = ["device_id": "old", "tool": "Codex", "state": "loggedIn", "sampled_at": 100, "basis": "profileMismatch", "method": "chatgpt"]
        precondition(parseAccountPresence([unavailableIdentity], host: "wsl")?[0].isIdentifiedLogin == false)
        let newMethod: [String: Any] = ["device_id": "old", "tool": "Claude", "state": "loggedIn", "sampled_at": 100, "basis": "identityUnavailable"]
        let unbound = parseAccountPresence([newMethod], host: "wsl")![0]
        precondition(unbound.state == .loggedIn && unbound.method == nil && unbound.account == nil && !unbound.isIdentifiedLogin)
        for (key, value) in [("account", ["provider": "anthropic", "accountID": "stale-id"] as Any),
                             ("basis", "cliStatus"), ("basis", "profileMismatch"), ("basis", "statusUnavailable"),
                             ("method", "future-method"), ("tool", "Codex")] {
            var invalid = newMethod; invalid[key] = value
            precondition(parseAccountPresence([invalid], host: "wsl") == nil)
        }
        var guessedIdentity = newMethod
        guessedIdentity["method"] = "future-method"
        guessedIdentity["account"] = ["provider": "anthropic", "accountID": "stale-id"]
        precondition(parseAccountPresence([guessedIdentity], host: "wsl") == nil)
        let raw = ["__summary__": ["account_presence": [current], "today": ["codex": ["ctx": 7, "requests": 1]]]] as [String: Any]
        let wire = String(data: try! JSONSerialization.data(withJSONObject: raw), encoding: .utf8)! + "\n{\"__ok__\":true}"
        precondition(parseSummary(wire, host: "wsl")?.accountPresence?[0].account?.accountID == "fixture-current")
        precondition(parseSummary(wire, host: "wsl")?.today["codex"]?.requests == 1)
        precondition(parseSummary("{\"__summary__\":{}}\n{\"__ok__\":true}", host: "wsl")?.accountPresence == nil)
    }

    static func accountCollectorSelfTest() {
        codexProcessCollectorSelfTest()
        accountPresenceCollectorSelfTest()
        let wire = """
        {"k":"codex","id":"old","t":1000,"m":"gpt-test","in":10,"out":2}
        {"k":"account_session","cli":"codex","s":"session.jsonl","account_provider":"codex","account_id":"account-a"}
        {"k":"codex","id":"new","t":1001,"in":20,"out":3,"account_provider":"openai","account_id":"account-a"}
        {"k":"codex_turn","turn_id":"turn-a","root_turn_id":"shared","t":1002,"ttft_ms":1250.5,"started_at":1000,"m":"gpt-test","account_provider":"openai","account_id":"account-a"}
        {"k":"codex_turn","turn_id":"turn-b","root_turn_id":"shared","t":1003,"ttft_ms":0}
        {"k":"codex_turn","turn_id":"failed","t":1004,"ttft_ms":30,"failed":true}
        {"k":"codex_turn","turn_id":"error","t":1004,"ttft_ms":31,"error":{}}
        {"k":"codex_turn","turn_id":"negative","t":1004,"ttft_ms":-1}
        {"k":"codex_turn","turn_id":"missing","t":1004}
        {"k":"codex_turn","turn_id":"bool","t":1004,"ttft_ms":true}
        {"k":"codex_turn","turn_id":"nan","t":1004,"ttft_ms":"NaN"}
        {"__ok__":true,"count":2,"max_mtime":123456}
        """
        let a = parseCLIRecords(jsonl: wire, host: "device-a")
        let b = parseCLIRecords(jsonl: wire, host: "device-b")
        precondition(a.ok && a.records.count == 2 && a.maxMtime == 123456)
        precondition(a.records[0].account == nil && a.records[1].account == b.records[1].account)
        precondition(a.sessionAccounts["session.jsonl"] == a.records[1].account)
        precondition(a.turnLatencies.count == 4 && a.turnLatencies[0].milliseconds == 1250.5)
        precondition(a.turnLatencies[0].startedAt == 1000 && a.turnLatencies[0].model == "gpt-test")
        precondition(a.turnLatencies[1].milliseconds == 0 && a.turnLatencies[1].model == nil)
        precondition(a.turnLatencies[0].id != a.turnLatencies[1].id)
        precondition(a.turnLatencies[2].failed && a.turnLatencies[3].failed)
        precondition(a.turnLatencies[0].id != b.turnLatencies[0].id)
        precondition(parseCLIRecords(jsonl: wire, host: "").turnLatencies[0].source == "Codex")
        precondition(!parseCLIRecords(jsonl: "{\"__ok__\":false}", host: "fixture").ok)
        precondition(!parseCLIRecords(jsonl: "{\"k\":\"codex_turn\",\"turn_id\":\"x\",\"t\":1,\"ttft_ms\":1}", host: "fixture").ok)
        precondition(parseAccountIdentity(["account_provider": "claude", "account_id": "a", "account_workspace": "org-1"]) !=
                     parseAccountIdentity(["account_provider": "claude", "account_id": "a", "account_workspace": "org-2"]))
        let quotaWire = """
        {"__summary__":{"platforms":{"codex":{"sessions":1,"account_provider":"openai","account_id":"account-a","quota":{"five_hour":{"used_percentage":30},"secondary_five_hour":{"used_percentage":20}}}}}}
        {"__ok__":true}
        """
        precondition(parseQuotaWindow(["used_percentage": 31.5])?.accountingUsedPercent == 31.5)
        let rows = parseQuotas(quotaWire)!
        precondition(rows[0].account?.accountID == "account-a" && rows[0].secondaryAccount == nil)
        precondition(parseSummary(quotaWire)?.platforms[0].account == rows[0].account)
    }

    private final class Output {
        var data = Data()
    }
}
