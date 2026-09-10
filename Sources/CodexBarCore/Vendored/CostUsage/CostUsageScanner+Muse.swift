import Foundation

extension CostUsageScanner {
    // MARK: - Muse

    struct MuseUsageRow: Codable, Equatable, Sendable {
        let dayKey: String
        let model: String
        let sessionId: String?
        let input: Int
        let output: Int
        let cacheRead: Int
        let costUSD: Double
    }

    struct MuseParseResult {
        let rows: [MuseUsageRow]
        let parsedBytes: Int64
    }

    private final class MuseScanState {
        var cache: CostUsageCache
        var touched: Set<String>
        let range: CostUsageDayRange
        let forceFullScan: Bool
        let checkCancellation: CancellationCheck?

        init(
            cache: CostUsageCache,
            range: CostUsageDayRange,
            forceFullScan: Bool,
            checkCancellation: CancellationCheck?)
        {
            self.cache = cache
            self.touched = []
            self.range = range
            self.forceFullScan = forceFullScan
            self.checkCancellation = checkCancellation
        }
    }

    static func loadMuseDaily(
        days: Int = 30,
        now: Date = Date(),
        options: Options = Options(),
        checkCancellation: CancellationCheck? = nil) throws -> CostUsageDailyReport
    {
        let until = now
        let since = Calendar.current.date(byAdding: .day, value: -days, to: until) ?? until
        let range = CostUsageDayRange(since: since, until: until)
        return try self.loadMuseDaily(
            range: range,
            now: now,
            options: options,
            checkCancellation: checkCancellation)
    }

    static func loadMuseDaily(
        range: CostUsageDayRange,
        now: Date = Date(),
        options: Options = Options(),
        checkCancellation: CancellationCheck? = nil) throws -> CostUsageDailyReport
    {
        try checkCancellation?()
        var cache = CostUsageCacheIO.load(provider: .muse, cacheRoot: options.cacheRoot)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let refreshMs = Int64(max(0, options.refreshMinIntervalSeconds) * 1000)
        let windowExpanded = self.requestedWindowExpandsCache(range: range, cache: cache)
        let shouldRefresh = options.forceRescan || windowExpanded || (nowMs - cache.lastScanUnixMs) >= refreshMs

        let roots = options.museSessionsRoots ?? MuseSettingsReader.defaultSessionRoots()

        if shouldRefresh {
            try checkCancellation?()
            if options.forceRescan {
                cache = CostUsageCache()
            }
            let scanState = MuseScanState(
                cache: cache,
                range: range,
                forceFullScan: options.forceRescan || windowExpanded,
                checkCancellation: checkCancellation)

            for root in roots {
                try self.scanMuseRoot(root: root, state: scanState)
            }
            try checkCancellation?()

            cache = scanState.cache
            let touched = scanState.touched
            cache.roots = nil

            for key in cache.files.keys where !touched.contains(key) {
                cache.files.removeValue(forKey: key)
            }

            cache.scanSinceKey = range.scanSinceKey
            cache.scanUntilKey = range.scanUntilKey
            cache.lastScanUnixMs = nowMs
            try checkCancellation?()
            CostUsageCacheIO.save(provider: .muse, cache: cache, cacheRoot: options.cacheRoot)
        }

        return self.buildMuseReport(from: cache, range: range)
    }

    private static func scanMuseRoot(root: URL, state: MuseScanState) throws {
        try state.checkCancellation?()
        guard FileManager.default.fileExists(atPath: root.path) else { return }

        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])
        else { return }

        for case let fileURL as URL in enumerator {
            try state.checkCancellation?()
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "json" || ext == "jsonl" else { continue }

            guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys)),
                  let size = resourceValues.fileSize,
                  let mtime = resourceValues.contentModificationDate
            else { continue }

            let mtimeMs = Int64(mtime.timeIntervalSince1970 * 1000)
            let path = fileURL.path
            state.touched.insert(path)

            if let cached = state.cache.files[path],
               cached.mtimeUnixMs == mtimeMs,
               cached.size == Int64(size),
               !state.forceFullScan
            {
                continue
            }

            let parsed = try self.parseMuseFileCancellable(
                fileURL: fileURL,
                range: state.range,
                checkCancellation: state.checkCancellation)

            let rows = parsed.rows
            let daysMap: [String: [String: [Int]]] = self.packMuseRows(rows)

            state.cache.files[path] = CostUsageFileUsage(
                mtimeUnixMs: mtimeMs,
                size: Int64(size),
                days: daysMap,
                parsedBytes: parsed.parsedBytes)
        }
    }

    private static func packMuseRows(_ rows: [MuseUsageRow]) -> [String: [String: [Int]]] {
        var days: [String: [String: [Int]]] = [:]
        for row in rows {
            var models = days[row.dayKey] ?? [:]
            var current = models[row.model] ?? [0, 0, 0, 0]
            current[0] += row.input
            current[1] += row.output
            current[2] += row.cacheRead
            current[3] += Int((row.costUSD * 1_000_000_000).rounded())
            models[row.model] = current
            days[row.dayKey] = models
        }
        return days
    }

    static func parseMuseFileCancellable(
        fileURL: URL,
        range: CostUsageDayRange,
        checkCancellation: CancellationCheck? = nil) throws -> MuseParseResult
    {
        try checkCancellation?()
        let ext = fileURL.pathExtension.lowercased()

        if ext == "jsonl" {
            return try self.parseMuseJSONL(fileURL: fileURL, range: range, checkCancellation: checkCancellation)
        } else {
            return try self.parseMuseJSON(fileURL: fileURL, range: range, checkCancellation: checkCancellation)
        }
    }

    private static func parseMuseJSONL(
        fileURL: URL,
        range: CostUsageDayRange,
        checkCancellation: CancellationCheck?) throws -> MuseParseResult
    {
        var rows: [MuseUsageRow] = []
        let maxLineBytes = 512 * 1024

        let parsedBytes = try CostUsageJsonl.scan(
            fileURL: fileURL,
            offset: 0,
            maxLineBytes: maxLineBytes,
            prefixBytes: maxLineBytes,
            checkCancellation: checkCancellation,
            onLine: { line in
                guard !line.bytes.isEmpty, !line.wasTruncated else { return }
                guard let obj = (try? JSONSerialization.jsonObject(with: line.bytes)) as? [String: Any] else { return }
                if let row = self.parseMuseObject(
                    obj: obj,
                    range: range,
                    fallbackSessionId: fileURL.deletingPathExtension().lastPathComponent)
                {
                    rows.append(row)
                }
            })

        return MuseParseResult(rows: rows, parsedBytes: parsedBytes)
    }

    private static func parseMuseJSON(
        fileURL: URL,
        range: CostUsageDayRange,
        checkCancellation: CancellationCheck?) throws -> MuseParseResult
    {
        try checkCancellation?()
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data)
        else {
            return MuseParseResult(rows: [], parsedBytes: 0)
        }

        var rows: [MuseUsageRow] = []
        let fallbackId = fileURL.deletingPathExtension().lastPathComponent

        if let array = json as? [[String: Any]] {
            for obj in array {
                if let row = self.parseMuseObject(obj: obj, range: range, fallbackSessionId: fallbackId) {
                    rows.append(row)
                }
            }
        } else if let dict = json as? [String: Any] {
            if let messages = dict["messages"] as? [[String: Any]] {
                for obj in messages {
                    if let row = self.parseMuseObject(obj: obj, range: range, fallbackSessionId: fallbackId) {
                        rows.append(row)
                    }
                }
            } else if let events = dict["events"] as? [[String: Any]] {
                for obj in events {
                    if let row = self.parseMuseObject(obj: obj, range: range, fallbackSessionId: fallbackId) {
                        rows.append(row)
                    }
                }
            } else if let row = self.parseMuseObject(obj: dict, range: range, fallbackSessionId: fallbackId) {
                rows.append(row)
            }
        }

        return MuseParseResult(rows: rows, parsedBytes: Int64(data.count))
    }

    private static func parseMuseObject(
        obj: [String: Any],
        range: CostUsageDayRange,
        fallbackSessionId: String) -> MuseUsageRow?
    {
        var dayKey: String?
        if let tsText = (obj["timestamp"] as? String)
            ?? (obj["created_at"] as? String)
            ?? (obj["time"] as? String)
            ?? (obj["date"] as? String)
        {
            dayKey = self.dayKeyFromTimestamp(tsText) ?? self.dayKeyFromParsedISO(tsText)
        } else if let recordedAt = (obj["recorded_at"] as? Double)
            ?? (obj["recorded_at"] as? Int64).map({ Double($0) })
            ?? (obj["recorded_at"] as? Int).map({ Double($0) })
        {
            let seconds = recordedAt > 1e14 ? (recordedAt / 1_000_000.0) :
                (recordedAt > 1e11 ? (recordedAt / 1000.0) : recordedAt)
            dayKey = CostUsageDayRange.dayKey(from: Date(timeIntervalSince1970: seconds))
        }

        guard let dayKey,
              CostUsageDayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey)
        else {
            return nil
        }

        var usageDict: [String: Any]? = (obj["usage"] as? [String: Any])
            ?? ((obj["message"] as? [String: Any])?["usage"] as? [String: Any])
        var modelCandidate: String? = (obj["model"] as? String)
            ?? ((obj["message"] as? [String: Any])?["model"] as? String)

        if let payload = obj["payload"] as? [String: Any] {
            if modelCandidate == nil {
                modelCandidate = (payload["model_id"] as? String) ?? (payload["model"] as? String)
            }
            if usageDict == nil {
                if let event = payload["event"] as? [String: Any],
                   let record = event["record"] as? [String: Any],
                   let quantity = record["quantity"] as? [String: Any]
                {
                    usageDict = quantity
                } else if let record = payload["record"] as? [String: Any],
                          let quantity = record["quantity"] as? [String: Any]
                {
                    usageDict = quantity
                } else if let quantity = payload["quantity"] as? [String: Any] {
                    usageDict = quantity
                }
            }
        }

        let modelRaw = modelCandidate ?? "muse-spark-1.3"
        let model = CostUsagePricing.normalizeMuseModel(modelRaw)
        let usage = usageDict ?? obj

        let input = (usage["input_tokens"] as? Int)
            ?? (usage["prompt_tokens"] as? Int)
            ?? 0
        let output = (usage["output_tokens"] as? Int)
            ?? (usage["completion_tokens"] as? Int)
            ?? 0
        let cacheRead = (usage["cache_read_input_tokens"] as? Int)
            ?? (usage["cache_read_tokens"] as? Int)
            ?? (usage["cached_tokens"] as? Int)
            ?? (usage["cached_input_tokens"] as? Int)
            ?? 0

        guard input > 0 || output > 0 || cacheRead > 0 else { return nil }

        let cost = CostUsagePricing.museCostUSD(
            model: model,
            inputTokens: input,
            cacheReadInputTokens: cacheRead,
            outputTokens: output) ?? 0.0

        let sessionId = (obj["session_id"] as? String)
            ?? (obj["sessionId"] as? String)
            ?? fallbackSessionId

        return MuseUsageRow(
            dayKey: dayKey,
            model: model,
            sessionId: sessionId,
            input: input,
            output: output,
            cacheRead: cacheRead,
            costUSD: cost)
    }

    private static func buildMuseReport(from cache: CostUsageCache, range: CostUsageDayRange) -> CostUsageDailyReport {
        var dayMap: [String: [String: (input: Int, output: Int, cacheRead: Int, cost: Double)]] = [:]

        for (_, file) in cache.files {
            for (dayKey, models) in file.days {
                guard CostUsageDayRange.isInRange(dayKey: dayKey, since: range.scanSinceKey, until: range.scanUntilKey)
                else {
                    continue
                }
                var currentModels = dayMap[dayKey] ?? [:]
                for (model, packed) in models {
                    var m = currentModels[model] ?? (0, 0, 0, 0.0)
                    let input = packed[safe: 0] ?? 0
                    let output = packed[safe: 1] ?? 0
                    let cacheRead = packed[safe: 2] ?? 0
                    let costNanos = packed[safe: 3] ?? 0
                    m.input += input
                    m.output += output
                    m.cacheRead += cacheRead
                    m.cost += Double(costNanos) / 1_000_000_000.0
                    currentModels[model] = m
                }
                dayMap[dayKey] = currentModels
            }
        }

        var entries: [CostUsageDailyReport.Entry] = []
        var totalInput = 0
        var totalOutput = 0
        var totalCacheRead = 0
        var totalTokens = 0
        var totalCost: Double = 0

        let sortedDays = dayMap.keys.sorted()
        for dayKey in sortedDays {
            guard let models = dayMap[dayKey] else { continue }
            var dayInput = 0
            var dayOutput = 0
            var dayCacheRead = 0
            var dayCost: Double = 0
            var breakdowns: [CostUsageDailyReport.ModelBreakdown] = []

            for (model, stats) in models.sorted(by: { $0.key < $1.key }) {
                let modelTotal = stats.input + stats.output
                dayInput += stats.input
                dayOutput += stats.output
                dayCacheRead += stats.cacheRead
                dayCost += stats.cost
                breakdowns.append(CostUsageDailyReport.ModelBreakdown(
                    modelName: model,
                    costUSD: stats.cost,
                    totalTokens: modelTotal))
            }

            let dayTotal = dayInput + dayOutput
            totalInput += dayInput
            totalOutput += dayOutput
            totalCacheRead += dayCacheRead
            totalTokens += dayTotal
            totalCost += dayCost

            entries.append(CostUsageDailyReport.Entry(
                date: dayKey,
                inputTokens: dayInput,
                outputTokens: dayOutput,
                cacheReadTokens: dayCacheRead,
                totalTokens: dayTotal,
                costUSD: dayCost,
                modelsUsed: breakdowns.map(\.modelName),
                modelBreakdowns: breakdowns))
        }

        let summary = CostUsageDailyReport.Summary(
            totalInputTokens: totalInput,
            totalOutputTokens: totalOutput,
            cacheReadTokens: totalCacheRead,
            totalTokens: totalTokens,
            totalCostUSD: totalCost)

        return CostUsageDailyReport(data: entries, summary: summary)
    }
}
