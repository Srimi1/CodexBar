import Foundation

#if os(macOS)
import SweetCookieKit

public enum SakanaCookieImporter {
    private static let cookieClient = BrowserCookieClient()
    private static let domains = ["console.sakana.ai"]

    public static func importCookieHeader(
        order: BrowserCookieImportOrder? = ProviderBrowserCookieDefaults.sakanaCookieImportOrder) throws -> String?
    {
        let browsers = order ?? Browser.defaultImportOrder
        for browser in browsers {
            if let header = try self.importCookieHeader(browser: browser) {
                return header
            }
        }
        return nil
    }

    private static func importCookieHeader(browser: Browser) throws -> String? {
        let query = BrowserCookieQuery(domains: self.domains)
        let records = try Self.cookieClient.codexBarRecords(
            matching: query,
            in: browser,
            logger: { _ in })
        let sessionRecords = records
            .flatMap(\.records)
            .filter { self.isConsoleAuthCookie($0.name) }
            .sorted { $0.name < $1.name }
        let cookies = BrowserCookieClient.makeHTTPCookies(sessionRecords, origin: query.origin)
        guard !cookies.isEmpty else { return nil }
        let header = cookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        if SakanaSettingsReader.cleanedCookie(header) != nil {
            return header
        }
        return nil
    }

    private static func isConsoleAuthCookie(_ name: String) -> Bool {
        let lowercased = name.lowercased()
        guard !lowercased.hasPrefix("_ga"),
              !lowercased.hasPrefix("_gid"),
              !lowercased.hasPrefix("_gat")
        else { return false }

        return lowercased.contains("authjs")
            || lowercased.contains("next-auth")
            || lowercased.contains("session")
            || lowercased.contains("csrf")
            || lowercased.contains("callback")
            || lowercased.contains("sakana")
    }
}
#else
public enum SakanaCookieImporter {
    public static func importCookieHeader(order _: BrowserCookieImportOrder? = nil) throws -> String? {
        nil
    }
}
#endif
