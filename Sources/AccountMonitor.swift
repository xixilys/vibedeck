import Foundation

/// Quota persistence runs with the background scanner. Views only receive an in-memory copy.
final class AccountMonitor {
    static let shared = AccountMonitor()
    private let lock = NSLock()
    private var store: AccountCycleStore?
    private var cached: [AccountQuotaObservation] = []
    private var evidence: [AccountQuotaObservation] = []
    private var error: String?

    func record(report: ScanReport) {
        if store == nil {
            let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/vibedeck/account-cycles.json").path
            store = AccountCycleStore(path: path)
        }
        store?.record(AccountUsage.quotaObservations(report: report, mergingAccounts: false))
        lock.lock()
        cached = store?.observations ?? []
        evidence = Array((store?.perSourceObservations ?? []).suffix(4000))
        error = store?.persistenceError
        lock.unlock()
    }

    func snapshot() -> [AccountQuotaObservation] {
        lock.lock(); defer { lock.unlock() }
        return cached
    }
    /// Unmerged per-device observations: the estimator uses every device's own baseline as one sample.
    func quotaEvidence() -> [AccountQuotaObservation] {
        lock.lock(); defer { lock.unlock() }
        return evidence
    }
    func persistenceError() -> String? {
        lock.lock(); defer { lock.unlock() }
        return error
    }
}
