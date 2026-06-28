import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SakanaUsageError: LocalizedError, Sendable, Equatable {
    case missingCredentials
    case invalidCredentials(String)
    case invalidURL
    case apiError(String)
    case parseFailed(String)
    case consoleLoginRequired

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "Missing Sakana API key or console cookie. Set apiKey/cookieHeader in ~/.codexbar/config.json, or SAKANA_API_KEY/SAKANA_SESSION_COOKIE."
        case let .invalidCredentials(message):
            "Sakana credentials were rejected. \(message)"
        case .invalidURL:
            "Sakana URL is invalid."
        case let .apiError(message):
            "Sakana API error: \(message)"
        case let .parseFailed(message):
            "Sakana quota parse error: \(message)"
        case .consoleLoginRequired:
            "Sakana API key is valid, but remaining quota requires a logged-in Sakana console session."
        }
    }
}

public struct SakanaConsoleQuotaSnapshot: Sendable, Equatable {
    public let fiveHourWindow: RateWindow
    public let weeklyWindow: RateWindow
    public let planName: String?
    public let subscriptionRenewsAt: Date?
    public let updatedAt: Date

    public init(
        fiveHourWindow: RateWindow,
        weeklyWindow: RateWindow,
        planName: String?,
        subscriptionRenewsAt: Date?,
        updatedAt: Date)
    {
        self.fiveHourWindow = fiveHourWindow
        self.weeklyWindow = weeklyWindow
        self.planName = planName
        self.subscriptionRenewsAt = subscriptionRenewsAt
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        UsageSnapshot(
            primary: self.fiveHourWindow,
            secondary: self.weeklyWindow,
            subscriptionRenewsAt: self.subscriptionRenewsAt,
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .sakana,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: self.planName),
            dataConfidence: .percentOnly)
    }
}

public struct SakanaAPIValidationSnapshot: Sendable, Equatable {
    public let modelIDs: [String]
    public let updatedAt: Date

    public init(modelIDs: [String], updatedAt: Date) {
        self.modelIDs = modelIDs
        self.updatedAt = updatedAt
    }

    public func toUsageSnapshot() -> UsageSnapshot {
        let modelList = self.modelIDs
            .filter { $0 == "fugu" || $0 == "fugu-ultra" }
            .sorted()
            .joined(separator: ", ")
        let loginMethod = modelList.isEmpty
            ? "Sakana API key valid; console login required"
            : "Sakana API key valid (\(modelList)); console login required"
        return UsageSnapshot(
            primary: nil,
            secondary: nil,
            extraRateWindows: [
                NamedRateWindow(
                    id: "sakana-quota-required",
                    title: "Console quota",
                    window: RateWindow(
                        usedPercent: 0,
                        windowMinutes: nil,
                        resetsAt: nil,
                        resetDescription: "Sign in to Sakana console to show quota."),
                    usageKnown: false),
            ],
            updatedAt: self.updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .sakana,
                accountEmail: nil,
                accountOrganization: nil,
                loginMethod: loginMethod),
            dataConfidence: .unknown)
    }
}

public enum SakanaUsageFetcher {
    private static let requestTimeoutSeconds: TimeInterval = 15

    public static func fetchConsoleQuota(
        cookieHeader: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> SakanaConsoleQuotaSnapshot
    {
        guard let cookie = SakanaSettingsReader.cleanedCookie(cookieHeader) else {
            throw SakanaUsageError.missingCredentials
        }
        let consoleURL = try SakanaSettingsReader.consoleURL(environment: environment).standardizedBaseURL()
        let firstError: Error
        do {
            return try await self.fetchConsolePage(
                path: "overview",
                consoleURL: consoleURL,
                cookieHeader: cookie,
                transport: transport,
                now: now)
        } catch {
            firstError = error
        }

        do {
            return try await self.fetchConsolePage(
                path: "billing",
                consoleURL: consoleURL,
                cookieHeader: cookie,
                transport: transport,
                now: now)
        } catch SakanaUsageError.invalidCredentials {
            throw SakanaUsageError.invalidCredentials("Console cookie is expired or cannot access billing.")
        } catch {
            throw firstError
        }
    }

    public static func validateAPIKey(
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        now: Date = Date()) async throws -> SakanaAPIValidationSnapshot
    {
        guard let token = SakanaSettingsReader.cleaned(apiKey) else {
            throw SakanaUsageError.missingCredentials
        }
        let baseURL = try SakanaSettingsReader.apiV1URL(environment: environment)
        let url = baseURL.appendingPathComponent("models")
        guard url.scheme?.lowercased() == "https" else {
            throw SakanaUsageError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.requestTimeoutSeconds

        let response = try await transport.response(for: request, retryPolicy: .transientIdempotent)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw SakanaUsageError.invalidCredentials("Check the Sakana API key in Settings.")
            }
            throw SakanaUsageError.apiError("HTTP \(response.statusCode).")
        }

        let modelIDs = try self.modelIDs(from: response.data)
        guard modelIDs.contains("fugu"), modelIDs.contains("fugu-ultra") else {
            throw SakanaUsageError.parseFailed("Models API did not list both fugu and fugu-ultra.")
        }
        return SakanaAPIValidationSnapshot(modelIDs: modelIDs, updatedAt: now)
    }

    static func parseConsoleQuota(data: Data, now: Date = Date()) throws -> SakanaConsoleQuotaSnapshot {
        let html = String(decoding: data, as: UTF8.self)
        guard !self.looksLikeLoginPage(html) else {
            throw SakanaUsageError.invalidCredentials("Sakana console login is required.")
        }

        let text = self.visibleText(from: html)
        guard let fiveHour = self.quotaWindow(named: .fiveHour, text: text),
              let weekly = self.quotaWindow(named: .weekly, text: text)
        else {
            throw SakanaUsageError.parseFailed("No 5-hour and weekly quota values were found.")
        }

        return SakanaConsoleQuotaSnapshot(
            fiveHourWindow: RateWindow(
                usedPercent: fiveHour.usedPercent,
                windowMinutes: 5 * 60,
                resetsAt: nil,
                resetDescription: fiveHour.description),
            weeklyWindow: RateWindow(
                usedPercent: weekly.usedPercent,
                windowMinutes: 7 * 24 * 60,
                resetsAt: nil,
                resetDescription: weekly.description),
            planName: self.planName(from: text),
            subscriptionRenewsAt: self.renewalDate(from: text),
            updatedAt: now)
    }

    private static func fetchConsolePage(
        path: String,
        consoleURL: URL,
        cookieHeader: String,
        transport: any ProviderHTTPTransport,
        now: Date) async throws -> SakanaConsoleQuotaSnapshot
    {
        let url = consoleURL.appendingPathComponent(path)
        guard url.scheme?.lowercased() == "https" else {
            throw SakanaUsageError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.requestTimeoutSeconds

        let response = try await transport.response(for: request, retryPolicy: .transientIdempotent)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw SakanaUsageError.invalidCredentials("Sakana console cookie was rejected.")
            }
            throw SakanaUsageError.apiError("Console HTTP \(response.statusCode).")
        }
        return try self.parseConsoleQuota(data: response.data, now: now)
    }

    private static func modelIDs(from data: Data) throws -> [String] {
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [])
            let payloads: [[String: Any]] = if let root = object as? [String: Any],
                                               let data = root["data"] as? [[String: Any]]
            {
                data
            } else if let array = object as? [[String: Any]] {
                array
            } else {
                []
            }
            let ids = payloads.compactMap { $0["id"] as? String }
            guard !ids.isEmpty else {
                throw SakanaUsageError.parseFailed("Models API returned no model IDs.")
            }
            return ids
        } catch let error as SakanaUsageError {
            throw error
        } catch {
            throw SakanaUsageError.parseFailed("Models API returned non-JSON data.")
        }
    }

    private enum WindowKind {
        case fiveHour
        case weekly

        var labels: [String] {
            switch self {
            case .fiveHour:
                ["5-hour quota", "5 hour quota", "five-hour quota", "5-hour", "5 hour"]
            case .weekly:
                ["weekly quota", "week quota", "weekly"]
            }
        }
    }

    private static func quotaWindow(
        named kind: WindowKind,
        text: String) -> (usedPercent: Double, description: String?)?
    {
        let lowercased = text.lowercased()
        for label in kind.labels {
            guard let labelRange = lowercased.range(of: label) else { continue }
            let distance = lowercased.distance(from: lowercased.startIndex, to: labelRange.lowerBound)
            let start = distance
            let end = min(text.count, distance + 220)
            let context = text[text.index(text.startIndex, offsetBy: start)..<text.index(
                text.startIndex,
                offsetBy: end)]
            if let window = self.percentWindow(from: String(context)) {
                return window
            }
        }
        return nil
    }

    private static func percentWindow(from text: String) -> (usedPercent: Double, description: String?)? {
        let patterns = [
            #"(?i)(\d+(?:\.\d+)?)\s*%\s*(used|remaining|left)"#,
            #"(?i)(used|remaining|left)\s*(\d+(?:\.\d+)?)\s*%"#,
        ]

        for pattern in patterns {
            guard let match = self.firstRegexMatch(pattern: pattern, in: text) else { continue }
            let first = match[0]
            let second = match[1]
            let rawPercent = Double(first) ?? Double(second)
            let qualifier = Double(first) == nil ? first.lowercased() : second.lowercased()
            guard let rawPercent else { continue }
            let usedPercent = qualifier.contains("remaining") || qualifier.contains("left")
                ? 100 - rawPercent
                : rawPercent
            return (
                max(0, min(100, usedPercent)),
                "\(self.formatPercent(max(0, min(100, rawPercent))))% \(qualifier)")
        }

        if let fraction = self.firstRegexMatch(pattern: #"(?i)(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)"#, in: text),
           let used = Double(fraction[0]),
           let limit = Double(fraction[1]),
           limit > 0
        {
            return (max(0, min(100, used / limit * 100)), "\(self.formatPercent(used))/\(self.formatPercent(limit))")
        }
        return nil
    }

    private static func planName(from text: String) -> String? {
        for plan in ["Standard", "Pro", "Max"] where text.range(of: plan, options: [.caseInsensitive]) != nil {
            return plan
        }
        return nil
    }

    private static func renewalDate(from text: String) -> Date? {
        let patterns = [
            #"(?i)(?:renews|renewal|next renewal|period end)[^\n]{0,80}?([A-Z][a-z]{2,8}\s+\d{1,2},\s+\d{4})"#,
            #"(?i)(?:renews|renewal|next renewal|period end)[^\n]{0,80}?(\d{4}-\d{2}-\d{2})"#,
        ]
        for pattern in patterns {
            guard let match = self.firstRegexMatch(pattern: pattern, in: text) else { continue }
            if let date = self.parseDate(match[0]) {
                return date
            }
        }
        return nil
    }

    private static func parseDate(_ value: String) -> Date? {
        let locale = Locale(identifier: "en_US_POSIX")
        for format in ["MMM d, yyyy", "MMMM d, yyyy", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    private static func looksLikeLoginPage(_ html: String) -> Bool {
        let lowercased = html.lowercased()
        if lowercased.contains("usage limit")
            || (lowercased.contains("5-hour") && lowercased.contains("weekly"))
            || lowercased.contains("token usage")
        {
            return false
        }

        let loginSignals = [
            "signin",
            "sign in",
            "login",
            "callbackurl",
            "authjs",
            "next-auth",
        ]
        guard loginSignals.contains(where: lowercased.contains) else { return false }
        return !lowercased.contains("5-hour quota") && !lowercased.contains("weekly quota")
    }

    private static func visibleText(from html: String) -> String {
        var text = html
        let replacements = [
            (#"(?is)<script.*?</script>"#, " "),
            (#"(?is)<style.*?</style>"#, " "),
            (#"(?is)<[^>]+>"#, " "),
        ]
        for (pattern, replacement) in replacements {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        let entities = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstRegexMatch(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        let groups = (1..<match.numberOfRanges).compactMap { index -> String? in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        return groups.isEmpty ? nil : groups
    }

    private static func formatPercent(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.0001 {
            return String(Int(rounded))
        }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") {
            text.removeLast()
        }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

extension URL {
    fileprivate func standardizedBaseURL() -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? self
    }
}
