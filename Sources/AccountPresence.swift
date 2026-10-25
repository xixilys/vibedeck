import Foundation
import Darwin

public enum AccountLoginState: String, Codable, Equatable {
    case loggedIn, loggedOut, unknown
    public var label: String {
        switch self {
        case .loggedIn: return L("已登录", "Signed in")
        case .loggedOut: return L("已登出", "Signed out")
        case .unknown: return L("待确认", "Unconfirmed")
        }
    }
}

public enum AccountPresenceBasis: String, Codable, Equatable {
    case cliStatus, statusUnavailable, identityUnavailable, profileMismatch
    public var label: String {
        switch self {
        case .cliStatus: return L("本地 CLI 登录状态", "Local CLI sign-in status")
        case .statusUnavailable: return L("暂未取得登录状态", "Sign-in status unavailable")
        case .identityUnavailable: return L("已确认登录，账号标识不可用", "Sign-in confirmed; account identity unavailable")
        case .profileMismatch: return L("无法将登录状态关联到账号 metadata", "Cannot bind sign-in status to account metadata")
        }
    }
}

/// Current local login facts, separate from quota and usage provenance.
/// `loggedIn` is a local CLI result, not a network/token-validity check.
public struct AccountPresence: Identifiable, Codable, Equatable {
    public var id: String { deviceID + "\u{1f}" + tool }
    public let deviceID: String
    public let tool: String
    public let state: AccountLoginState
    public let account: AccountIdentity?
    public let sampledAt: TimeInterval
    public let basis: AccountPresenceBasis
    /// Safe classifier only: chatgpt, claudeAi, apiKey, external, or nil.
    /// A confirmed Claude sign-in with a new first-party method has nil method and account.
    public let method: String?

    public var isIdentifiedLogin: Bool {
        guard state == .loggedIn, let account else { return false }
        return tool == "Codex" && method == "chatgpt" && account.provider == "openai" ||
            tool == "Claude" && method == "claudeAi" && account.provider == "anthropic"
    }
    public func isFresh(now: TimeInterval, maxAge: TimeInterval) -> Bool {
        sampledAt.isFinite && sampledAt > 0 && now.isFinite && maxAge.isFinite && maxAge >= 0 &&
            sampledAt <= now + 60 && now - sampledAt <= maxAge
    }
    enum CodingKeys: String, CodingKey {
        case tool, state, account, basis, method
        case deviceID = "device_id", sampledAt = "sampled_at"
    }
}

/// Called only on ProcessScanner's serialized background scan; no timer or persistence.
final class AccountPresenceCollector {
    struct Status {
        let exitCode: Int32
        let output: Data
    }
    struct CodexMetadata: Decodable {
        struct Tokens: Decodable {
            let accountID: String?
            enum CodingKeys: String, CodingKey { case accountID = "account_id" }
        }
        let authMode: String?
        let tokens: Tokens?
        enum CodingKeys: String, CodingKey { case authMode = "auth_mode", tokens }
        var account: AccountIdentity? {
            guard authMode == nil || authMode == "chatgpt" || authMode == "chatgptAuthTokens", let id = tokens?.accountID, id.utf8.count <= 512 else { return nil }
            return AccountIdentity(provider: "openai", accountID: id)
        }
    }
    private struct ClaudeMetadata: Decodable {
        struct OAuth: Decodable {
            let accountUuid: String?
            let organizationUuid: String?
        }
        let oauthAccount: OAuth?
        var account: AccountIdentity? {
            guard let id = oauthAccount?.accountUuid, id.utf8.count <= 512,
                  (oauthAccount?.organizationUuid?.utf8.count ?? 0) <= 512 else { return nil }
            return AccountIdentity(provider: "anthropic", accountID: id, workspaceID: oauthAccount?.organizationUuid)
        }
    }
    private struct ClaudeStatus: Decodable {
        let loggedIn: Bool
        let authMethod: String?
        let apiProvider: String?
    }
    private final class Capture {
        let lock = NSLock()
        var data = Data()
        var oversized = false
    }

    private let home: String
    private let environment: [String: String]
    private var cached: [AccountPresence] = []
    private var capturedAt: TimeInterval?
    private let cacheSeconds: TimeInterval = 30

    init(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home; self.environment = environment
    }

    func snapshot(force: Bool = false, now: TimeInterval = Date().timeIntervalSince1970) -> [AccountPresence] {
        if !force, let at = capturedAt, now >= at, now - at < cacheSeconds { return cached }
        let codexHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.codex"
        let codexBefore = Self.codexMetadata(path: codexHome + "/auth.json")
        let configPath = codexHome + "/config.toml"
        let storageBefore = Self.readCredentialStore(configPath)
        var commandEnvironment = environment
        commandEnvironment["HOME"] = home
        commandEnvironment["CODEX_HOME"] = codexHome
        commandEnvironment["CI"] = "1"
        commandEnvironment["NO_COLOR"] = "1"
        let codexPaths = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                          "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex"]
        let codexStatus = Self.executable(codexPaths).flatMap { Self.runStatus($0, ["login", "status"], environment: commandEnvironment) }
        let codexAfter = Self.codexMetadata(path: codexHome + "/auth.json")
        let storageAfter = Self.readCredentialStore(configPath)
        let stableCodexMetadata = codexBefore?.account == codexAfter?.account && codexBefore?.authMode == codexAfter?.authMode
        // Test names only, never read or decode environment credential values.
        let codexOverride = ["OPENAI_API_KEY", "CODEX_API_KEY"].contains { environment.keys.contains($0) }
        let codexProfileMatches = storageBefore == "file" && storageAfter == "file" && stableCodexMetadata && !codexOverride
        let codex = Self.codexPresence(codexStatus, account: codexProfileMatches ? codexAfter?.account : nil,
                                       profileMatches: codexProfileMatches, now: now)

        let customClaude = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let defaultClaude = URL(fileURLWithPath: home + "/.claude").resolvingSymlinksInPath().standardizedFileURL.path
        let claudeOverride = ["CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY"].contains { environment.keys.contains($0) }
        let claudeProfileMatches = (customClaude.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path == defaultClaude } ?? true) && !claudeOverride
        let claudeBefore = Self.claudeMetadata(home + "/.claude.json")
        let claudePaths = [home + "/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        let claudeStatus = Self.executable(claudePaths).flatMap { Self.runStatus($0, ["auth", "status", "--json"], environment: commandEnvironment, includeStderr: false) }
        let claudeAfter = Self.claudeMetadata(home + "/.claude.json")
        let stableClaudeMetadata = claudeBefore == claudeAfter
        let claude = Self.claudePresence(claudeStatus, account: claudeProfileMatches && stableClaudeMetadata ? claudeAfter : nil,
                                         profileMatches: claudeProfileMatches && stableClaudeMetadata, now: now)
        cached = [codex, claude]; capturedAt = now
        return cached
    }

    static func codexPresence(_ status: Status?, account: AccountIdentity?, profileMatches: Bool = true,
                              deviceID: String = "local", now: TimeInterval) -> AccountPresence {
        guard let status else { return unknown(tool: "Codex", deviceID: deviceID, now: now) }
        // Byte prefixes only: API-key status may contain a redacted key suffix.
        // Never convert that raw output or any suffix to a String, log, or wire value.
        let lines = status.output.split(separator: 10).map { $0.drop(while: { $0 == 32 || $0 == 9 || $0 == 13 }) }
        let chatGPT = lines.contains { $0.starts(with: "Logged in using ChatGPT".utf8) }
        let apiKey = lines.contains { $0.starts(with: "Logged in using an API key".utf8) || $0.starts(with: "Logged in using API key".utf8) }
        let loggedOut = lines.contains { $0.starts(with: "Not logged in".utf8) }
        guard [chatGPT, apiKey, loggedOut].filter({ $0 }).count == 1 else { return unknown(tool: "Codex", deviceID: deviceID, now: now) }
        if loggedOut && status.exitCode != 0 {
            return AccountPresence(deviceID: deviceID, tool: "Codex", state: .loggedOut, account: nil, sampledAt: now, basis: .cliStatus, method: nil)
        }
        guard status.exitCode == 0 && !loggedOut else { return unknown(tool: "Codex", deviceID: deviceID, now: now) }
        let identity = chatGPT && profileMatches ? account : nil
        return AccountPresence(deviceID: deviceID, tool: "Codex", state: .loggedIn, account: identity, sampledAt: now,
                               basis: !profileMatches && chatGPT ? .profileMismatch : identity == nil ? .identityUnavailable : .cliStatus,
                               method: chatGPT ? "chatgpt" : "apiKey")
    }

    static func claudePresence(_ status: Status?, account: AccountIdentity?, profileMatches: Bool = true,
                               deviceID: String = "local", now: TimeInterval) -> AccountPresence {
        guard let status, let raw = try? JSONDecoder().decode(ClaudeStatus.self, from: status.output) else {
            return unknown(tool: "Claude", deviceID: deviceID, now: now)
        }
        if !raw.loggedIn && raw.authMethod == "none" && status.exitCode != 0 {
            return AccountPresence(deviceID: deviceID, tool: "Claude", state: .loggedOut, account: nil, sampledAt: now, basis: .cliStatus, method: nil)
        }
        guard raw.loggedIn && status.exitCode == 0 else { return unknown(tool: "Claude", deviceID: deviceID, now: now) }
        let firstParty = raw.apiProvider == "firstParty"
        let oauth = ["claude.ai", "oauth", "claudeAi"].contains(raw.authMethod ?? "") && firstParty
        let method: String?
        if oauth { method = "claudeAi" }
        else if firstParty && ["api_key", "apiKey", "api-key"].contains(raw.authMethod ?? "") { method = "apiKey" }
        else if let provider = raw.apiProvider, provider != "firstParty" { method = "external" }
        else { method = nil }
        guard let method else {
            // A new first-party method does not erase an explicit sign-in fact,
            // but it cannot authorize attaching old OAuth account metadata.
            guard firstParty, let auth = raw.authMethod, !auth.isEmpty, auth != "none" else {
                return unknown(tool: "Claude", deviceID: deviceID, now: now)
            }
            return AccountPresence(deviceID: deviceID, tool: "Claude", state: .loggedIn, account: nil,
                                   sampledAt: now, basis: .identityUnavailable, method: nil)
        }
        let identity = oauth && profileMatches ? account : nil
        return AccountPresence(deviceID: deviceID, tool: "Claude", state: .loggedIn, account: identity, sampledAt: now,
                               basis: !profileMatches && oauth ? .profileMismatch : identity == nil ? .identityUnavailable : .cliStatus, method: method)
    }

    /// A missing/failed device observation is not evidence of logout.
    static func completingDevice(_ observations: [AccountPresence]?, deviceID: String, now: TimeInterval) -> [AccountPresence] {
        ["Codex", "Claude"].map { tool in
            observations?.first(where: { $0.deviceID == deviceID && $0.tool == tool }) ?? unknown(tool: tool, deviceID: deviceID, now: now)
        }
    }

    static func unknown(tool: String, deviceID: String, now: TimeInterval) -> AccountPresence {
        AccountPresence(deviceID: deviceID, tool: tool, state: .unknown, account: nil, sampledAt: now, basis: .statusUnavailable, method: nil)
    }

    static func codexMetadata(path: String) -> CodexMetadata? {
        readMetadataFile(path).flatMap { try? JSONDecoder().decode(CodexMetadata.self, from: $0) }
    }
    private static func claudeMetadata(_ path: String) -> AccountIdentity? {
        readMetadataFile(path).flatMap { try? JSONDecoder().decode(ClaudeMetadata.self, from: $0) }?.account
    }
    private static func readMetadataFile(_ path: String) -> Data? {
        let limit = 512 * 1024
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return nil }
        return data
    }
    private static func readCredentialStore(_ path: String) -> String? {
        var info = stat()
        if path.withCString({ lstat($0, &info) }) != 0 { return errno == ENOENT ? "file" : nil }
        guard let data = readMetadataFile(path) else { return nil }
        return credentialStore(data)
    }
    /// Official packaged default is file; keyring/auto/ephemeral metadata must not
    /// be confused with an old auth.json that is no longer the active store.
    static func credentialStore(_ data: Data?) -> String? {
        guard let data else { return "file" }
        var found: String?
        let key = Array("cli_auth_credentials_store".utf8)
        let keys = [key, [34] + key + [34], [39] + key + [39]]
        for raw in data.split(separator: 10) {
            let line = raw.drop(while: { $0 == 32 || $0 == 9 })
            if line.isEmpty || line.first == 35 { continue }
            // Unsupported multiline/escaped key syntax cannot establish that
            // an old auth.json still represents the current credential store.
            let bytes = Data(line)
            if ["\"\"\"", "'''", "\\u", "\\U"].contains(where: { bytes.range(of: Data($0.utf8)) != nil }) { return nil }
            guard let spelling = keys.first(where: { line.starts(with: $0) }) else {
                if bytes.range(of: Data(key)) != nil { return nil }
                continue
            }
            let rest = line.dropFirst(spelling.count).drop(while: { $0 == 32 || $0 == 9 })
            guard rest.first == 61 else { return nil }
            let value = rest.dropFirst().drop(while: { $0 == 32 || $0 == 9 })
            guard let quote = value.first, quote == 34 || quote == 39,
                  let end = value.dropFirst().firstIndex(of: quote) else { return nil }
            let modeBytes = value[value.index(after: value.startIndex)..<end]
            let trailing = value[value.index(after: end)...].drop(while: { $0 == 32 || $0 == 9 || $0 == 13 })
            guard trailing.isEmpty || trailing.first == 35,
                  let mode = String(data: Data(modeBytes), encoding: .utf8), ["file", "keyring", "auto", "ephemeral"].contains(mode),
                  found == nil || found == mode else { return nil }
            found = mode
        }
        return found ?? "file"
    }
    private static func executable(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    private static func runStatus(_ executable: String, _ arguments: [String], environment: [String: String], includeStderr: Bool = true) -> Status? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory())
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = includeStderr ? pipe : FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        let capture = Capture()
        DispatchQueue.global(qos: .utility).async {
            var output = Data(); var oversized = false
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                if output.count + chunk.count <= 64 * 1024 { output.append(chunk) } else { oversized = true }
            }
            capture.lock.lock(); capture.data = output; capture.oversized = oversized; capture.lock.unlock()
            drained.signal()
        }
        let deadline = DispatchTime.now() + 5
        guard exited.wait(timeout: deadline) == .success else {
            // Only this newly-created read-only status child is managed here.
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 0.2) == .timedOut && process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        guard drained.wait(timeout: .now() + 1) == .success else { return nil }
        capture.lock.lock(); defer { capture.lock.unlock() }
        guard !capture.oversized else { return nil }
        return Status(exitCode: process.terminationStatus, output: capture.data)
    }

    static func selfTest() {
        let a = AccountIdentity(provider: "openai", accountID: "fixture-current")!
        let signedIn = Status(exitCode: 0, output: Data("Logged in using ChatGPT\n".utf8))
        precondition(codexPresence(signedIn, account: a, now: 100).isIdentifiedLogin)
        precondition(codexPresence(signedIn, account: a, now: 100).isFresh(now: 120, maxAge: 30))
        precondition(!codexPresence(signedIn, account: a, now: 100).isFresh(now: 140, maxAge: 30))
        precondition(!codexPresence(signedIn, account: a, now: 200).isFresh(now: 100, maxAge: 60))
        precondition(codexPresence(signedIn, account: nil, now: 100).state == .loggedIn)
        precondition(codexPresence(signedIn, account: a, profileMatches: false, now: 100).account == nil)
        precondition(codexPresence(Status(exitCode: 1, output: Data("Not logged in\n".utf8)), account: a, now: 100).state == .loggedOut)
        precondition(codexPresence(nil, account: a, now: 100).state == .unknown)
        let key = Status(exitCode: 0, output: Data("Logged in using an API key - fixture-redacted\n".utf8))
        precondition(codexPresence(key, account: a, now: 100).account == nil)
        precondition(codexPresence(key, account: a, now: 100).method == "apiKey")
        let claude = AccountIdentity(provider: "anthropic", accountID: "fixture-claude", workspaceID: "fixture-org")!
        let oauth = Status(exitCode: 0, output: Data(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"ignored"}"#.utf8))
        precondition(claudePresence(oauth, account: claude, now: 100).account == claude)
        let out = Status(exitCode: 1, output: Data(#"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}"#.utf8))
        precondition(claudePresence(out, account: claude, now: 100).state == .loggedOut)
        precondition(claudePresence(nil, account: claude, now: 100).state == .unknown)
        let external = Status(exitCode: 0, output: Data(#"{"loggedIn":true,"authMethod":"api_key","apiProvider":"thirdParty"}"#.utf8))
        precondition(claudePresence(external, account: claude, now: 100).account == nil)
        let newMethod = Status(exitCode: 0, output: Data(#"{"loggedIn":true,"authMethod":"future-method","apiProvider":"firstParty"}"#.utf8))
        precondition(claudePresence(newMethod, account: claude, now: 100).method == nil)
        precondition(claudePresence(newMethod, account: claude, now: 100).state == .loggedIn)
        precondition(claudePresence(newMethod, account: claude, now: 100).account == nil)
        precondition(claudePresence(newMethod, account: claude, now: 100).basis == .identityUnavailable)
        precondition(!claudePresence(newMethod, account: claude, now: 100).isIdentifiedLogin)
        let missingMethod = Status(exitCode: 0, output: Data(#"{"loggedIn":true,"apiProvider":"firstParty"}"#.utf8))
        precondition(claudePresence(missingMethod, account: claude, now: 100).state == .unknown)
        let contradictory = Status(exitCode: 0, output: Data(#"{"loggedIn":true,"authMethod":"none","apiProvider":"firstParty"}"#.utf8))
        precondition(claudePresence(contradictory, account: claude, now: 100).state == .unknown)
        let emptyMethod = Status(exitCode: 0, output: Data(#"{"loggedIn":true,"authMethod":"","apiProvider":"firstParty"}"#.utf8))
        precondition(claudePresence(emptyMethod, account: claude, now: 100).state == .unknown)
        let failedNewMethod = Status(exitCode: 1, output: newMethod.output)
        precondition(claudePresence(failedNewMethod, account: claude, now: 100).state == .unknown)
        precondition(claudePresence(Status(exitCode: 0, output: out.output), account: claude, now: 100).state == .unknown)
        precondition(credentialStore(nil) == "file")
        precondition(credentialStore(Data("# cli_auth_credentials_store = \"keyring\"\n".utf8)) == "file")
        precondition(credentialStore(Data("cli_auth_credentials_store = \"keyring\"\n".utf8)) == "keyring")
        precondition(credentialStore(Data("cli_auth_credentials_store = \"file\"\n[profiles.test]\ncli_auth_credentials_store = \"auto\"\n".utf8)) == nil)
        for store in ["file", "keyring", "auto", "ephemeral"] {
            for spelling in ["cli_auth_credentials_store", "\"cli_auth_credentials_store\"", "'cli_auth_credentials_store'"] {
                for quote in ["\"", "'"] {
                    let config = "\t" + spelling + " = " + quote + store + quote + " # note\r\n"
                    precondition(credentialStore(Data(config.utf8)) == store)
                    let current = codexPresence(signedIn, account: store == "file" ? a : nil, profileMatches: store == "file", now: 100)
                    precondition(current.isIdentifiedLogin == (store == "file"), "Nonfile stores never inherit old file metadata")
                }
            }
        }
        let ambiguousConfigs = [
            "profiles.other.cli_auth_credentials_store = \"keyring\"\n",
            "\"cli_auth_cred\\u0065ntials_store\" = \"keyring\"\n",
            "cli_auth_credentials_store = \"file\"\n[profiles.other]\n\"cli_auth_credentials_store\" = \"keyring\"\n",
            "description = \"\"\"\ncli_auth_credentials_store = \"keyring\"\n\"\"\"\n",
            "cli_auth_credentials_store = \"file\" garbage\n",
            "cli_auth_credentials_store = \"\"\"file\"\"\"\n"
        ]
        for config in ambiguousConfigs { precondition(credentialStore(Data(config.utf8)) == nil) }
        let metadata = try! JSONDecoder().decode(CodexMetadata.self, from: Data(#"{"auth_mode":"chatgpt","tokens":{"account_id":"fixture-current","id_token":{"ignored":true},"access_token":42},"OPENAI_API_KEY":["ignored"]}"#.utf8))
        precondition(metadata.account == a, "Only account_id metadata is decoded, not credential values")
        precondition(!AccountPresence(deviceID: "remote", tool: "Codex", state: .unknown, account: a, sampledAt: 100, basis: .statusUnavailable, method: "chatgpt").isIdentifiedLogin)
        precondition(completingDevice(nil, deviceID: "remote", now: 100).allSatisfy { $0.state == .unknown })
        precondition(completingDevice([], deviceID: "remote", now: 100).allSatisfy { $0.state == .unknown })
        let remote = codexPresence(signedIn, account: a, deviceID: "remote", now: 100)
        let partial = completingDevice([remote], deviceID: "remote", now: 110)
        precondition(partial[0].isIdentifiedLogin && partial[1].state == .unknown)
        precondition(completingDevice([remote], deviceID: "other", now: 110).allSatisfy { $0.state == .unknown })
    }
}
