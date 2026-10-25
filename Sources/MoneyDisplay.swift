import Foundation
import Combine

enum DisplayCurrency: String, CaseIterable {
    case original, usd, cny
    static let defaultsKey = "vg.currency"
    var label: String {
        switch self {
        case .original: return L("原币", "Original")
        case .usd: return "USD"
        case .cny: return "CNY"
        }
    }
    var code: String? { self == .original ? nil : rawValue.uppercased() }
}

/// Reference conversion only. The original cost and its pricing currency remain unchanged.
struct ExchangeQuote: Codable, Equatable {
    var cnyPerUSD: Double
    var asOf: String
    var fetchedAt: TimeInterval
    static let sourceURL = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!

    func isUsable(at now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard cnyPerUSD.isFinite, cnyPerUSD > 0, fetchedAt.isFinite, fetchedAt <= now + 60 else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: asOf), formatter.string(from: date) == asOf else { return false }
        let age = now - date.timeIntervalSince1970
        return age >= -86400 && age <= 7 * 86400
    }

    static func parseECB(_ data: Data, fetchedAt: TimeInterval = Date().timeIntervalSince1970) -> Self? {
        final class Reader: NSObject, XMLParserDelegate {
            var date: String?
            var rates: [String: Double] = [:]
            func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
                guard elementName == "Cube" else { return }
                if let date = attributes["time"] { self.date = date }
                if let currency = attributes["currency"], let text = attributes["rate"], let rate = Double(text), rate.isFinite, rate > 0 {
                    rates[currency] = rate
                }
            }
        }
        let reader = Reader(), parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let date = reader.date, let usd = reader.rates["USD"], let cny = reader.rates["CNY"] else { return nil }
        let quote = Self(cnyPerUSD: cny / usd, asOf: date, fetchedAt: fetchedAt)
        return quote.isUsable(at: fetchedAt) ? quote : nil
    }
}

enum MoneyDisplay {
    struct Presentation {
        var text: String
        var detail: String
        var converted = false
        var conversionUnavailable = false
    }

    static func amount(_ value: Double, currency: String) -> String {
        guard value.isFinite else { return "—" }
        let formatter = CachedNumberFormatter.decimal(locale: AppLanguage.current.locale, fraction: value >= 10_000 ? 0 : 2)
        let code = currency.uppercased()
        if value > 0 && value < 0.01 { return "\(code) <0.01" }
        return code + " " + (formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value))
    }

    static func convertedValue(_ values: [String: Double], to target: String, quote: ExchangeQuote?, at now: TimeInterval = Date().timeIntervalSince1970) -> Double? {
        guard !values.isEmpty, values.values.allSatisfy({ $0.isFinite }) else { return nil }
        let target = target.uppercased()
        var result = 0.0
        for (currency, value) in values {
            let code = currency.uppercased()
            if code == target || value == 0 { result += value; continue }
            guard let quote, quote.isUsable(at: now) else { return nil }
            if code == "USD" && target == "CNY" { result += value * quote.cnyPerUSD }
            else if code == "CNY" && target == "USD" { result += value / quote.cnyPerUSD }
            else { return nil }
        }
        return result.isFinite ? result : nil
    }

    static func format(_ values: [String: Double], mode: DisplayCurrency, quote: ExchangeQuote?, at now: TimeInterval = Date().timeIntervalSince1970) -> Presentation {
        guard !values.isEmpty, values.values.allSatisfy({ $0.isFinite }) else { return Presentation(text: "—", detail: "") }
        let original = values.keys.sorted().map { amount(values[$0]!, currency: $0) }.joined(separator: " + ")
        guard let target = mode.code else { return Presentation(text: original, detail: "") }
        let needsConversion = values.contains { $0.key.uppercased() != target && $0.value != 0 }
        guard needsConversion else {
            return Presentation(text: amount(values.values.reduce(0, +), currency: target), detail: "")
        }
        guard let total = convertedValue(values, to: target, quote: quote, at: now), let quote else {
            return Presentation(text: original, detail: L("没有可用汇率，保留原币金额。", "No current reference rate; showing the original currency."), conversionUnavailable: true)
        }
        let detail = original + "\n" + L("ECB 参考汇率", "ECB reference rate") + " · " + quote.asOf
            + String(format: " · 1 USD = %.4f CNY", quote.cnyPerUSD)
        return Presentation(text: "≈" + amount(total, currency: target), detail: detail, converted: true)
    }

    static func selfTest() {
        let now = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(secondsFromGMT: 0), year: 2026, month: 10, day: 22, hour: 16).date!.timeIntervalSince1970
        let xml = Data("<Envelope><Cube><Cube time='2026-10-22'><Cube currency='USD' rate='1.1205'/><Cube currency='CNY' rate='7.4786'/></Cube></Cube></Envelope>".utf8)
        let quote = ExchangeQuote.parseECB(xml, fetchedAt: now)!
        precondition(abs(quote.cnyPerUSD - 7.4786 / 1.1205) < 0.0000001)
        precondition(convertedValue(["USD": 10, "CNY": quote.cnyPerUSD * 5], to: "USD", quote: quote, at: now).map { abs($0 - 15) < 0.000001 } == true)
        precondition(convertedValue(["CNY": 10], to: "USD", quote: nil, at: now) == nil)
        precondition(convertedValue(["EUR": 10], to: "USD", quote: quote, at: now) == nil)
        precondition(convertedValue(["USD": .nan], to: "USD", quote: quote, at: now) == nil)
        precondition(format(["CNY": 10], mode: .usd, quote: nil, at: now).conversionUnavailable)
        precondition(!format(["USD": 10], mode: .usd, quote: nil, at: now).converted)
        precondition(format(["USD": 10], mode: .cny, quote: quote, at: now).text.hasPrefix("≈CNY"))
        precondition(!quote.isUsable(at: now + 8 * 86400))
        precondition(ExchangeQuote.parseECB(Data("<Cube time='2026-10-22'><Cube currency='USD' rate='1'/></Cube>".utf8), fetchedAt: now) == nil)
    }
}

/// Loaded and refreshed off the UI thread; only the small published result reaches the panel.
final class ExchangeRates: ObservableObject {
    static let shared = ExchangeRates()
    @Published private(set) var quote: ExchangeQuote?
    private let worker = DispatchQueue(label: "vibedeck.exchange-rates", qos: .utility)
    private let cacheURL: URL
    private var loaded = false
    private var inFlight = false
    private var lastAttempt: TimeInterval = 0
    private var cached: ExchangeQuote?

    init(cacheURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/vibedeck/exchange-rate.json")) {
        self.cacheURL = cacheURL
    }

    func refreshIfNeeded() {
        worker.async { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSince1970
            if !self.loaded {
                self.loaded = true
                if let data = try? Data(contentsOf: self.cacheURL), let stored = try? JSONDecoder().decode(ExchangeQuote.self, from: data), stored.isUsable(at: now) {
                    self.cached = stored
                    DispatchQueue.main.async { self.quote = stored }
                }
            }
            let retryAfter: TimeInterval = self.cached == nil ? 3600 : 12 * 3600
            guard !self.inFlight, now - self.lastAttempt >= retryAfter else { return }
            self.lastAttempt = now
            if let cached = self.cached, now - cached.fetchedAt < 12 * 3600 { return }
            self.inFlight = true
            var request = URLRequest(url: ExchangeQuote.sourceURL)
            request.timeoutInterval = 8
            request.cachePolicy = .reloadIgnoringLocalCacheData
            URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
                guard let self else { return }
                self.worker.async {
                    self.inFlight = false
                    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), let data,
                          let quote = ExchangeQuote.parseECB(data) else { return }
                    self.cached = quote
                    if let encoded = try? JSONEncoder().encode(quote) {
                        try? FileManager.default.createDirectory(at: self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        try? encoded.write(to: self.cacheURL, options: .atomic)
                        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.cacheURL.path)
                    }
                    DispatchQueue.main.async { self.quote = quote }
                }
            }.resume()
        }
    }
}

/// NumberFormatter construction dominates panel redraws; keep one per locale and precision.
enum CachedNumberFormatter {
    private static let lock = NSLock()
    private static var cache: [String: NumberFormatter] = [:]

    static func decimal(locale: Locale, fraction: Int, minimumFraction: Int? = nil) -> NumberFormatter {
        let key = "\(locale.identifier):\(fraction):\(minimumFraction ?? fraction)"
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = minimumFraction ?? fraction
        formatter.maximumFractionDigits = fraction
        formatter.roundingMode = .halfUp
        cache[key] = formatter
        return formatter
    }
}
