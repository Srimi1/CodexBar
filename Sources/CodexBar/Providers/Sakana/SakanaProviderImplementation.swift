import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct SakanaProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .sakana

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "api/web" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.sakanaAPIKey
        _ = settings.sakanaCookieSource
        _ = settings.sakanaCookieHeader
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if SakanaSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        if SakanaSettingsReader.sessionCookie(environment: context.environment) != nil {
            return true
        }
        if !context.settings.sakanaAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if context.settings.sakanaCookieSource == .manual {
            return !context.settings.sakanaCookieHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return context.settings.sakanaCookieSource == .auto
    }

    @MainActor
    func settingsSnapshot(context: ProviderSettingsSnapshotContext) -> ProviderSettingsSnapshotContribution? {
        .sakana(context.settings.sakanaSettingsSnapshot(tokenOverride: context.tokenOverride))
    }

    @MainActor
    func settingsPickers(context: ProviderSettingsContext) -> [ProviderSettingsPickerDescriptor] {
        let cookieBinding = Binding(
            get: { context.settings.sakanaCookieSource.rawValue },
            set: { raw in
                context.settings.sakanaCookieSource = ProviderCookieSource(rawValue: raw) ?? .auto
            })
        let cookieOptions = ProviderCookieSourceUI.options(
            allowsOff: false,
            keychainDisabled: context.settings.debugDisableKeychainAccess)

        return [
            ProviderSettingsPickerDescriptor(
                id: "sakana-cookie-source",
                title: "Cookie source",
                subtitle: "Automatic imports Sakana console cookies from Chrome.",
                dynamicSubtitle: {
                    ProviderCookieSourceUI.subtitle(
                        source: context.settings.sakanaCookieSource,
                        keychainDisabled: context.settings.debugDisableKeychainAccess,
                        auto: "Automatic imports Sakana console cookies from Chrome.",
                        manual: "Paste a Cookie header or cURL capture from Sakana console.",
                        off: "Sakana console cookies are disabled.")
                },
                binding: cookieBinding,
                options: cookieOptions,
                isVisible: nil,
                onChange: nil),
        ]
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "sakana-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json. Validates fugu and fugu-ultra model access.",
                kind: .secure,
                placeholder: "Sakana API key...",
                binding: context.stringBinding(\.sakanaAPIKey),
                actions: Self.dashboardActions(),
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "sakana-cookie",
                title: "Cookie header",
                subtitle: "Used only when Cookie source is Manual.",
                kind: .secure,
                placeholder: "Cookie: ...",
                binding: context.stringBinding(\.sakanaCookieHeader),
                actions: [],
                isVisible: { context.settings.sakanaCookieSource == .manual },
                onActivate: { context.settings.ensureSakanaCookieLoaded() }),
        ]
    }

    @MainActor
    private static func dashboardActions() -> [ProviderSettingsActionDescriptor] {
        [
            self.linkAction(id: "sakana-overview", title: "Open Overview", url: "https://console.sakana.ai/overview"),
            self.linkAction(id: "sakana-billing", title: "Open Billing", url: "https://console.sakana.ai/billing"),
            self.linkAction(id: "sakana-pricing", title: "Open Pricing", url: "https://console.sakana.ai/pricing"),
        ]
    }

    @MainActor
    private static func linkAction(id: String, title: String, url: String) -> ProviderSettingsActionDescriptor {
        ProviderSettingsActionDescriptor(
            id: id,
            title: title,
            style: .link,
            isVisible: nil,
            perform: {
                if let url = URL(string: url) {
                    NSWorkspace.shared.open(url)
                }
            })
    }
}
