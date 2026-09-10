import Foundation
import Testing
@testable import CodexBarCore

struct MuseCostUsageScannerTests {
    @Test
    func `scans JSON session file correctly`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-muse-tests-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionJSON = """
        {
            "id": "session-1",
            "model": "muse-spark-1.3",
            "messages": [
                {
                    "timestamp": "2026-09-08T12:00:00Z",
                    "model": "muse-spark-1.3",
                    "usage": {
                        "input_tokens": 1000,
                        "output_tokens": 200,
                        "cached_tokens": 100
                    }
                },
                {
                    "timestamp": "2026-09-08T12:05:00Z",
                    "model": "muse-spark-1.3",
                    "usage": {
                        "input_tokens": 2000,
                        "output_tokens": 400,
                        "cache_read_input_tokens": 200
                    }
                }
            ]
        }
        """
        let fileURL = sessionsDir.appendingPathComponent("session-1.json")
        try sessionJSON.write(to: fileURL, atomically: true, encoding: .utf8)

        var options = CostUsageScanner.Options(
            museSessionsRoots: [sessionsDir],
            cacheRoot: cacheDir)
        options.refreshMinIntervalSeconds = 0

        let report = try CostUsageScanner.loadMuseDaily(options: options)

        #expect(report.data.count == 1)

        let entry = report.data[0]
        #expect(entry.inputTokens == 3000)
        #expect(entry.outputTokens == 600)
        #expect(entry.cacheReadTokens == 300)
        #expect(entry.totalTokens == 3600)
        #expect(entry.modelsUsed?.contains("muse-spark-1.3") == true)
        #expect((entry.costUSD ?? 0) > 0)
    }

    @Test
    func `scans JSONL session file correctly`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-muse-tests-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let line1 = """
        {"timestamp":"2026-09-09T10:00:00Z","model":"muse-code",\
        "usage":{"input_tokens":500,"output_tokens":100,"cached_tokens":50}}
        """
        let line2 = """
        {"timestamp":"2026-09-09T10:30:00Z","model":"muse-code",\
        "usage":{"prompt_tokens":1500,"completion_tokens":300,"cache_read_tokens":100}}
        """
        let fileURL = sessionsDir.appendingPathComponent("session-2.jsonl")
        try "\(line1)\n\(line2)\n".write(to: fileURL, atomically: true, encoding: .utf8)

        var options = CostUsageScanner.Options(
            museSessionsRoots: [sessionsDir],
            cacheRoot: cacheDir)
        options.refreshMinIntervalSeconds = 0

        let report = try CostUsageScanner.loadMuseDaily(options: options)

        #expect(report.data.count == 1)

        let entry = report.data[0]
        #expect(entry.inputTokens == 2000)
        #expect(entry.outputTokens == 400)
        #expect(entry.cacheReadTokens == 150)
        #expect(entry.totalTokens == 2400)
        #expect(entry.modelsUsed?.contains("muse-code") == true)
    }

    @Test
    func `multi-day sessions aggregate and compute costs correctly`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-muse-tests-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let day1Session = """
        {
            "timestamp": "2026-09-01T15:00:00Z",
            "model": "muse-spark-1.3",
            "input_tokens": 10000,
            "output_tokens": 2000
        }
        """
        let day2Session = """
        {
            "timestamp": "2026-09-02T15:00:00Z",
            "model": "muse-code",
            "input_tokens": 20000,
            "output_tokens": 4000
        }
        """

        try day1Session.write(to: sessionsDir.appendingPathComponent("day1.json"), atomically: true, encoding: .utf8)
        try day2Session.write(to: sessionsDir.appendingPathComponent("day2.json"), atomically: true, encoding: .utf8)

        var options = CostUsageScanner.Options(
            museSessionsRoots: [sessionsDir],
            cacheRoot: cacheDir)
        options.refreshMinIntervalSeconds = 0

        let report = try CostUsageScanner.loadMuseDaily(options: options)

        #expect(report.data.count == 2)
        let dates = report.data.map(\.date).sorted()
        #expect(dates == ["2026-09-01", "2026-09-02"])
    }

    @Test
    func `handles corrupt or empty files gracefully`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-muse-tests-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "".write(to: sessionsDir.appendingPathComponent("empty.json"), atomically: true, encoding: .utf8)
        try "{ corrupted json".write(
            to: sessionsDir.appendingPathComponent("corrupt.json"),
            atomically: true,
            encoding: .utf8)
        try "not json at all\nline 2".write(
            to: sessionsDir.appendingPathComponent("corrupt.jsonl"),
            atomically: true,
            encoding: .utf8)

        var options = CostUsageScanner.Options(
            museSessionsRoots: [sessionsDir],
            cacheRoot: cacheDir)
        options.refreshMinIntervalSeconds = 0

        let report = try CostUsageScanner.loadMuseDaily(options: options)

        #expect(report.data.isEmpty)
    }
}
