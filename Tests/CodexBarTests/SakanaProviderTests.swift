import Foundation
import Testing
@testable import CodexBarCore

struct SakanaProviderTests {
    @Test
    func `settings reader trims API key and cookie header`() {
        let env = [
            SakanaSettingsReader.apiKeyEnvironmentKey: " 'sakana-key' ",
            SakanaSettingsReader.sessionCookieEnvironmentKey: " Cookie: __Secure-authjs.session-token=abc ",
        ]

        #expect(SakanaSettingsReader.apiKey(environment: env) == "sakana-key")
        #expect(SakanaSettingsReader.sessionCookie(environment: env) == "__Secure-authjs.session-token=abc")
    }

    @Test
    func `config API key projects into Sakana environment`() {
        let config = ProviderConfig(
            id: .sakana,
            apiKey: "sakana-config-key",
            cookieHeader: "__Secure-authjs.session-token=manual",
            cookieSource: .manual)
        let env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: [:],
            provider: .sakana,
            config: config)

        #expect(env[SakanaSettingsReader.apiKeyEnvironmentKey] == "sakana-config-key")
        #expect(ProviderConfigEnvironment.supportsAPIKeyOverride(for: .sakana))
        #expect(CodexBarConfigValidator.validate(CodexBarConfig(providers: [config])).isEmpty)
    }

    @Test
    func `descriptor registers Sakana provider metadata`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .sakana)

        #expect(descriptor.metadata.displayName == "Sakana AI")
        #expect(descriptor.metadata.cliName == "sakana")
        #expect(descriptor.metadata.sessionLabel == "5-hour quota")
        #expect(descriptor.metadata.weeklyLabel == "Weekly quota")
        #expect(descriptor.fetchPlan.sourceModes.contains(.auto))
        #expect(descriptor.fetchPlan.sourceModes.contains(.web))
        #expect(descriptor.fetchPlan.sourceModes.contains(.api))
    }

    @Test
    func `models API validation confirms fugu models without generation calls`() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(url.absoluteString == "https://api.sakana.test/v1/models")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sakana-key")
            #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
            #expect(request.timeoutInterval == 15)
            return Self.makeResponse(url: url, body: #"""
            {
              "object": "list",
              "data": [
                { "id": "fugu" },
                { "id": "fugu-ultra" },
                { "id": "fugu-ultra-20260615" }
              ]
            }
            """#)
        }

        let validation = try await SakanaUsageFetcher.validateAPIKey(
            apiKey: " sakana-key ",
            environment: [SakanaSettingsReader.apiURLEnvironmentKey: "https://api.sakana.test"],
            transport: transport,
            now: now)
        let usage = validation.toUsageSnapshot()

        #expect(validation.modelIDs.contains("fugu"))
        #expect(validation.modelIDs.contains("fugu-ultra"))
        #expect(usage.primary == nil)
        #expect(usage.secondary == nil)
        #expect(usage.extraRateWindows?.first?.usageKnown == false)
        #expect(usage.loginMethod(for: .sakana)?.contains("console login required") == true)

        let requests = await transport.requests()
        #expect(requests.map { $0.url?.path } == ["/v1/models"])
    }

    @Test
    func `models API validation rejects missing key unauthorized non json and timeout`() async throws {
        await #expect(throws: SakanaUsageError.missingCredentials) {
            try await SakanaUsageFetcher.validateAPIKey(apiKey: " ", transport: ProviderHTTPTransportStub { _ in
                throw URLError(.badURL)
            })
        }

        await #expect(throws: SakanaUsageError.invalidCredentials("Check the Sakana API key in Settings.")) {
            try await SakanaUsageFetcher.validateAPIKey(
                apiKey: "bad-key",
                transport: ProviderHTTPTransportStub { request in
                    try Self.makeResponse(url: #require(request.url), status: 401, body: "{}")
                })
        }

        await #expect(throws: SakanaUsageError.parseFailed("Models API returned non-JSON data.")) {
            try await SakanaUsageFetcher.validateAPIKey(
                apiKey: "bad-json",
                transport: ProviderHTTPTransportStub { request in
                    try Self.makeResponse(url: #require(request.url), body: "not json")
                })
        }

        await #expect(throws: URLError(.timedOut)) {
            try await SakanaUsageFetcher.validateAPIKey(
                apiKey: "timeout",
                transport: ProviderHTTPTransportStub { _ in
                    throw URLError(.timedOut)
                })
        }
    }

    @Test
    func `console parser maps Standard plan five hour weekly and renewal`() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let html = #"""
        <main>
          <h1>Standard</h1>
          <section><h2>5-hour quota</h2><span>18% used</span></section>
          <section><h2>Weekly quota</h2><span>42% remaining</span></section>
          <p>Renews Jul 31, 2026</p>
        </main>
        """#

        let snapshot = try SakanaUsageFetcher.parseConsoleQuota(data: Data(html.utf8), now: now)
        let usage = snapshot.toUsageSnapshot()

        #expect(usage.primary?.usedPercent == 18)
        #expect(usage.primary?.windowMinutes == 300)
        #expect(usage.secondary?.usedPercent == 58)
        #expect(usage.secondary?.windowMinutes == 10080)
        #expect(usage.loginMethod(for: .sakana) == "Standard")
        #expect(snapshot.subscriptionRenewsAt != nil)
    }

    @Test
    func `console parser supports Pro Max fraction windows and detects missing markup`() throws {
        let pro = #"""
        <main>
          <h2>Pro</h2>
          <div>5 hour quota 3 / 10</div>
          <div>Weekly quota 22% used</div>
        </main>
        """#
        let max = #"""
        <main>
          <h2>Max</h2>
          <div>five-hour quota remaining 12.5%</div>
          <div>weekly 1 / 4</div>
        </main>
        """#

        let proSnapshot = try SakanaUsageFetcher.parseConsoleQuota(data: Data(pro.utf8))
        let maxSnapshot = try SakanaUsageFetcher.parseConsoleQuota(data: Data(max.utf8))

        #expect(proSnapshot.planName == "Pro")
        #expect(proSnapshot.fiveHourWindow.usedPercent == 30)
        #expect(maxSnapshot.planName == "Max")
        #expect(maxSnapshot.fiveHourWindow.usedPercent == 87.5)
        #expect(maxSnapshot.weeklyWindow.usedPercent == 25)

        #expect(throws: SakanaUsageError.parseFailed("No 5-hour and weekly quota values were found.")) {
            try SakanaUsageFetcher.parseConsoleQuota(data: Data("<main>No quota yet</main>".utf8))
        }
    }

    @Test
    func `console fetch falls back from overview to billing and detects login page`() async throws {
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(request.value(forHTTPHeaderField: "Cookie") == "__Secure-authjs.session-token=abc")
            switch url.path {
            case "/overview":
                return Self.makeResponse(url: url, body: "<html><a href='/login'>Sign in</a></html>")
            case "/billing":
                return Self.makeResponse(url: url, body: #"""
                <main>
                  <h2>Pro</h2>
                  <div>5-hour quota 25% used</div>
                  <div>Weekly quota 80% remaining</div>
                </main>
                """#)
            default:
                Issue.record("Unexpected URL \(url)")
                return Self.makeResponse(url: url, status: 404, body: "{}")
            }
        }

        let snapshot = try await SakanaUsageFetcher.fetchConsoleQuota(
            cookieHeader: "__Secure-authjs.session-token=abc",
            environment: [SakanaSettingsReader.consoleURLEnvironmentKey: "https://console.sakana.test"],
            transport: transport)

        #expect(snapshot.planName == "Pro")
        #expect(snapshot.fiveHourWindow.usedPercent == 25)
        #expect(snapshot.weeklyWindow.usedPercent == 20)

        let requests = await transport.requests()
        #expect(requests.map { $0.url?.path } == ["/overview", "/billing"])
    }

    private static func makeResponse(url: URL, status: Int = 200, body: String) -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }
}
