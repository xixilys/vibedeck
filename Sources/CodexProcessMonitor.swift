import Foundation
import Darwin

/// Observed turn lifecycle, not an inference from CPU, process existence, or log age.
public enum CodexActivityState: String, Equatable, Codable {
    case active, idle, stopped, unresponsive, unknown

    public var label: String {
        switch self {
        case .active: return L("轮次未结束", "Turn open")
        case .idle: return L("空闲", "Idle")
        case .stopped: return L("进程已暂停", "Process stopped")
        case .unresponsive: return L("僵尸进程", "Zombie process")
        case .unknown: return L("状态未知", "Unknown")
        }
    }
}

public enum CodexProcessRole: String, Equatable, Codable {
    case cli, appServer, worker
    public var label: String {
        switch self {
        case .cli: return "CLI"
        case .appServer: return "App Server"
        case .worker: return L("子进程", "Worker")
        }
    }
}

public enum CodexProcessSource: String, Equatable, Codable {
    case localKernel, linuxProc
}

public enum CodexStateBasis: String, Equatable, Codable {
    case turnStarted, turnEnded, kernelStopped, kernelZombie, noLifecycleEvidence, partialObservation
    public var label: String {
        switch self {
        case .turnStarted: return L("明确的轮次开始事件；可能在等工具或批准", "Explicit turn start; may be awaiting a tool or approval")
        case .turnEnded: return L("明确的轮次结束事件", "Explicit turn end")
        case .kernelStopped: return L("内核报告进程暂停", "Kernel reports stopped process")
        case .kernelZombie: return L("内核报告僵尸进程", "Kernel reports zombie process")
        case .noLifecycleEvidence: return L("没有可用的当前轮次事件", "No current lifecycle evidence")
        case .partialObservation: return L("只读采集不完整", "Partial read-only observation")
        }
    }
}

public struct CodexSessionActivity: Identifiable, Equatable, Codable {
    public let id: String
    public let cwd: String?
    public let state: CodexActivityState
    public let basis: CodexStateBasis
    /// Explicit lifecycle event time; nil means that no usable event was observed.
    public let observedAt: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case id, cwd, state, basis
        case observedAt = "observed_at"
    }
}

public struct CodexProcessInfo: Identifiable, Equatable, Codable {
    public var id: String { "\(deviceID):\(instanceID)" }
    public let deviceID: String
    public let source: CodexProcessSource
    /// PID + kernel birth time; never use a PID alone as persistent identity.
    public let instanceID: String
    public let pid: Int
    public let parentPID: Int
    public let role: CodexProcessRole
    public let cwd: String?
    public let startedAt: TimeInterval
    public let sampledAt: TimeInterval
    public let memMB: Double
    public let state: CodexActivityState
    public let basis: CodexStateBasis
    public let sessions: [CodexSessionActivity]
    public let observationLimited: Bool

    enum CodingKeys: String, CodingKey {
        case source, pid, role, cwd, state, basis, sessions
        case deviceID = "device_id", instanceID = "instance_id", parentPID = "parent_pid"
        case startedAt = "started_at", sampledAt = "sampled_at", memMB = "mem_mb", observationLimited = "observation_limited"
    }
}

struct CodexProcessSample {
    let pid: Int
    let parentPID: Int
    let command: String
    let memMB: Double
}

/// Local, passive monitor. It never connects to a running server or launches Codex.
/// Caller serializes access (ProcessScanner's existing lock). Kernel metadata replaces
/// lsof and directory walks; only rollout files already open by a live Codex are read.
final class CodexProcessMonitor {
    private struct Birth: Equatable {
        let seconds: UInt64
        let microseconds: UInt64
        var timestamp: TimeInterval { Double(seconds) + Double(microseconds) / 1_000_000 }
        var key: String { "\(seconds).\(microseconds)" }
    }
    private struct RolloutReference: Hashable {
        let path: String
        let device: Int32
        let inode: UInt64
    }
    private struct CachedProcess {
        let birth: Birth
        let at: TimeInterval
        let cwd: String?
        let paths: [RolloutReference]
        let limited: Bool
    }
    private struct Lifecycle {
        let state: CodexActivityState
        let timestamp: TimeInterval
    }
    private struct CachedLog {
        let device: Int32
        let inode: UInt64
        var size: Int64
        var offset: UInt64
        var cwd: String?
        var lifecycle: Lifecycle?
        var coverageLimited: Bool
        var searchBefore: UInt64?
        var searchedBytes: Int
        var searchSuffix: [UInt8]
        var incompleteRecord: Bool
        var pendingRecordStart: UInt64?
    }
    private(set) var inventoryLimited = false
    private var lastSnapshotAt: TimeInterval?
    private var lastSnapshot: [CodexProcessInfo] = []
    private var processCache: [Int: CachedProcess] = [:]
    private var logCache: [String: CachedLog] = [:]
    private let refreshSeconds: TimeInterval = 5
    private let maxFDs = 4096
    private let maxLogsPerProcess = 64
    private let maxHeadBytes = 32_768
    private let maxReadBytes = 131_072
    private let maxBytesPerScan = 4 * 1024 * 1024
    private let maxHistoryBytes = 8 * 1024 * 1024
    private let logRoots: [String]

    init(home: String = NSHomeDirectory()) {
        let root = URL(fileURLWithPath: home).appendingPathComponent(".codex/sessions").resolvingSymlinksInPath().path
        logRoots = [root + "/"]
    }

    /// Classify only an executable (or the script of a known JS interpreter).
    /// Arguments containing "codex", helper binaries, grep and shell payloads do not qualify.
    static func role(command: String) -> CodexProcessRole? {
        guard let executable = command.split(maxSplits: 1, whereSeparator: { $0.isWhitespace }).first else { return nil }
        let base = executable.split(separator: "/").last.map(String.init) ?? ""
        guard ["codex", "codex.js", "node", "nodejs", "bun"].contains(base) else { return nil }
        // Bound parsing before a potentially large prompt argument.
        let tokens = command.split(maxSplits: 64, whereSeparator: { $0.isWhitespace }).prefix(64).map(String.init)
        var argumentStart = 1
        if ["node", "nodejs", "bun"].contains(base) {
            guard tokens.count > 1 else { return nil }
            let script = URL(fileURLWithPath: tokens[1]).lastPathComponent
            guard script == "codex" || script == "codex.js" else { return nil }
            argumentStart = 2
        } else if base != "codex" && base != "codex.js" {
            return nil
        }
        // Inspect only actual command positions, never a prompt passed to `exec`.
        let arguments = Array(tokens.dropFirst(argumentStart))
        // Global options can precede the mode (`codex -c key=value app-server`).
        // Stop at the first positional argument so prompt text cannot select the role.
        let valueOptions: Set<String> = ["-c", "--config", "-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval", "-C", "--cd", "--add-dir", "--enable", "--disable", "-i", "--image", "--local-provider"]
        var position = 0
        while position < arguments.count {
            let token = arguments[position]
            if ["--version", "-V", "--help", "-h"].contains(token) { return nil }
            if valueOptions.contains(token) { position += 2; continue }
            if token.hasPrefix("-") { position += 1; continue }
            break
        }
        let mode = position < arguments.count ? arguments[position] : ""
        if mode == "mcp-server" || mode == "mcp" { return nil }
        if mode == "app-server" { return .appServer }
        if mode == "exec-server" { return .worker }
        if ["login", "logout", "completion", "completions", "features", "debug"].contains(mode) { return nil }
        return .cli
    }

    static func canonicalSamples(_ samples: [CodexProcessSample]) -> [(CodexProcessSample, CodexProcessRole)] {
        let byPID = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let matched = samples.compactMap { p -> (CodexProcessSample, CodexProcessRole)? in
            role(command: p.command).map { (p, $0) }
        }
        let matchedPIDs = Set(matched.map { $0.0.pid })
        // npm node launcher -> native binary: keep the binary, not two sessions.
        let wrapperPIDs = Set(matched.filter { p, _ in
            let base = p.command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            return ["node", "nodejs", "bun"].contains(base) && matched.contains { $0.0.parentPID == p.pid }
        }.map { $0.0.pid })
        return matched.filter { !wrapperPIDs.contains($0.0.pid) }.map { p, role in
            var parent = p.parentPID
            var seen = Set<Int>()
            while parent > 1, seen.insert(parent).inserted, seen.count < 32 {
                if matchedPIDs.contains(parent), !wrapperPIDs.contains(parent) { return (p, role == .appServer ? role : .worker) }
                parent = byPID[parent]?.parentPID ?? 0
            }
            return (p, role)
        }.sorted { $0.0.pid < $1.0.pid }
    }

    func snapshot(_ samples: [CodexProcessSample], now: TimeInterval = Date().timeIntervalSince1970) -> [CodexProcessInfo] {
        let candidates = Self.canonicalSamples(samples)
        let livePIDs = Set(candidates.map { $0.0.pid })
        if let last = lastSnapshotAt, now >= last, now - last < refreshSeconds,
           lastSnapshot.count == candidates.count,
           zip(lastSnapshot, candidates).allSatisfy({ row, candidate in
               guard row.pid == candidate.0.pid, row.role == candidate.1 else { return false }
               var bsd = proc_bsdinfo()
               guard proc_pidinfo(Int32(row.pid), PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout.size(ofValue: bsd))) == MemoryLayout.size(ofValue: bsd) else { return false }
               let birth = Birth(seconds: bsd.pbi_start_tvsec, microseconds: bsd.pbi_start_tvusec)
               return row.instanceID == "\(row.pid):\(birth.key)" &&
                   (bsd.pbi_status == 5) == (row.state == .unresponsive) && (bsd.pbi_status == 4) == (row.state == .stopped)
           }) { return lastSnapshot }
        processCache = processCache.filter { livePIDs.contains($0.key) }
        var budget = maxBytesPerScan
        var result: [CodexProcessInfo] = []
        var ownedPaths = Set<String>()
        for (p, role) in candidates {
            var bsd = proc_bsdinfo()
            guard proc_pidinfo(Int32(p.pid), PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout.size(ofValue: bsd))) == MemoryLayout.size(ofValue: bsd),
                  bsd.pbi_pid == p.pid else { processCache[p.pid] = nil; continue }
            let birth = Birth(seconds: bsd.pbi_start_tvsec, microseconds: bsd.pbi_start_tvusec)
            var executable = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let pathBytes = executable.withUnsafeMutableBytes { proc_pidpath(Int32(p.pid), $0.baseAddress, UInt32($0.count)) }
            let expected = p.command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init).map { URL(fileURLWithPath: $0).lastPathComponent }
            if pathBytes > 0 {
                guard URL(fileURLWithPath: String(cString: executable)).lastPathComponent == expected else { processCache[p.pid] = nil; continue }
            } else if bsd.pbi_status != 5 {
                // Zombie processes may no longer have a readable executable path.
                processCache[p.pid] = nil; continue
            }
            let cached: CachedProcess
            if let old = processCache[p.pid], old.birth == birth, now >= old.at, now - old.at < refreshSeconds {
                cached = old
            } else {
                let metadata = processMetadata(pid: p.pid)
                cached = CachedProcess(birth: birth, at: now, cwd: metadata.cwd, paths: metadata.paths, limited: metadata.limited)
                processCache[p.pid] = cached
            }
            var sessions: [CodexSessionActivity] = []
            var limited = cached.limited
            for reference in cached.paths {
                let path = reference.path
                // A log FD inherited by another process does not create a second session.
                ownedPaths.insert(path)
                if let session = readSession(reference, birth: birth.timestamp, now: now, budget: &budget) {
                    sessions.append(session)
                    if session.basis == .partialObservation { limited = true }
                } else { limited = true }
            }
            // Do not publish a process that exited / reused its PID during the FD reads.
            var after = proc_bsdinfo()
            guard proc_pidinfo(Int32(p.pid), PROC_PIDTBSDINFO, 0, &after, Int32(MemoryLayout.size(ofValue: after))) == MemoryLayout.size(ofValue: after),
                  after.pbi_start_tvsec == birth.seconds, after.pbi_start_tvusec == birth.microseconds else { continue }
            let kernelState: CodexActivityState?
            if after.pbi_status == 5 { kernelState = .unresponsive } // SZOMB
            else if after.pbi_status == 4 { kernelState = .stopped } // SSTOP
            else { kernelState = nil }
            let state = kernelState ?? Self.aggregate(sessions.map { $0.state }, limited: limited)
            let basis: CodexStateBasis = state == .unresponsive ? .kernelZombie : state == .stopped ? .kernelStopped :
                state == .active ? .turnStarted : state == .idle ? .turnEnded : limited ? .partialObservation : .noLifecycleEvidence
            result.append(CodexProcessInfo(deviceID: "local", source: .localKernel, instanceID: "\(p.pid):\(birth.key)", pid: p.pid, parentPID: Int(after.pbi_ppid), role: role,
                                           cwd: cached.cwd, startedAt: birth.timestamp, sampledAt: now, memMB: p.memMB,
                                           state: state, basis: basis, sessions: sessions.sorted { $0.id < $1.id }, observationLimited: limited))
        }
        // Backfill lifecycle metadata fairly across already-open logs. A first sample
        // need not read a whole long turn, and later UI ticks resume the bounded search.
        let pending = ownedPaths.filter { logCache[$0]?.lifecycle == nil && logCache[$0]?.searchBefore != nil }
            .sorted { (logCache[$0]?.searchedBytes ?? 0) < (logCache[$1]?.searchedBytes ?? 0) }
        var backfillQueue = pending
        while budget > 0 && !backfillQueue.isEmpty {
            let path = backfillQueue.removeFirst()
            let before = logCache[path]?.searchedBytes
            backfillLifecycle(path, now: now, budget: &budget)
            if let cache = logCache[path], cache.lifecycle == nil, cache.searchBefore != nil,
               cache.searchedBytes != before { backfillQueue.append(path) }
        }
        result = result.map { p in
            let sessions = p.sessions.map { session -> CodexSessionActivity in
                guard let path = ownedPaths.first(where: { Self.sessionID($0) == session.id }), let log = logCache[path] else { return session }
                return Self.session(id: session.id, value: log, birth: p.startedAt)
            }
            return Self.updating(p, sessions: sessions, limited: processCache[p.pid]?.limited == true || sessions.contains { $0.basis == .partialObservation })
        }
        let sessionOwners = Dictionary(grouping: result.flatMap { $0.sessions.map { $0.id } }, by: { $0 })
        let ambiguous = Set(sessionOwners.filter { $0.value.count > 1 }.keys)
        if !ambiguous.isEmpty {
            result = result.map { p in
                guard p.sessions.contains(where: { ambiguous.contains($0.id) }) else { return p }
                let sessions = p.sessions.filter { !ambiguous.contains($0.id) }
                return Self.updating(p, sessions: sessions, limited: true)
            }
        }
        // Closed/exited sessions are removed; historical logs cannot masquerade as live tasks.
        logCache = logCache.filter { ownedPaths.contains($0.key) }
        inventoryLimited = result.count != candidates.count
        lastSnapshot = result
        lastSnapshotAt = now
        return result
    }

    private static func updating(_ p: CodexProcessInfo, sessions: [CodexSessionActivity], limited: Bool) -> CodexProcessInfo {
        let state = p.state == .stopped || p.state == .unresponsive ? p.state : aggregate(sessions.map { $0.state }, limited: limited)
        let basis: CodexStateBasis = state == .active ? .turnStarted : state == .idle ? .turnEnded : state == .stopped ? .kernelStopped : state == .unresponsive ? .kernelZombie : limited ? .partialObservation : .noLifecycleEvidence
        return CodexProcessInfo(deviceID: p.deviceID, source: p.source, instanceID: p.instanceID, pid: p.pid, parentPID: p.parentPID,
                                role: p.role, cwd: p.cwd, startedAt: p.startedAt, sampledAt: p.sampledAt, memMB: p.memMB,
                                state: state, basis: basis, sessions: sessions, observationLimited: limited)
    }

    static func aggregate(_ states: [CodexActivityState], limited: Bool) -> CodexActivityState {
        if states.contains(.active) { return .active }
        if !limited && !states.isEmpty && states.allSatisfy({ $0 == .idle }) { return .idle }
        return .unknown
    }

    private func processMetadata(pid: Int) -> (cwd: String?, paths: [RolloutReference], limited: Bool) {
        var vnode = proc_vnodepathinfo()
        var cwd: String?
        if proc_pidinfo(Int32(pid), PROC_PIDVNODEPATHINFO, 0, &vnode, Int32(MemoryLayout.size(ofValue: vnode))) == MemoryLayout.size(ofValue: vnode) {
            cwd = withUnsafePointer(to: &vnode.pvi_cdir.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if cwd?.isEmpty == true { cwd = nil }
        }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: maxFDs)
        let bytes = fds.withUnsafeMutableBytes { proc_pidinfo(Int32(pid), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return (cwd, [], true) }
        var limited = Int(bytes) >= fds.count * MemoryLayout<proc_fdinfo>.stride
        var paths = Set<RolloutReference>()
        for fd in fds.prefix(min(fds.count, Int(bytes) / MemoryLayout<proc_fdinfo>.stride)) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
            var file = vnode_fdinfowithpath()
            guard proc_pidfdinfo(Int32(pid), fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &file, Int32(MemoryLayout.size(ofValue: file))) == MemoryLayout.size(ofValue: file) else { limited = true; continue }
            let path = withUnsafePointer(to: &file.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if logRoots.contains(where: { path.hasPrefix($0) }), Self.sessionID(path) != nil {
                paths.insert(RolloutReference(path: path, device: Int32(bitPattern: file.pvip.vip_vi.vi_stat.vst_dev), inode: file.pvip.vip_vi.vi_stat.vst_ino))
                if paths.count >= maxLogsPerProcess { limited = true; break }
            }
        }
        return (cwd, paths.sorted { $0.path < $1.path }, limited)
    }

    static func sessionID(_ path: String) -> String? {
        guard path.hasSuffix(".jsonl") else { return nil }
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        guard name.hasPrefix("rollout-"), name.count >= 36 else { return nil }
        let id = String(name.suffix(36))
        return UUID(uuidString: id).map { _ in id.lowercased() }
    }

    private func readSession(_ reference: RolloutReference, birth: TimeInterval, now: TimeInterval, budget: inout Int) -> CodexSessionActivity? {
        let path = reference.path
        guard let id = Self.sessionID(path) else { return nil }
        var st = stat()
        guard path.withCString({ lstat($0, &st) }) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_dev == reference.device, st.st_ino == reference.inode else {
            logCache[path] = nil
            return CodexSessionActivity(id: id, cwd: nil, state: .unknown, basis: .partialObservation, observedAt: nil)
        }
        var cache = logCache[path]
        // Unchanged logs need only metadata, not open/read/close on every UI tick.
        let unchanged = cache.map { $0.device == st.st_dev && $0.inode == st.st_ino && $0.size == st.st_size } ?? false
        if unchanged, let value = cache { return Self.session(id: id, value: value, birth: birth) }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var opened = stat()
        guard fstat(handle.fileDescriptor, &opened) == 0, opened.st_dev == st.st_dev, opened.st_ino == st.st_ino else { return nil }
        if cache == nil || cache?.device != st.st_dev || cache?.inode != st.st_ino || (cache?.size ?? 0) > st.st_size {
            cache = CachedLog(device: st.st_dev, inode: st.st_ino, size: -1, offset: 0, cwd: nil, lifecycle: nil, coverageLimited: false, searchBefore: nil, searchedBytes: 0, searchSuffix: [], incompleteRecord: false, pendingRecordStart: nil)
            if budget >= maxHeadBytes {
                let data = (try? handle.read(upToCount: maxHeadBytes)) ?? Data()
                budget -= data.count
                if data.contains(10), let first = data.split(separator: 10, maxSplits: 1).first, Self.wellFormedJSON(Array(first)) {
                    let fields = Self.objectFields(Array(first))
                    if Self.string(fields["type"]) == "session_meta", let payload = fields["payload"] {
                        cache?.cwd = Self.string(Self.objectFields(payload)["cwd"])
                    }
                }
            }
        }
        guard var value = cache else { return nil }
        if !unchanged, budget > 0 {
            let size = UInt64(max(0, st.st_size))
            // Catch up normal append bursts contiguously; do not repeatedly lose
            // a pending initial backfill just because a turn writes >128KiB/5s.
            let count = min(value.offset > 0 ? 8 * maxReadBytes : maxReadBytes, budget)
            let start = max(value.offset, size > UInt64(count) ? size - UInt64(count) : 0)
            // A skipped region may contain the end/start of a turn; discard old certainty.
            let skipped = start > value.offset
            if skipped {
                value.lifecycle = nil; value.coverageLimited = true
                value.searchBefore = start; value.searchedBytes = 0; value.pendingRecordStart = nil
            }
            do {
                try handle.seek(toOffset: start)
                let data = try handle.read(upToCount: count) ?? Data()
                budget -= data.count
                let bytes = Array(data)
                let lineStart = bytes.lastIndex(of: 10).map { $0 + 1 } ?? 0
                value.incompleteRecord = lineStart < bytes.count
                if Self.hasMalformedRecords(bytes, useFirstLine: start == value.offset) {
                    value.lifecycle = nil; value.coverageLimited = true; value.searchBefore = nil
                } else if let event = Self.latestLifecycle(bytes, useFirstLine: start == value.offset, maxTimestamp: now + 5) {
                    value.lifecycle = event
                    value.coverageLimited = false
                    value.searchBefore = nil; value.pendingRecordStart = nil
                }
                if skipped && value.lifecycle == nil {
                    value.searchSuffix = Array(bytes.prefix(1024))
                }
                // Partial final records are retried on the next scan, not interpreted.
                value.offset = start + UInt64(lineStart)
                value.size = lineStart == bytes.count ? st.st_size : -1
            } catch { value.lifecycle = nil; value.coverageLimited = true }
        } else if !unchanged { value.lifecycle = nil; value.coverageLimited = true }
        logCache[path] = value
        return Self.session(id: id, value: value, birth: birth)
    }

    private func backfillLifecycle(_ path: String, now: TimeInterval, budget: inout Int) {
        guard var cache = logCache[path], let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        var st = stat()
        guard fstat(handle.fileDescriptor, &st) == 0, st.st_dev == cache.device, st.st_ino == cache.inode else { return }
        if let pending = cache.pendingRecordStart {
            completeLifecycleRecord(handle, start: pending, now: now, budget: &budget, cache: &cache)
            logCache[path] = cache; return
        }
        guard let before = cache.searchBefore, before > 0, cache.searchedBytes < maxHistoryBytes, st.st_size >= before else { return }
        let count = min(maxReadBytes, budget, maxHistoryBytes - cache.searchedBytes, Int(before))
        guard count > 0 else { return }
        let start = before - UInt64(count)
        do {
            try handle.seek(toOffset: start)
            let chunk = Array(try handle.read(upToCount: count) ?? Data())
            budget -= chunk.count; cache.searchedBytes += chunk.count
            let bytes = chunk + cache.searchSuffix
            if Self.hasMalformedRecords(bytes, useFirstLine: start == 0) {
                cache.lifecycle = nil; cache.coverageLimited = true; cache.searchBefore = nil
                logCache[path] = cache; return
            }
            cache.lifecycle = Self.latestLifecycle(bytes, useFirstLine: start == 0,
                                                    headerStartLimit: chunk.count, maxTimestamp: now + 5)
            // A short metadata header may cross a chunk boundary or precede a large
            // completion message. Locate it, then validate the whole record before
            // publishing anything; the header by itself is never state evidence.
            let fragmentStart = bytes.lastIndex(of: 10).map { $0 + 1 } ?? 0
            if (fragmentStart > 0 || start == 0), fragmentStart < chunk.count,
               Self.lifecycleHeader(Array(bytes[fragmentStart...])) != nil {
                cache.lifecycle = nil; cache.coverageLimited = true
                cache.pendingRecordStart = start + UInt64(fragmentStart)
                completeLifecycleRecord(handle, start: cache.pendingRecordStart!, now: now, budget: &budget, cache: &cache)
                logCache[path] = cache; return
            }
            if cache.lifecycle != nil {
                cache.coverageLimited = false; cache.searchBefore = nil
            } else {
                cache.searchBefore = start > 0 && cache.searchedBytes < maxHistoryBytes ? start : nil
                cache.searchSuffix = Array(bytes.prefix(1024))
                if start == 0 { cache.coverageLimited = false }
            }
            logCache[path] = cache
        } catch { /* Keep unknown; use only the existing sampling cadence to retry. */ }
    }

    private func completeLifecycleRecord(_ handle: FileHandle, start: UInt64, now: TimeInterval,
                                         budget: inout Int, cache: inout CachedLog) {
        let maxRecordBytes = 1024 * 1024
        let count = min(maxRecordBytes, budget)
        guard count > 0 else { return }
        do {
            try handle.seek(toOffset: start)
            let bytes = Array(try handle.read(upToCount: count) ?? Data())
            budget -= bytes.count; cache.searchedBytes += bytes.count
            if let newline = bytes.firstIndex(of: 10) {
                let event = Self.lifecycle(Array(bytes[..<newline])).flatMap { $0.timestamp <= now + 5 ? $0 : nil }
                cache.lifecycle = event; cache.coverageLimited = event == nil
                cache.pendingRecordStart = nil; cache.searchBefore = nil
            } else if count < maxRecordBytes && bytes.count == count {
                cache.pendingRecordStart = start // Retry with the next scan's budget.
            } else {
                cache.lifecycle = nil; cache.coverageLimited = true
                cache.pendingRecordStart = nil; cache.searchBefore = nil
                if bytes.count < count { cache.incompleteRecord = true }
            }
        } catch {
            cache.lifecycle = nil; cache.coverageLimited = true
            cache.pendingRecordStart = nil; cache.searchBefore = nil
        }
    }

    private static func session(id: String, value: CachedLog, birth: TimeInterval) -> CodexSessionActivity {
        // Markers from a previous process incarnation cannot describe this process.
        if value.incompleteRecord {
            return CodexSessionActivity(id: id, cwd: value.cwd, state: .unknown, basis: .partialObservation, observedAt: nil)
        }
        let event = value.lifecycle.flatMap { $0.timestamp >= birth ? $0 : nil }
        return CodexSessionActivity(id: id, cwd: value.cwd, state: event?.state ?? .unknown, basis: event.map { $0.state == .active ? .turnStarted : .turnEnded } ?? (value.coverageLimited ? .partialObservation : .noLifecycleEvidence), observedAt: event?.timestamp)
    }

    private static func latestLifecycle(_ bytes: [UInt8], useFirstLine: Bool,
                                        headerStartLimit: Int = Int.max, maxTimestamp: TimeInterval = .greatestFiniteMagnitude) -> Lifecycle? {
        var latest: Lifecycle?
        var lineStart = 0
        var canUse = useFirstLine
        for end in bytes.indices where bytes[end] == 10 {
            if canUse && lineStart < headerStartLimit,
               let event = lifecycle(Array(bytes[lineStart..<end])), event.timestamp <= maxTimestamp { latest = event }
            canUse = true; lineStart = end + 1
        }
        return latest
    }

    private static func lifecycle(_ bytes: [UInt8]) -> Lifecycle? {
        guard let event = lifecycleHeader(bytes), wellFormedJSON(bytes) else { return nil }
        return event
    }

    private static func lifecycleHeader(_ bytes: [UInt8]) -> Lifecycle? {
        let fields = objectFields(bytes, wanted: ["type", "timestamp"])
        guard string(fields["type"]) == "event_msg", let timestamp = string(fields["timestamp"]),
              let time = parseTime(timestamp), let payload = objectFields(bytes, wanted: ["payload"], prefixObjects: true)["payload"] else { return nil }
        let event = string(objectFields(payload, wanted: ["type"])["type"])
        switch event {
        case "task_started": return Lifecycle(state: .active, timestamp: time)
        case "task_complete", "task_completed", "turn_aborted": return Lifecycle(state: .idle, timestamp: time)
        default: return nil
        }
    }

    /// Validate bytes and nesting without constructing message/prompt string values.
    /// Metadata objects reject duplicate keys rather than choosing an ambiguous type.
    private struct JSONStructure {
        let bytes: [UInt8]
        var index = 0
        mutating func whitespace() {
            while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        mutating func validate() -> Bool {
            whitespace()
            guard value(depth: 0) else { return false }
            whitespace(); return index == bytes.count
        }
        mutating func value(depth: Int) -> Bool {
            guard depth <= 64, index < bytes.count else { return false }
            switch bytes[index] {
            case 123: return object(depth: depth)
            case 91:
                index += 1; whitespace()
                if index < bytes.count && bytes[index] == 93 { index += 1; return true }
                while value(depth: depth + 1) {
                    whitespace(); guard index < bytes.count else { return false }
                    if bytes[index] == 93 { index += 1; return true }
                    guard bytes[index] == 44 else { return false }
                    index += 1; whitespace()
                }
                return false
            case 34: return quoted()
            case 116: return literal([116, 114, 117, 101])
            case 102: return literal([102, 97, 108, 115, 101])
            case 110: return literal([110, 117, 108, 108])
            default: return number()
            }
        }
        mutating func object(depth: Int) -> Bool {
            index += 1; whitespace()
            if index < bytes.count && bytes[index] == 125 { index += 1; return true }
            var keys = Set<String>()
            while index < bytes.count {
                let start = index
                guard quoted() else { return false }
                if depth <= 1 {
                    guard let key = CodexProcessMonitor.string(Array(bytes[start..<index])), keys.insert(key).inserted else { return false }
                }
                whitespace(); guard index < bytes.count && bytes[index] == 58 else { return false }
                index += 1; whitespace()
                guard value(depth: depth + 1) else { return false }
                whitespace(); guard index < bytes.count else { return false }
                if bytes[index] == 125 { index += 1; return true }
                guard bytes[index] == 44 else { return false }
                index += 1; whitespace()
            }
            return false
        }
        mutating func literal(_ token: [UInt8]) -> Bool {
            guard bytes.count - index >= token.count, bytes[index..<index + token.count].elementsEqual(token) else { return false }
            index += token.count; return true
        }
        mutating func number() -> Bool {
            if index < bytes.count && bytes[index] == 45 { index += 1 }
            guard index < bytes.count else { return false }
            if bytes[index] == 48 { index += 1 }
            else {
                guard (49...57).contains(bytes[index]) else { return false }
                while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
            }
            if index < bytes.count && bytes[index] == 46 {
                index += 1; let start = index
                while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
                guard index > start else { return false }
            }
            if index < bytes.count && [69, 101].contains(bytes[index]) {
                index += 1
                if index < bytes.count && [43, 45].contains(bytes[index]) { index += 1 }
                let start = index
                while index < bytes.count && (48...57).contains(bytes[index]) { index += 1 }
                guard index > start else { return false }
            }
            return true
        }
        mutating func quoted() -> Bool {
            guard index < bytes.count && bytes[index] == 34 else { return false }
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 34 { index += 1; return true }
                if byte == 92 {
                    index += 1; guard index < bytes.count else { return false }
                    if bytes[index] == 117 {
                        guard bytes.count - index >= 5,
                              bytes[(index + 1)...(index + 4)].allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return false }
                        index += 5
                    } else {
                        guard [34, 92, 47, 98, 102, 110, 114, 116].contains(bytes[index]) else { return false }
                        index += 1
                    }
                    continue
                }
                guard byte >= 32 else { return false }
                if byte >= 128 {
                    let length: Int
                    if (194...223).contains(byte) { length = 2 }
                    else if (224...239).contains(byte) { length = 3 }
                    else if (240...244).contains(byte) { length = 4 }
                    else { return false }
                    guard bytes.count - index >= length,
                          bytes[(index + 1)..<(index + length)].allSatisfy({ (128...191).contains($0) }) else { return false }
                    let second = bytes[index + 1]
                    if byte == 224 && second < 160 || byte == 237 && second > 159 || byte == 240 && second < 144 || byte == 244 && second > 143 { return false }
                    index += length
                } else { index += 1 }
            }
            return false
        }
    }

    private static func wellFormedJSON(_ bytes: [UInt8]) -> Bool {
        var structure = JSONStructure(bytes: bytes)
        return structure.validate()
    }

    private static func hasMalformedRecords(_ bytes: [UInt8], useFirstLine: Bool) -> Bool {
        var start = 0
        var use = useFirstLine
        for end in bytes.indices where bytes[end] == 10 {
            if use && !wellFormedJSON(Array(bytes[start..<end])) { return true }
            start = end + 1; use = true
        }
        return false
    }

    private static let iso = ISO8601DateFormatter()
    private static let fractionalISO: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static func parseTime(_ text: String) -> TimeInterval? {
        (fractionalISO.date(from: text) ?? iso.date(from: text))?.timeIntervalSince1970
    }

    /// Select JSON object fields without deserializing prompt, message, instructions,
    /// tool arguments or responses. String values are decoded only for explicitly requested keys.
    private static func objectFields(_ bytes: [UInt8], wanted: Set<String> = ["timestamp", "type", "payload", "cwd"], prefixObjects: Bool = false) -> [String: [UInt8]] {
        var result: [String: [UInt8]] = [:]
        var i = 0
        func whitespace() { while i < bytes.count && [9, 10, 13, 32].contains(bytes[i]) { i += 1 } }
        func quotedEnd(_ start: Int) -> Int? {
            guard start < bytes.count, bytes[start] == 34 else { return nil }
            var p = start + 1
            while p < bytes.count {
                if bytes[p] == 92 { p += 2; continue }
                if bytes[p] == 34 { return p + 1 }
                p += 1
            }
            return nil
        }
        whitespace()
        guard i < bytes.count, bytes[i] == 123 else { return [:] }
        i += 1
        while i < bytes.count {
            whitespace()
            if i < bytes.count, bytes[i] == 125 { break }
            let keyStart = i
            guard let keyEnd = quotedEnd(i), let key = string(Array(bytes[keyStart..<keyEnd])) else { break }
            i = keyEnd; whitespace()
            guard i < bytes.count, bytes[i] == 58 else { break }
            i += 1; whitespace()
            let start = i
            guard i < bytes.count else { break }
            if prefixObjects, wanted.contains(key), bytes[i] == 123 {
                result[key] = Array(bytes[i..<min(bytes.count, i + 512)])
                return result
            }
            if bytes[i] == 34 {
                guard let end = quotedEnd(i) else { break }; i = end
            } else if bytes[i] == 123 || bytes[i] == 91 {
                var depth = 0
                while i < bytes.count {
                    if bytes[i] == 34 {
                        guard let end = quotedEnd(i) else { return result }; i = end; continue
                    }
                    if bytes[i] == 123 || bytes[i] == 91 { depth += 1 }
                    if bytes[i] == 125 || bytes[i] == 93 { depth -= 1 }
                    i += 1
                    if depth == 0 { break }
                }
                if depth != 0 { break }
            } else {
                while i < bytes.count, ![44, 125, 9, 10, 13, 32].contains(bytes[i]) { i += 1 }
            }
            if wanted.contains(key) { result[key] = Array(bytes[start..<i]) }
            if result.count == wanted.count { return result }
            whitespace()
            guard i < bytes.count, bytes[i] == 44 else { break }
            i += 1
        }
        return result
    }
    private static func string(_ bytes: [UInt8]?) -> String? {
        guard let bytes, bytes.first == 34 else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed])) as? String
    }

    static func selfTest() {
        precondition(role(command: "node /opt/bin/codex app-server --listen stdio://") == .appServer)
        precondition(role(command: "codex -c key=value app-server --analytics-default-enabled") == .appServer)
        precondition(role(command: "codex -c key=value exec-server --remote host") == .worker)
        precondition(role(command: "codex -c app-server exec app-server") == .cli)
        precondition(role(command: "/opt/node_modules/@openai/codex/vendor/bin/codex exec do-work") == .cli)
        precondition(role(command: "/opt/bin/codex exec app-server") == .cli)
        precondition(role(command: "ssh host codex app-server") == nil)
        precondition(role(command: "/bin/zsh -c codex") == nil)
        precondition(role(command: "node /tmp/not-codex.js") == nil)
        precondition(role(command: "/opt/codex-path/rg --files") == nil)
        precondition(role(command: "codex mcp-server") == nil)
        let samples = [CodexProcessSample(pid: 10, parentPID: 1, command: "node /opt/bin/codex app-server", memMB: 1),
                       CodexProcessSample(pid: 11, parentPID: 10, command: "/opt/vendor/bin/codex app-server", memMB: 2),
                       CodexProcessSample(pid: 12, parentPID: 11, command: "codex exec task", memMB: 3)]
        let canonical = canonicalSamples(samples)
        precondition(canonical.count == 2 && canonical[0].0.pid == 11 && canonical[1].1 == .worker)
        precondition(aggregate([], limited: false) == .unknown)
        precondition(aggregate([.idle, .unknown], limited: false) == .unknown)
        precondition(aggregate([.idle], limited: true) == .unknown)
        precondition(aggregate([.idle], limited: false) == .idle)
        precondition(aggregate([.active, .unknown], limited: true) == .active)
        let started = Array(#"{"timestamp":"2026-10-23T05:13:17.053Z","ordinal":1,"type":"event_msg","payload":{"type":"task_started","turn_id":"fixture"}}"#.utf8)
        precondition(lifecycle(started)?.state == .active)
        let complete = Array(#"{"timestamp":"2026-10-23T05:14:17Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"ignored"}}"#.utf8)
        precondition(lifecycle(complete)?.state == .idle)
        precondition(latestLifecycle(complete, useFirstLine: true) == nil, "Do not consume a partial final record")
        precondition(latestLifecycle(started + [10] + complete + [10], useFirstLine: true)?.state == .idle)
        let longEnd = Array(#"{"timestamp":"2026-10-23T05:14:17Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":""#.utf8) +
            [UInt8](repeating: 120, count: 512 * 1024) + Array(#""}}"#.utf8) + [10]
        let data = started + [10] + longEnd
        let boundary = started.count + 1 + 18 // Lifecycle header crosses the chunk boundary.
        let chunk = Array(data[..<boundary])
        let overlap = Array(data[boundary..<min(data.count, boundary + 1024)])
        precondition(lifecycleHeader(Array((chunk + overlap).dropFirst(started.count + 1)))?.state == .idle)
        precondition(lifecycle(Array(longEnd.dropLast()))?.state == .idle)
        precondition(lifecycle(Array(longEnd.prefix(1024))) == nil, "A valid-looking header is not a complete record")
        let adversarial = Array(#"{"timestamp":"2026-10-23T05:14:17Z","type":"response_item","payload":{"type":"message","content":"task_complete"}}"#.utf8)
        precondition(lifecycle(adversarial) == nil)
        let corrupt = Array(#"{"timestamp":"2026-10-23T05:13:17Z","type":"event_msg","payload":{"x":0],"type":"task_started"}}"#.utf8)
        precondition(lifecycle(corrupt) == nil && !wellFormedJSON(corrupt))
        let duplicate = Array(#"{"timestamp":"2026-10-23T05:13:17Z","type":"event_msg","payload":{"type":"task_complete","type":"task_started"}}"#.utf8)
        precondition(lifecycle(duplicate) == nil)
        precondition(hasMalformedRecords(corrupt + [10], useFirstLine: true))
        for invalid in [#"{"x":[1,2}}"#, #"{"x":01}"#, #"{"x":"\q"}"#, #"{"x":true,}"#] {
            precondition(!wellFormedJSON(Array(invalid.utf8)))
        }
        precondition(wellFormedJSON(Array(#"{"x":[true,false,null,-1.2e+3,{"y":"汉字\n"}]}"#.utf8)))
        let metadata = Array(#"{"type":"session_meta","payload":{"instructions":"escaped \"cwd\":\"wrong\"","cwd":"/fixture/work"}}"#.utf8)
        precondition(string(objectFields(objectFields(metadata)["payload"]!)["cwd"]) == "/fixture/work")
        precondition(sessionID("/fixture/rollout-2026-10-23T01-13-16-01a1672d-7b4f-7900-aec4-60c71d91fafd.jsonl") == "01a1672d-7b4f-7900-aec4-60c71d91fafd")
        precondition(sessionID("/fixture/auth.json") == nil)
        let oldEvent = CachedLog(device: 1, inode: 1, size: 10, offset: 10, cwd: nil,
                                 lifecycle: Lifecycle(state: .active, timestamp: 100), coverageLimited: false, searchBefore: nil, searchedBytes: 0, searchSuffix: [], incompleteRecord: false, pendingRecordStart: nil)
        precondition(session(id: "fixture", value: oldEvent, birth: 101).state == .unknown)
        precondition(session(id: "fixture", value: oldEvent, birth: 99).state == .active)
        let partial = CachedLog(device: 1, inode: 2, size: 10, offset: 10, cwd: nil, lifecycle: nil, coverageLimited: true, searchBefore: nil, searchedBytes: 0, searchSuffix: [], incompleteRecord: false, pendingRecordStart: nil)
        precondition(session(id: "fixture", value: partial, birth: 99).basis == .partialObservation)
    }
}
