import Foundation

/// Provider-issued, non-secret account metadata. Credentials and email addresses never belong here.
public struct AccountIdentity: Codable, Hashable {
    public let provider: String
    public let accountID: String
    public let workspaceID: String?
    public var displayLabel: String?

    public init?(provider: String, accountID: String, workspaceID: String? = nil, displayLabel: String? = nil) {
        func identifier(_ raw: String) -> String? {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return UUID(uuidString: value)?.uuidString.lowercased() ?? value
        }
        guard let subject = identifier(accountID), let rawProvider = identifier(provider) else { return nil }
        switch rawProvider.lowercased() {
        case "codex", "openai": self.provider = "openai"
        case "claude", "anthropic": self.provider = "anthropic"
        default: self.provider = rawProvider.lowercased()
        }
        self.accountID = subject
        self.workspaceID = workspaceID.flatMap(identifier)
        self.displayLabel = displayLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var key: String { [provider, accountID, workspaceID ?? ""].joined(separator: "\u{1f}") }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }

    private enum CodingKeys: String, CodingKey { case provider, accountID, workspaceID, displayLabel }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        guard let identity = Self(provider: try fields.decode(String.self, forKey: .provider),
                                  accountID: try fields.decode(String.self, forKey: .accountID),
                                  workspaceID: try fields.decodeIfPresent(String.self, forKey: .workspaceID),
                                  displayLabel: try fields.decodeIfPresent(String.self, forKey: .displayLabel)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid account identity"))
        }
        self = identity
    }
}

/// A completed Codex turn's own first-token metric, separate from usage records and HTTP first-byte timing.
public struct TurnLatencySample: Codable, Equatable, Identifiable {
    public var turnID: String
    public var source: String
    public var timestamp: TimeInterval
    public var startedAt: TimeInterval?
    public var milliseconds: Double
    public var model: String?
    public var account: AccountIdentity?
    public var failed: Bool

    public init(turnID: String, source: String, timestamp: TimeInterval, milliseconds: Double,
                startedAt: TimeInterval? = nil, model: String? = nil, account: AccountIdentity? = nil, failed: Bool = false) {
        self.turnID = turnID; self.source = source; self.timestamp = timestamp; self.milliseconds = milliseconds
        self.startedAt = startedAt; self.model = model; self.account = account; self.failed = failed
    }

    public var id: String { source + "\u{0}" + turnID }
    /// Codex records a true first-token time; Claude / opencode samples are first-response approximations.
    public var isNativeFirstToken: Bool { UsageHistory.cli(of: source) == "Codex" }
    public var isSuccessfulSample: Bool {
        !failed && !turnID.isEmpty && timestamp.isFinite && timestamp > 0 && milliseconds.isFinite && milliseconds >= 0
    }
}
