import Foundation

// Normalized token accounting from provider-owned usage payloads. This is
// deliberately separate from the visible-text chars/4 fallback: values in this
// type came from a provider protocol and are safe to present as exact counts.
//
// The normalization strategy was informed by T3 Code's MIT-licensed Codex and
// Claude adapters at pingdotgg/t3code (reviewed at daf8ee0b2f684cda82e8721abe1138b219b1ef12).
// See Support/ThirdPartyNotices.txt for attribution and license terms.
struct ReportedTokenUsage: Equatable {
    // Thread/session total supplied cumulatively by the provider (Codex).
    let cumulativeTokens: Int?
    // Tokens processed by this Eave-launched turn (Claude/Cursor).
    let turnTokens: Int?
    // Latest active request/context size, not lifetime throughput.
    let contextTokens: Int?
    let contextWindow: Int?

    var hasUsage: Bool {
        cumulativeTokens != nil || turnTokens != nil || contextTokens != nil
    }
}

enum ProviderTokenUsageParser {
    typealias JSON = [String: Any]

    // Claude result usage may be a flat aggregate, a total_tokens-only rollup,
    // or include per-model-call iterations. The rollup is throughput for this
    // process/turn; the last detailed iteration is the active context snapshot.
    static func claude(result: JSON) -> ReportedTokenUsage? {
        guard let usage = result["usage"] as? JSON else { return nil }

        let freshTotal = claudeTotal(usage, includingCacheReads: false)
        let iterations = (usage["iterations"] as? [Any])?
            .compactMap { $0 as? JSON } ?? []
        let lastIterationTokens = iterations.reversed()
            .compactMap { claudeTotal($0, includingCacheReads: true) }
            .first(where: { $0 > 0 })
        let iterationsTotal = positiveSum(
            iterations.compactMap { claudeTotal($0, includingCacheReads: false) }
        )
        // Only when the detailed fields are absent: total_tokens folds in cache
        // reads, which are history this chat already paid for once.
        let explicitTotal = freshTotal == nil ? positiveInt(usage["total_tokens"]) : nil

        let turnTokens = positive(freshTotal) ?? iterationsTotal ?? explicitTotal
        // Only per-call detail can stand for context size. The flat rollup adds
        // up every API call in the turn, so on a long tool-using turn it runs to
        // several times the window; claudeMessage supplies the real value.
        let contextTokens = lastIterationTokens
        let contextWindow = claudeContextWindow(result["modelUsage"] ?? result["model_usage"])

        let report = ReportedTokenUsage(
            cumulativeTokens: nil,
            turnTokens: turnTokens,
            contextTokens: contextTokens,
            contextWindow: contextWindow
        )
        return report.hasUsage ? report : nil
    }

    // One assistant message is one API response, so its prompt fields are the
    // live context size: what the model was just handed, cache hits included.
    static func claudeMessage(_ message: JSON) -> ReportedTokenUsage? {
        guard let usage = message["usage"] as? JSON,
              let prompt = positiveSum([
                  nonNegativeInt(usage["input_tokens"]),
                  nonNegativeInt(usage["cache_read_input_tokens"]),
                  nonNegativeInt(usage["cache_creation_input_tokens"]),
              ].compactMap { $0 })
        else { return nil }

        return ReportedTokenUsage(
            cumulativeTokens: nil, turnTokens: nil,
            contextTokens: prompt, contextWindow: nil
        )
    }

    // Cursor added a terminal result usage object after its original
    // stream-json schema shipped. Accept both its camelCase fields and the
    // equivalent snake_case spellings so additive schema evolution is safe.
    static func cursor(result: JSON) -> ReportedTokenUsage? {
        guard let usage = result["usage"] as? JSON else { return nil }
        let cacheReadTokens = firstInt(in: usage, keys: ["cacheReadTokens", "cache_read_tokens"])
        // Cache reads are replayed history, so they belong to the context size,
        // not to the running total of work done.
        let freshComponents = [
            firstInt(in: usage, keys: ["inputTokens", "input_tokens"]),
            firstInt(in: usage, keys: ["outputTokens", "output_tokens"]),
            firstInt(in: usage, keys: ["cacheWriteTokens", "cache_write_tokens"]),
            firstInt(in: usage, keys: ["reasoningTokens", "reasoning_tokens"]),
        ].compactMap { $0 }
        let turnTokens = positiveSum(freshComponents)
            ?? (freshComponents.isEmpty
                ? positiveInt(usage["totalTokens"] ?? usage["total_tokens"])
                : nil)
        let contextTotal = positiveSum(freshComponents + [cacheReadTokens].compactMap { $0 })
        let explicitContext = positiveInt(
            usage["contextTokens"] ?? usage["context_tokens"]
                ?? usage["usedTokens"] ?? usage["used_tokens"]
        )
        let contextWindow = positiveInt(
            usage["contextWindow"] ?? usage["context_window"]
                ?? usage["maxTokens"] ?? usage["max_tokens"]
        )

        let report = ReportedTokenUsage(
            cumulativeTokens: nil,
            turnTokens: turnTokens,
            contextTokens: explicitContext ?? contextTotal ?? turnTokens,
            contextWindow: contextWindow
        )
        return report.hasUsage ? report : nil
    }

    // Codex app-server owns both meanings directly: total is thread-cumulative
    // throughput, while last is the current context/request snapshot.
    static func codex(tokenUsage: JSON) -> ReportedTokenUsage? {
        guard let total = tokenUsage["total"] as? JSON,
              let last = tokenUsage["last"] as? JSON,
              let reportedTotal = positiveInt(total["totalTokens"]),
              let contextTokens = positiveInt(last["totalTokens"])
        else { return nil }

        // Codex's thread total counts cached input every turn it is replayed,
        // so a long thread reports several times its own context window. Net it
        // out to keep the running total meaning "new tokens processed".
        let cachedInput = nonNegativeInt(
            total["cachedInputTokens"] ?? total["cached_input_tokens"]
        ) ?? 0
        let cumulativeTokens = max(reportedTotal - cachedInput, 1)

        return ReportedTokenUsage(
            cumulativeTokens: cumulativeTokens,
            turnTokens: nil,
            contextTokens: contextTokens,
            contextWindow: positiveInt(tokenUsage["modelContextWindow"])
        )
    }

    // includingCacheReads distinguishes the two meanings that share these
    // fields: with reads, it is how big the request was (context); without, it
    // is how much of that was new work (throughput). Adding cache reads into a
    // running total counts the same history once per turn, which is what made
    // long chats report multiples of the context window.
    private static func claudeTotal(_ usage: JSON, includingCacheReads: Bool) -> Int? {
        var components = [
            nonNegativeInt(usage["input_tokens"]),
            nonNegativeInt(usage["output_tokens"]),
            nonNegativeInt(usage["cache_creation_input_tokens"]),
        ]
        if includingCacheReads {
            components.append(nonNegativeInt(usage["cache_read_input_tokens"]))
        }
        return positiveSum(components.compactMap { $0 })
    }

    private static func claudeContextWindow(_ value: Any?) -> Int? {
        guard let modelUsage = value as? JSON else { return nil }
        return modelUsage.values
            .compactMap { $0 as? JSON }
            .compactMap { positiveInt($0["contextWindow"] ?? $0["context_window"]) }
            .max()
    }

    private static func firstInt(in object: JSON, keys: [String]) -> Int? {
        for key in keys {
            if let value = nonNegativeInt(object[key]) { return value }
        }
        return nil
    }

    private static func positiveSum(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        var total = 0
        for value in values {
            let addition = total.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            total = addition.partialValue
        }
        return total > 0 ? total : nil
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func positiveInt(_ value: Any?) -> Int? {
        positive(nonNegativeInt(value))
    }

    // JSONSerialization bridges numbers through NSNumber. Reject booleans and
    // non-integral/overflowing values instead of silently truncating them.
    private static func nonNegativeInt(_ value: Any?) -> Int? {
        if value is Bool { return nil }
        if let value = value as? Int { return value >= 0 ? value : nil }
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value < Double(Int.max), value.rounded() == value
        else { return nil }
        return Int(value)
    }
}
