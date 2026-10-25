import Foundation

/// 从 models.dev 补齐内置目录未覆盖的模型，并刷新来源可证明且未被手改的自动价。
/// 手工覆盖永远优先；内置的长上下文/Fast 规则不能被同步成平价用户行。
enum PriceSync {
    static let sourceName = "models.dev"
    static let sourceURL = "https://models.dev/api.json"
    private static let syncLock = NSLock()
    /// 同一个模型名在多个 provider 下出现时，按这个顺序取第一个（优先厂商自己的官方口径）。
    static let preferredProviders = ["deepseek", "openai", "anthropic", "zai", "zhipuai", "moonshotai", "minimax", "xiaomi", "google", "meta", "mistral", "xai"]

    struct Outcome {
        var added: [String] = []
        var updated: [String] = []
        var skipped: [String] = []
        var backupPath: String = ""
        var error: String = ""
    }

    static func pricesPath(home: String) -> String { "\(home)/.config/vibedeck/prices.json" }

    /// 本地实际用到的模型名：用量缓存里的 models + 代理记账里的 model。
    static func usedModels(home: String) -> [String] {
        var names = Set<String>()
        if let data = try? Data(contentsOf: URL(fileURLWithPath: "\(home)/.config/vibedeck/usage-daily.json")),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let days = root["days"] as? [[String: Any]] {
            for day in days {
                guard let sources = day["sources"] as? [String: Any] else { continue }
                for value in sources.values {
                    guard let totals = value as? [String: Any], let models = totals["models"] as? [String: Any] else { continue }
                    names.formUnion(models.keys)
                }
            }
        }
        if let text = try? String(contentsOfFile: "\(home)/.config/vibedeck/api-calls.jsonl", encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let model = object["model"] as? String, !model.isEmpty else { continue }
                names.insert(model)
            }
        }
        return names.sorted()
    }

    /// 拉价格库 → 小写 modelID → {in,out,cache_read,cache_write}（USD / 百万 token）。
    static func fetch(timeout: TimeInterval = 30) -> [String: [String: Double]]? {
        guard let url = URL(string: sourceURL) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        var payload: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            if error == nil, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                payload = data
            }
            done.signal()
        }.resume()
        guard done.wait(timeout: .now() + timeout + 5) == .success,
              let data = payload,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let prices = parse(root)
        return prices.isEmpty ? nil : prices
    }

    /// 纯函数：把 models.dev 的 api.json 摊平成 modelID → 价格表（便于自测）。
    static func parse(_ root: [String: Any]) -> [String: [String: Double]] {
        var out: [String: [String: Double]] = [:]
        let order = preferredProviders + root.keys.filter { !preferredProviders.contains($0) }.sorted()
        for providerID in order {
            guard let provider = root[providerID] as? [String: Any],
                  let models = provider["models"] as? [String: Any] else { continue }
            for (modelID, raw) in models {
                let key = modelID.lowercased()
                if out[key] != nil { continue }                       // 先到的优先 provider 赢
                guard let model = raw as? [String: Any], let cost = model["cost"] as? [String: Any] else { continue }
                func value(_ name: String) -> Double? { (cost[name] as? NSNumber)?.doubleValue }
                guard let input = value("input"), let output = value("output"), input > 0 || output > 0 else { continue }
                out[key] = ["in": input, "out": output,
                            "cache_read": value("cache_read") ?? input,
                            "cache_write": value("cache_write") ?? input]
            }
        }
        return out
    }

    /// _sync.rows 保存上次自动写入的原行；只有逐行相等才允许刷新，旧版无来源行视为手工价。
    static func sync(home: String, remote: [String: [String: Double]]? = nil,
                     catalog: PricingCatalog.Catalog = PricingCatalog.builtin) -> Outcome {
        syncLock.lock(); defer { syncLock.unlock() }
        var outcome = Outcome()
        let path = pricesPath(home: home)
        let url = URL(fileURLWithPath: path)
        let exists = FileManager.default.fileExists(atPath: path)
        var originalData: Data?
        var json: [String: Any] = [:]
        if exists {
            guard let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                outcome.error = "价目表无法读取或不是 JSON 对象，未修改"
                return outcome
            }
            json = object
            originalData = data
        }
        func fileUnchanged() -> Bool {
            if exists { return (try? Data(contentsOf: url)) == originalData }
            return !FileManager.default.fileExists(atPath: path)
        }
        let table = ProcessScanner.PriceTable(json: json)
        let used = usedModels(home: home)
        guard !used.isEmpty else { return outcome }
        let previousSync = json["_sync"] as? [String: Any] ?? [:]
        var tracked = previousSync["source"] as? String == sourceName
            ? (previousSync["rows"] as? [String: Any] ?? [:]) : [:]
        func isAutomatic(_ key: String) -> Bool {
            guard let current = json[key] as? [String: Any], let saved = tracked[key] as? [String: Any] else { return false }
            return NSDictionary(dictionary: current).isEqual(to: saved)
        }
        var candidates: [String] = []
        for model in used {
            let key = json.keys.first { $0.lowercased() == model.lowercased() } ?? model
            let automatic = isAutomatic(key)
            if PricingCatalog.entry(for: model, in: catalog) != nil || CostEngine.isSubscriptionIncluded(model) {
                if automatic {
                    // 回到内置目录，保留完整计价规则；只移除可证明由同步生成的原行。
                    json.removeValue(forKey: key)
                    tracked.removeValue(forKey: key)
                    outcome.updated.append(model)
                }
                continue
            }
            if !automatic, table.cost(model: model, ctx: 0, cacheRead: 0, cacheWrite: 0, out: 0) != nil { continue }
            candidates.append(model)
        }
        if !candidates.isEmpty {
            guard let prices = remote ?? fetch() else {
                outcome.updated = []
                outcome.error = "拉取 \(sourceName) 失败，未修改价目表"
                return outcome
            }
            for model in candidates {
                guard let price = prices[model.lowercased()] else {
                    outcome.skipped.append(model)
                    continue
                }
                let input = price["in"] ?? 0
                let output = price["out"] ?? 0
                guard input.isFinite, output.isFinite, input >= 0, output >= 0, input > 0 || output > 0 else {
                    outcome.skipped.append(model)
                    continue
                }
                let cacheRead = price["cache_read"] ?? input
                let cacheWrite = price["cache_write"] ?? input
                guard cacheRead.isFinite, cacheWrite.isFinite, cacheRead >= 0, cacheWrite >= 0 else {
                    outcome.skipped.append(model)
                    continue
                }
                let key = json.keys.first { $0.lowercased() == model.lowercased() } ?? model
                let row: [String: Any] = ["in": input, "out": output, "cache_read": cacheRead,
                                          "cache_write": cacheWrite, "currency": "USD"]
                if let current = json[key] as? [String: Any], NSDictionary(dictionary: current).isEqual(to: row) { continue }
                if isAutomatic(key) { outcome.updated.append(model) } else { outcome.added.append(model) }
                json[key] = row
                tracked[key] = row
            }
        }
        guard !outcome.added.isEmpty || !outcome.updated.isEmpty else { return outcome }
        json["_sync"] = ["source": sourceName, "at": ISO8601DateFormatter().string(from: Date()), "rows": tracked]
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            outcome.added = []; outcome.updated = []
            outcome.error = "写回价目表失败"
            return outcome
        }
        do {
            guard fileUnchanged() else {
                outcome.added = []; outcome.updated = []
                outcome.error = "同步期间价目表已被修改，已保留最新内容；请重新同步"
                return outcome
            }
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            if let originalData {
                let backup = path + ".backup-" + UUID().uuidString
                try originalData.write(to: URL(fileURLWithPath: backup), options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup)
                outcome.backupPath = backup
            }
            // 备份也可能耗时；写回前再次核对，原地编辑和原子替换都按原始字节检测。
            guard fileUnchanged() else {
                outcome.added = []; outcome.updated = []
                outcome.error = "同步期间价目表已被修改，已保留最新内容；请重新同步"
                return outcome
            }
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            outcome.added = []; outcome.updated = []
            outcome.error = "写回价目表失败：\(error.localizedDescription)"
        }
        return outcome
    }
}
