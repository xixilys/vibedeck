import Foundation
import SQLite3

/// opencode（v1.18+）把每个 assistant 回合的用量写进自己的 SQLite 库，国产模型（deepseek / glm / kimi …）
/// 也在这里，所以这是把它们算进统计的唯一来源。
///
/// 读法：只读打开、一次读全部 assistant 行、整表重建。不做增量游标 —— 实测 message 表的活数据只有
/// 十几 MB，全量重读比「游标 + 重叠窗口」更便宜；而且 message 行是流式写入的，`time_updated` 可以比
/// `time_created` 晚好几个小时才定稿，任何固定的重叠窗口都会漏掉最后的 token 值。
enum OpenCodeUsage {
    /// 一行 assistant 用量。字段名对齐 opencode 的 data JSON。
    struct Row: Equatable {
        var id: String
        var session: String?
        var provider: String
        var model: String
        /// time_created，毫秒 → 秒
        var createdAt: TimeInterval
        var input: Int64
        var output: Int64
        var reasoning: Int64
        var cacheRead: Int64
        var cacheWrite: Int64
        /// created → completed，秒；旧采集器/未完成消息缺失。
        var seconds: Double? = nil
    }

    /// 口径与 Claude / Codex 一致：ctx 是「全部输入」（新鲜 + 缓存读 + 缓存写），out 含思考。
    /// opencode 的 total = input + output + reasoning + cache.read + cache.write，
    /// 映射后 tokenTotal = ctx + out 正好等于它。
    static func totals(_ row: Row) -> UsageHistory.ModelTotals {
        UsageHistory.ModelTotals(
            ctx: row.input + row.cacheRead + row.cacheWrite,
            cacheRead: row.cacheRead,
            cacheWrite: row.cacheWrite,
            out: row.output + row.reasoning,
            think: row.reasoning)
    }

    /// 纯函数：把行映射成记录表，键 = 消息 id（重复读不会重复计数）。
    static func records(rows: [Row], source: String = "OpenCode") -> [String: UsageHistory.Record] {
        var out: [String: UsageHistory.Record] = [:]
        for row in rows where !row.id.isEmpty {
            out[row.id] = UsageHistory.Record(
                id: row.id,
                source: source,
                timestamp: row.createdAt,
                model: row.model.isEmpty ? "?" : row.model,
                usage: totals(row),
                session: row.session,
                timing: row.seconds.flatMap { seconds in
                    PerformanceTiming.estimated(output: totals(row).out, seconds: seconds) == nil ? nil : PerformanceTiming(seconds: seconds)
                })
        }
        return out
    }

    /// `$XDG_DATA_HOME/opencode/opencode.db`，否则 `~/.local/share/opencode/opencode.db`。
    static func databasePath(home: String) -> String {
        let xdg = (ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? "").trimmingCharacters(in: .whitespaces)
        return xdg.isEmpty ? "\(home)/.local/share/opencode/opencode.db" : "\(xdg)/opencode/opencode.db"
    }

    /// 只读打开并整表读一遍。读失败返回 nil（调用方保留上次快照，绝不拿空表覆盖）；
    /// 库不存在或没有 assistant 行则返回空表。
    static func read(dbPath: String) -> [String: UsageHistory.Record]? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return [:] }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        defer { sqlite3_close(db) }
        // WAL 模式下读不挡写、写不挡读；偶发的 SQLITE_BUSY 交给 busy_timeout 重试，仍失败就下轮再来。
        sqlite3_busy_timeout(db, 4000)
        // Older opencode keeps assistant rows in `message`; v1.2x moved them to `session_message`
        // (a migrated superset with the same ids). Read both and let the newer table win per id.
        let legacy = """
        SELECT id, time_created, session_id,
               json_extract(data,'$.modelID'), json_extract(data,'$.providerID'),
               json_extract(data,'$.tokens.input'), json_extract(data,'$.tokens.output'),
               json_extract(data,'$.tokens.reasoning'), json_extract(data,'$.tokens.cache.read'),
               json_extract(data,'$.tokens.cache.write'),
               (json_extract(data,'$.time.completed') - json_extract(data,'$.time.created')) / 1000.0
        FROM message
        WHERE json_extract(data,'$.role')='assistant' AND json_extract(data,'$.tokens') IS NOT NULL
        """
        let current = """
        SELECT id, time_created, session_id,
               json_extract(data,'$.model.id'), json_extract(data,'$.model.providerID'),
               json_extract(data,'$.tokens.input'), json_extract(data,'$.tokens.output'),
               json_extract(data,'$.tokens.reasoning'), json_extract(data,'$.tokens.cache.read'),
               json_extract(data,'$.tokens.cache.write'),
               (json_extract(data,'$.time.completed') - json_extract(data,'$.time.created')) / 1000.0
        FROM session_message
        WHERE type='assistant' AND json_extract(data,'$.tokens') IS NOT NULL
        """
        var byID: [String: Row] = [:]
        for (table, sql) in [("message", legacy), ("session_message", current)] where hasTable(db, table) {
            guard let rows = query(db, sql) else { return nil }
            for row in rows { byID[row.id] = row }
        }
        return records(rows: Array(byID.values))
    }

    private static func hasTable(_ db: OpaquePointer, _ name: String) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else { return false }
        defer { sqlite3_finalize(prepared) }
        sqlite3_bind_text(prepared, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(prepared) == SQLITE_ROW
    }

    /// nil = the query failed midway; never hand back half a table.
    private static func query(_ db: OpaquePointer, _ sql: String) -> [Row]? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else { return nil }
        defer { sqlite3_finalize(prepared) }
        var rows: [Row] = []
        var step = sqlite3_step(prepared)
        while step == SQLITE_ROW {
            autoreleasepool {
                guard let idText = sqlite3_column_text(prepared, 0) else { return }
                func text(_ index: Int32) -> String? {
                    guard let raw = sqlite3_column_text(prepared, index) else { return nil }
                    return String(cString: raw)
                }
                func count(_ index: Int32) -> Int64 { max(0, sqlite3_column_int64(prepared, index)) }
                rows.append(Row(
                    id: String(cString: idText),
                    session: text(2),
                    provider: text(4) ?? "",
                    model: text(3) ?? "",
                    createdAt: Double(sqlite3_column_int64(prepared, 1)) / 1000.0,
                    input: count(5), output: count(6), reasoning: count(7),
                    cacheRead: count(8), cacheWrite: count(9),
                    seconds: sqlite3_column_type(prepared, 10) == SQLITE_NULL ? nil : sqlite3_column_double(prepared, 10)))
            }
            step = sqlite3_step(prepared)
        }
        return step == SQLITE_DONE ? rows : nil
    }

    /// First streamed output of recent assistant replies (`time.streamed − time.created`), as turn samples.
    /// Only the v2 table records `streamed`; older databases simply yield none.
    static func latencies(dbPath: String, since: TimeInterval, source: String = "OpenCode") -> [TurnLatencySample] {
        var handle: OpaquePointer?
        guard FileManager.default.fileExists(atPath: dbPath),
              sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 4000)
        guard hasTable(db, "session_message") else { return [] }
        let sql = """
        SELECT id, json_extract(data,'$.time.created'), json_extract(data,'$.time.streamed'),
               json_extract(data,'$.model.id'), json_extract(data,'$.error') IS NOT NULL
        FROM session_message
        WHERE type='assistant' AND time_created >= ? AND json_extract(data,'$.time.streamed') IS NOT NULL
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let prepared = stmt else { return [] }
        defer { sqlite3_finalize(prepared) }
        sqlite3_bind_int64(prepared, 1, Int64(since * 1000))
        var samples: [TurnLatencySample] = []
        while sqlite3_step(prepared) == SQLITE_ROW {
            guard let id = sqlite3_column_text(prepared, 0) else { continue }
            let created = sqlite3_column_double(prepared, 1), streamed = sqlite3_column_double(prepared, 2)
            guard created > 0, streamed >= created else { continue }
            let model = sqlite3_column_text(prepared, 3).map { String(cString: $0) }
            samples.append(TurnLatencySample(turnID: String(cString: id), source: source, timestamp: streamed / 1000,
                                             milliseconds: streamed - created, startedAt: created / 1000, model: model,
                                             failed: sqlite3_column_int(prepared, 4) != 0))
        }
        return samples
    }
}

/// DeepSeek's DSH keeps per-session logs zstd-compressed, but its cost meter also writes a plain daily
/// ledger (`~/.dsh/storages/cost-meter/ledger.json`). That ledger is the readable source: one record per
/// day with fresh input, cache reads/writes, output and reasoning, plus the account balance it last saw.
enum DSHUsage {
    struct Balance: Equatable {
        var amount: Double
        var currency: String
        var asOf: TimeInterval
    }

    static func ledgerPath(home: String) -> String { "\(home)/.dsh/storages/cost-meter/ledger.json" }

    /// nil = unreadable (keep the previous snapshot); [:] = no ledger.
    static func read(path: String, model: String = "deepseek-flash", now: TimeInterval = Date().timeIntervalSince1970,
                     calendar: Calendar = .current) -> (records: [String: UsageHistory.Record], balance: Balance?)? {
        guard FileManager.default.fileExists(atPath: path) else { return ([:], nil) }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let modified = ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? now
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        var records: [String: UsageHistory.Record] = [:]
        for (key, value) in root["days"] as? [String: Any] ?? [:] {
            guard let day = value as? [String: Any], let start = formatter.date(from: key)?.timeIntervalSince1970 else { continue }
            func count(_ name: String) -> Int64 { max(0, (day[name] as? NSNumber)?.int64Value ?? 0) }
            let input = count("input"), cacheRead = count("cacheRead"), cacheWrite = count("cacheWrite")
            let output = count("output"), reasoning = count("reasoning")
            guard input + cacheRead + cacheWrite + output + reasoning > 0 else { continue }
            // A finished day sits at noon; today's running total sits at the ledger's last write.
            let end = start + 86_400
            let timestamp = now < end ? min(now, max(start, modified)) : start + 43_200
            let id = "dsh:" + key
            records[id] = UsageHistory.Record(
                id: id, source: "DSH", timestamp: timestamp, model: model,
                usage: UsageHistory.ModelTotals(ctx: input + cacheRead + cacheWrite, cacheRead: cacheRead, cacheWrite: cacheWrite,
                                                out: output + reasoning, think: reasoning),
                session: id)
        }
        var balance: Balance?
        if let ref = root["balanceRef"] as? [String: Any], let total = (ref["total"] as? NSNumber)?.doubleValue, total.isFinite {
            let at = ((ref["at"] as? NSNumber)?.doubleValue ?? 0) / 1000
            balance = Balance(amount: total, currency: (ref["currency"] as? String) ?? "CNY", asOf: at > 0 ? at : modified)
        }
        return (records, balance)
    }
}
