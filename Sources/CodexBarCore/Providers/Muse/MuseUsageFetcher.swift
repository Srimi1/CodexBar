import Foundation

public struct MuseUsageFetcher: Sendable {
    public static func fetchUsage(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        sessionRoots: [URL]? = nil,
        configURL: URL? = nil,
        now: Date = Date()) async throws -> UsageSnapshot
    {
        let settings = MuseSettingsReader.readSettingsJSON(configURL: configURL)
        let planName = (settings?["plan"] as? String)
            ?? (settings?["tier"] as? String)
            ?? "Standard"
        let email = (settings?["email"] as? String)
            ?? (settings?["user"] as? String)

        // Calculate limits from local session files if present
        let roots = sessionRoots ?? MuseSettingsReader.defaultSessionRoots(environment: environment)
        let (todayTokens, weeklyTokens) = self.calculateRecentTokenUsage(roots: roots, now: now)

        let (dailyBudget, weeklyBudget) = self.budgets(for: planName)

        let usedDailyPercent = min(100.0, max(0.0, (Double(todayTokens) / Double(dailyBudget)) * 100.0))
        let usedWeeklyPercent = min(100.0, max(0.0, (Double(weeklyTokens) / Double(weeklyBudget)) * 100.0))

        let calendar = Calendar.current
        let nextDay = calendar.nextDate(
            after: now,
            matching: DateComponents(hour: 0, minute: 0, second: 0),
            matchingPolicy: .nextTime)
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now))

        let primaryWindow = RateWindow(
            usedPercent: usedDailyPercent,
            windowMinutes: 1440,
            resetsAt: nextDay,
            resetDescription: "Resets at midnight",
            nextRegenPercent: nil)

        let secondaryWindow = RateWindow(
            usedPercent: usedWeeklyPercent,
            windowMinutes: 10080,
            resetsAt: nextWeek,
            resetDescription: "Weekly quota",
            nextRegenPercent: nil)

        let identity = ProviderIdentitySnapshot(
            providerID: .muse,
            accountEmail: email,
            accountOrganization: planName,
            loginMethod: "Meta Account")

        return UsageSnapshot(
            primary: primaryWindow,
            secondary: secondaryWindow,
            subscriptionExpiresAt: nil,
            subscriptionRenewsAt: nextWeek,
            updatedAt: now,
            identity: identity,
            dataConfidence: .estimated)
    }

    private static func budgets(for plan: String) -> (daily: Int, weekly: Int) {
        let lower = plan.lowercased()
        if lower.contains("everyday") {
            return (500_000, 2_500_000)
        } else if lower.contains("high") {
            return (2_500_000, 12_500_000)
        } else if lower.contains("power") {
            return (10_000_000, 50_000_000)
        } else if lower.contains("contributor") {
            return (2_100_000, 14_700_000)
        }
        // Default Standard
        return (4_000_000, 28_000_000)
    }

    private static func calculateRecentTokenUsage(roots: [URL], now: Date) -> (today: Int, weekly: Int) {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now

        var todaySum = 0
        var weeklySum = 0

        for root in roots where FileManager.default.fileExists(atPath: root.path) {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
            else { continue }

            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                guard ext == "json" || ext == "jsonl" else { continue }
                guard let attrs = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modDate = attrs.contentModificationDate,
                      modDate >= sevenDaysAgo
                else { continue }

                let tokensInFile = self.tokensFromFile(fileURL: fileURL, since: sevenDaysAgo, todayStart: startOfToday)
                todaySum += tokensInFile.today
                weeklySum += tokensInFile.weekly
            }
        }

        return (todaySum, weeklySum)
    }

    private static func tokensFromFile(fileURL: URL, since: Date, todayStart: Date) -> (today: Int, weekly: Int) {
        guard let data = try? Data(contentsOf: fileURL) else { return (0, 0) }

        var today = 0
        var weekly = 0

        func processObject(_ json: [String: Any]) {
            let date: Date = {
                if let ts = json["timestamp"] as? String, let d = ISO8601DateFormatter().date(from: ts) {
                    return d
                }
                if let ts = json["created_at"] as? String, let d = ISO8601DateFormatter().date(from: ts) {
                    return d
                }
                if let recordedAt = (json["recorded_at"] as? Double)
                    ?? (json["recorded_at"] as? Int64).map({ Double($0) })
                    ?? (json["recorded_at"] as? Int).map({ Double($0) })
                {
                    let seconds = recordedAt > 1e14 ? (recordedAt / 1_000_000.0) :
                        (recordedAt > 1e11 ? (recordedAt / 1000.0) : recordedAt)
                    return Date(timeIntervalSince1970: seconds)
                }
                return Date()
            }()

            guard date >= since else { return }

            let totalTokens: Int = {
                if let t = json["total_tokens"] as? Int { return t }
                var usageDict = json["usage"] as? [String: Any]
                if usageDict == nil, let payload = json["payload"] as? [String: Any] {
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
                if let u = usageDict {
                    let inp = (u["input_tokens"] as? Int) ?? (u["prompt_tokens"] as? Int) ?? 0
                    let out = (u["output_tokens"] as? Int) ?? (u["completion_tokens"] as? Int) ?? 0
                    return inp + out
                }
                let inp = (json["input_tokens"] as? Int) ?? 0
                let out = (json["output_tokens"] as? Int) ?? 0
                return inp + out
            }()

            weekly += totalTokens
            if date >= todayStart {
                today += totalTokens
            }
        }

        // Try parsing full JSON first (dict or array)
        if let jsonObject = try? JSONSerialization.jsonObject(with: data) {
            if let dict = jsonObject as? [String: Any] {
                if let messages = dict["messages"] as? [[String: Any]] {
                    for msg in messages {
                        processObject(msg)
                    }
                } else if let events = dict["events"] as? [[String: Any]] {
                    for event in events {
                        processObject(event)
                    }
                } else {
                    processObject(dict)
                }
                return (today, weekly)
            } else if let array = jsonObject as? [[String: Any]] {
                for item in array {
                    processObject(item)
                }
                return (today, weekly)
            }
        }

        // Otherwise try line-by-line JSONL
        if let content = String(data: data, encoding: .utf8) {
            for line in content.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let lineData = trimmed.data(using: .utf8),
                      let json = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
                else { continue }
                processObject(json)
            }
        }

        return (today, weekly)
    }
}
