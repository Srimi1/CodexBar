import Foundation

public enum MuseStatusProbe {
    public struct ProbeResult: Sendable {
        public let isInstalled: Bool
        public let version: String?
        public let hasConfig: Bool
        public let hasSessions: Bool
        public let apiKeyPresent: Bool
    }

    public static func probe(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> ProbeResult
    {
        let apiKey = MuseSettingsReader.apiKey(environment: environment)
        let config = MuseSettingsReader.readSettingsJSON()
        let sessionRoots = MuseSettingsReader.defaultSessionRoots(environment: environment)
        let hasSessions = sessionRoots.contains { root in
            (try? FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty) == false
        }
        let version = self.detectCLIVersion(environment: environment)

        return ProbeResult(
            isInstalled: version != nil,
            version: version,
            hasConfig: config != nil,
            hasSessions: hasSessions,
            apiKeyPresent: apiKey != nil)
    }

    public static func detectCLIVersion(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        let fileManager = FileManager.default
        let standardPaths = [
            "/usr/local/bin/muse",
            "/opt/homebrew/bin/muse",
            "\(fileManager.homeDirectoryForCurrentUser.path)/.local/bin/muse",
            "\(fileManager.homeDirectoryForCurrentUser.path)/.cargo/bin/muse",
        ]

        for path in standardPaths where fileManager.isExecutableFile(atPath: path) {
            if let output = self.runCommand(path: path, arguments: ["--version"]) {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }

        if let pathVar = environment["PATH"] {
            for dir in pathVar.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("muse").path
                if fileManager.isExecutableFile(atPath: candidate) {
                    if let output = self.runCommand(path: candidate, arguments: ["--version"]) {
                        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { return trimmed }
                    }
                }
            }
        }

        return nil
    }

    private static func runCommand(path: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
