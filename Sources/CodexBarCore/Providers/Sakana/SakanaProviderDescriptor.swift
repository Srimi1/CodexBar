import Foundation

public enum SakanaProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .sakana,
            metadata: ProviderMetadata(
                id: .sakana,
                displayName: "Sakana AI",
                sessionLabel: "5-hour quota",
                weeklyLabel: "Weekly quota",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Sakana console quota. API keys validate model access only.",
                toggleTitle: "Show Sakana AI usage",
                cliName: "sakana",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                browserCookieOrder: ProviderBrowserCookieDefaults.sakanaCookieImportOrder,
                dashboardURL: "https://console.sakana.ai/overview",
                subscriptionDashboardURL: "https://console.sakana.ai/billing",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .sakana,
                iconResourceName: "ProviderIcon-sakana",
                color: ProviderColor(red: 23 / 255, green: 154 / 255, blue: 139 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: false,
                noDataMessage: { "Sakana cost history is not available from CodexBar." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .web, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { context in
                    switch context.sourceMode {
                    case .api:
                        [SakanaAPIFetchStrategy()]
                    case .web:
                        [SakanaConsoleFetchStrategy()]
                    case .auto:
                        [SakanaConsoleFetchStrategy(), SakanaAPIFetchStrategy()]
                    case .cli, .oauth:
                        []
                    }
                })),
            cli: ProviderCLIConfig(
                name: "sakana",
                aliases: ["sakana-ai", "sakana.ai"],
                versionDetector: nil))
    }
}

struct SakanaConsoleFetchStrategy: ProviderFetchStrategy {
    let id: String = "sakana.console"
    let kind: ProviderFetchKind = .web

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        await self.cookieHeader(context: context) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let cookieHeader = await self.cookieHeader(context: context) else {
            throw SakanaUsageError.missingCredentials
        }
        let quota = try await SakanaUsageFetcher.fetchConsoleQuota(
            cookieHeader: cookieHeader,
            environment: context.env)
        return self.makeResult(usage: quota.toUsageSnapshot(), sourceLabel: "web")
    }

    func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        guard context.sourceMode == .auto else { return false }
        if case SakanaUsageError.invalidCredentials = error {
            return true
        }
        if case SakanaUsageError.parseFailed = error {
            return true
        }
        return error is URLError
    }

    private func cookieHeader(context: ProviderFetchContext) async -> String? {
        let settings = context.settings?.sakana ?? ProviderSettingsSnapshot.CookieProviderSettings(
            cookieSource: .auto,
            manualCookieHeader: nil)
        if settings.cookieSource == .manual {
            return SakanaSettingsReader.cleanedCookie(settings.manualCookieHeader)
        }
        if settings.cookieSource == .off {
            return nil
        }
        if let cookie = SakanaSettingsReader.sessionCookie(environment: context.env) {
            return cookie
        }
        #if os(macOS)
        return try? SakanaCookieImporter.importCookieHeader()
        #else
        return nil
        #endif
    }
}

struct SakanaAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "sakana.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        SakanaSettingsReader.apiKey(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        guard let apiKey = SakanaSettingsReader.apiKey(environment: context.env) else {
            throw SakanaUsageError.missingCredentials
        }
        let validation = try await SakanaUsageFetcher.validateAPIKey(
            apiKey: apiKey,
            environment: context.env)
        return self.makeResult(usage: validation.toUsageSnapshot(), sourceLabel: "api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
