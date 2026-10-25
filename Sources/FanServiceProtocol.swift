import Foundation

@objc(VGFanServiceProtocol) protocol VGFanServiceProtocol {
    func perform(_ command: String, rpm: Int, withReply reply: @escaping (Int32, String) -> Void)
}

enum FanServiceConfiguration {
    static let serviceName = "io.github.xixilys.vibedeck.fan-control"
    static let helperPath = "/Library/PrivilegedHelperTools/" + serviceName
    static let manifestPath = helperPath + ".plist"
    static let protocolVersion = 1

    static func requirement(codeHashes: [String]) -> String? {
        guard !codeHashes.isEmpty, codeHashes.allSatisfy({ hash in
            hash.utf8.count == 40 && hash.utf8.allSatisfy {
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }
        }) else { return nil }
        return codeHashes.map { "cdhash H\"\($0.lowercased())\"" }.joined(separator: " or ")
    }
}
