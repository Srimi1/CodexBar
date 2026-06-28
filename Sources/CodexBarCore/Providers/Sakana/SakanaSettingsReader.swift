import Foundation

public enum SakanaSettingsError: LocalizedError, Sendable, Equatable {
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidEndpointOverride(key):
            "Sakana endpoint override \(key) must be an HTTPS URL."
        }
    }
}

public enum SakanaSettingsReader {
    public static let apiKeyEnvironmentKey = "SAKANA_API_KEY"
    public static let sessionCookieEnvironmentKey = "SAKANA_SESSION_COOKIE"
    public static let apiURLEnvironmentKey = "SAKANA_API_URL"
    public static let consoleURLEnvironmentKey = "SAKANA_CONSOLE_URL"

    public static let defaultAPIURL = URL(string: "https://api.sakana.ai")!
    public static let defaultConsoleURL = URL(string: "https://console.sakana.ai")!

    public static func apiKey(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    public static func sessionCookie(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        self.cleanedCookie(environment[self.sessionCookieEnvironmentKey])
    }

    public static func apiURL(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        try self.httpsURL(
            environment: environment,
            key: self.apiURLEnvironmentKey,
            defaultURL: self.defaultAPIURL)
    }

    public static func apiV1URL(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let baseURL = try self.apiURL(environment: environment).standardizedBaseURL()
        if baseURL.pathComponents.last == "v1" {
            return baseURL
        }
        return baseURL.appendingPathComponent("v1")
    }

    public static func consoleURL(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        try self.httpsURL(
            environment: environment,
            key: self.consoleURLEnvironmentKey,
            defaultURL: self.defaultConsoleURL)
    }

    public static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.count >= 2,
           let first = value.first,
           let last = value.last,
           first == "\"" && last == "\"" || first == "'" && last == "'"
        {
            value.removeFirst()
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }

    public static func cleanedCookie(_ raw: String?) -> String? {
        guard let cleaned = self.cleaned(raw) else { return nil }
        if cleaned.localizedCaseInsensitiveContains("curl ") {
            return self.cookieHeader(fromCurl: cleaned)
        }
        if cleaned.lowercased().hasPrefix("cookie:") {
            return self.cleaned(String(cleaned.dropFirst("cookie:".count)))
        }
        return cleaned
    }

    private static func cookieHeader(fromCurl curl: String) -> String? {
        let pattern = #"(?i)(?:-H|--header)\s+(['"])Cookie:\s*([^'"]+)\1"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(curl.startIndex..<curl.endIndex, in: curl)
        guard let match = regex.firstMatch(in: curl, range: range),
              let cookieRange = Range(match.range(at: 2), in: curl)
        else {
            return nil
        }
        return self.cleaned(String(curl[cookieRange]))
    }

    private static func httpsURL(environment: [String: String], key: String, defaultURL: URL) throws -> URL {
        guard let raw = self.cleaned(environment[key]) else { return defaultURL }
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false
        else {
            throw SakanaSettingsError.invalidEndpointOverride(key)
        }
        return url
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
