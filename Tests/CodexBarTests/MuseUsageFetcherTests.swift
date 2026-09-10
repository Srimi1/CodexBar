import Foundation
import Testing
@testable import CodexBarCore

struct MuseUsageFetcherTests {
    @Test
    func `settings reader reads API key from environment`() {
        let env = ["META_API_KEY": "meta-key-123"]
        let settings = MuseSettingsReader.readSettings(environment: env)
        #expect(settings.apiKey == "meta-key-123")
        #expect(!settings.isContributor)
    }

    @Test
    func `settings reader reads fallback API key from MUSE_API_KEY`() {
        let env = ["MUSE_API_KEY": "muse-key-456"]
        let settings = MuseSettingsReader.readSettings(environment: env)
        #expect(settings.apiKey == "muse-key-456")
        #expect(!settings.isContributor)
    }

    @Test
    func `settings reader parses JSON config file`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-muse-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configFile = root.appendingPathComponent("settings.json")
        let json = """
        {
            "api_key": "config-key-789",
            "tier": "contributor",
            "model": "muse-spark-1.3"
        }
        """
        try json.write(to: configFile, atomically: true, encoding: .utf8)

        let settings = MuseSettingsReader.readSettings(environment: [:], configURL: configFile)
        #expect(settings.apiKey == "config-key-789")
        #expect(settings.isContributor)
        #expect(settings.defaultModel == "muse-spark-1.3")
    }

    @Test
    func `status probe detects config and sessions`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-muse-probe-\(UUID().uuidString)", isDirectory: true)
        let configDir = root.appendingPathComponent("config", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configFile = configDir.appendingPathComponent("settings.json")
        try "{\"tier\":\"Everyday\"}".write(to: configFile, atomically: true, encoding: .utf8)
        try "{}".write(to: sessionsDir.appendingPathComponent("session.json"), atomically: true, encoding: .utf8)

        let probe = MuseStatusProbe.probe(
            environment: [
                "MUSE_CONFIG_FILE": configFile.path,
                "MUSE_SESSIONS_DIR": sessionsDir.path,
            ])

        #expect(probe.hasConfig)
        #expect(probe.hasSessions)
    }

    @Test
    func `usage fetcher constructs valid rate windows and identity`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-muse-fetcher-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Write a session file for today with 40,000 tokens
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: now)

        let sessionJSON = """
        {
            "id": "session-today",
            "messages": [
                {
                    "timestamp": "\(timestamp)",
                    "model": "muse-spark-1.3",
                    "usage": {
                        "input_tokens": 30000,
                        "output_tokens": 10000
                    }
                }
            ]
        }
        """
        try sessionJSON.write(
            to: sessionsDir.appendingPathComponent("session.json"),
            atomically: true,
            encoding: .utf8)

        let snapshot = try await MuseUsageFetcher.fetchUsage(
            environment: ["META_API_KEY": "test-key"],
            sessionRoots: [sessionsDir],
            now: now)

        #expect(snapshot.identity?.providerID == .muse)
        #expect(snapshot.identity?.loginMethod == "Meta Account")
        #expect(snapshot.primary != nil)
        #expect(snapshot.secondary != nil)

        // Primary window should have reset at midnight and used percentage > 0
        if let primary = snapshot.primary {
            #expect(primary.windowMinutes == 24 * 60)
            #expect(primary.usedPercent > 0)
        }

        // Secondary window should be weekly quota and used percentage > 0
        if let secondary = snapshot.secondary {
            #expect(secondary.windowMinutes == 7 * 24 * 60)
            #expect(secondary.usedPercent > 0)
        }
    }
}
