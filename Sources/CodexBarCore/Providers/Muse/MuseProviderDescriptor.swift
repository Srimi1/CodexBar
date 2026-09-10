import Foundation

public enum MuseProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .muse,
            metadata: ProviderMetadata(
                id: .muse,
                displayName: "Muse",
                sessionLabel: "Today",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "",
                toggleTitle: "Show Muse Code usage",
                cliName: "muse",
                defaultEnabled: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                dashboardURL: "https://developer.meta.com/ai",
                subscriptionDashboardURL: "https://developer.meta.com/ai",
                changelogURL: "https://developer.meta.com/ai/resources/blog/muse-code-new-plans-and-features/",
                statusPageURL: nil,
                statusLinkURL: "https://developer.meta.com/ai"),
            branding: ProviderBranding(
                iconStyle: .muse,
                iconResourceName: "ProviderIcon-muse",
                color: ProviderColor(red: 0 / 255, green: 100 / 255, blue: 224 / 255)),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: { "No Muse sessions or token usage found." }),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .cli, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: self.resolveStrategies)),
            cli: ProviderCLIConfig(
                name: "muse",
                aliases: ["muse-code"],
                versionDetector: { _ in MuseStatusProbe.detectCLIVersion() }))
    }

    private static func resolveStrategies(context: ProviderFetchContext) async -> [any ProviderFetchStrategy] {
        [MuseFetchStrategy()]
    }
}

public struct MuseFetchStrategy: ProviderFetchStrategy {
    public let id = "muse.default"
    public let kind = ProviderFetchKind.localProbe

    public init() {}

    public func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        true
    }

    public func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        let usage = try await MuseUsageFetcher.fetchUsage(environment: context.env)
        return self.makeResult(usage: usage, sourceLabel: "Muse Code")
    }

    public func shouldFallback(on error: Error, context: ProviderFetchContext) -> Bool {
        false
    }
}
