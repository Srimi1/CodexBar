import Foundation

// Muse Code pricing lives beside its provider so the vendored pricing catalog stays provider-neutral.
// Rates follow Meta's published Muse Spark API pricing: standard and Contributor tiers.
extension CostUsagePricing {
    struct MusePricing {
        let inputCostPerToken: Double
        let outputCostPerToken: Double
        let cacheReadInputCostPerToken: Double?
        let displayLabel: String?
    }

    static let museCatalog: [String: MusePricing] = [
        "muse-spark": MusePricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 4.25e-6,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: "Muse Spark"),
        "muse-spark-1.2": MusePricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 4.25e-6,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: "Muse Spark 1.2"),
        "muse-spark-1.3": MusePricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 4.25e-6,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: "Muse Spark 1.3"),
        "muse-code": MusePricing(
            inputCostPerToken: 1.25e-6,
            outputCostPerToken: 4.25e-6,
            cacheReadInputCostPerToken: 1.25e-7,
            displayLabel: "Muse Code"),
        "muse-spark-contributor": MusePricing(
            inputCostPerToken: 1e-7,
            outputCostPerToken: 2e-7,
            cacheReadInputCostPerToken: 1e-8,
            displayLabel: "Muse Spark (Contributor)"),
        "muse-spark-1.2-contributor": MusePricing(
            inputCostPerToken: 1e-7,
            outputCostPerToken: 2e-7,
            cacheReadInputCostPerToken: 1e-8,
            displayLabel: "Muse Spark 1.2 (Contributor)"),
        "muse-spark-1.3-contributor": MusePricing(
            inputCostPerToken: 1e-7,
            outputCostPerToken: 2e-7,
            cacheReadInputCostPerToken: 1e-8,
            displayLabel: "Muse Spark 1.3 (Contributor)"),
    ]

    static func normalizeMuseModel(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("meta/") {
            trimmed = String(trimmed.dropFirst("meta/".count))
        } else if trimmed.hasPrefix("meta.") {
            trimmed = String(trimmed.dropFirst("meta.".count))
        }

        if self.museCatalog[trimmed] != nil {
            return trimmed
        }

        if trimmed == "muse" || trimmed == "spark" {
            return "muse-spark-1.3"
        }
        if trimmed == "spark-1.2" {
            return "muse-spark-1.2"
        }
        if trimmed == "spark-1.3" {
            return "muse-spark-1.3"
        }

        if let datedSuffix = trimmed.range(of: #"-\d{4}-\d{2}(-\d{2})?$"#, options: .regularExpression) {
            let base = String(trimmed[..<datedSuffix.lowerBound])
            if self.museCatalog[base] != nil {
                return base
            }
        }
        if trimmed.hasSuffix("-latest") {
            let base = String(trimmed.dropLast("-latest".count))
            if self.museCatalog[base] != nil {
                return base
            }
        }
        return trimmed
    }

    static func museCostUSD(
        model: String,
        inputTokens: Int,
        cacheReadInputTokens: Int = 0,
        outputTokens: Int,
        isContributor: Bool = false) -> Double?
    {
        let key = self.normalizeMuseModel(model)
        let effectiveKey = isContributor && !key.hasSuffix("-contributor")
            ? "\(key)-contributor"
            : key

        guard let pricing = self.museCatalog[effectiveKey] ?? self.museCatalog[key] ?? self.museCatalog["muse-spark-1.3"] else {
            return nil
        }

        let nonCachedInput = max(0, inputTokens - cacheReadInputTokens)
        let cacheReadRate = pricing.cacheReadInputCostPerToken ?? pricing.inputCostPerToken
        return (Double(nonCachedInput) * pricing.inputCostPerToken)
            + (Double(cacheReadInputTokens) * cacheReadRate)
            + (Double(max(0, outputTokens)) * pricing.outputCostPerToken)
    }
}
