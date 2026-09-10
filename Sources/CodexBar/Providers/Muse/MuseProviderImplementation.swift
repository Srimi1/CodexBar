import AppKit
import CodexBarCore
import Foundation
import SwiftUI

struct MuseProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .muse

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "cli/sessions" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings.museAPIKey
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        if MuseSettingsReader.apiKey(environment: context.environment) != nil {
            return true
        }
        if !context.settings.museAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        let probe = MuseStatusProbe.probe(environment: context.environment)
        return probe.isInstalled || probe.hasConfig || probe.hasSessions
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "muse-api-key",
                title: "API key",
                subtitle: "Stored in ~/.codexbar/config.json or META_API_KEY / MUSE_API_KEY.",
                kind: .secure,
                placeholder: "Meta API key...",
                binding: context.stringBinding(\.museAPIKey),
                actions: Self.dashboardActions(),
                isVisible: nil,
                onActivate: nil),
        ]
    }

    @MainActor
    private static func dashboardActions() -> [ProviderSettingsActionDescriptor] {
        [
            self.linkAction(
                id: "muse-docs",
                title: "Open Documentation",
                url: "https://developer.meta.com/ai"),
            self.linkAction(
                id: "muse-blog",
                title: "Open Muse Blog",
                url: "https://developer.meta.com/ai/resources/blog/muse-code-new-plans-and-features/"),
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
                guard let target = URL(string: url) else { return }
                NSWorkspace.shared.open(target)
            })
    }
}
