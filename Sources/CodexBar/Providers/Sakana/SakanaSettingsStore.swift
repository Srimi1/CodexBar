import CodexBarCore
import Foundation

extension SettingsStore {
    var sakanaAPIKey: String {
        get { self.configSnapshot.providerConfig(for: .sakana)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .sakana) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .sakana, field: "apiKey", value: newValue)
        }
    }

    var sakanaCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .sakana)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .sakana) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .sakana, field: "cookieHeader", value: newValue)
        }
    }

    var sakanaCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .sakana, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .sakana) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .sakana, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureSakanaCookieLoaded() {}
}

extension SettingsStore {
    func sakanaSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .CookieProviderSettings {
        self.resolvedCookieSettings(
            provider: .sakana,
            configuredSource: self.sakanaCookieSource,
            configuredHeader: self.sakanaCookieHeader,
            tokenOverride: tokenOverride)
    }
}
