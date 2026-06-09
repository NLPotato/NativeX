//
//  Metrics.swift
//  Prompt Playground
//
//  The LLMOps scoring layer: objective metric structs, deterministic evaluators (driven by
//  NaturalLanguage), the per-run composite score, and the aggregate "golden-readiness"
//  thresholds that decide when a prompt/schema variant is good enough to ship to wiekant.
//
//  Subjective signals (manual rating + LLM judge) are layered on in Phase 2; the composite
//  here is objective-only and is the baseline ranking.
//

import Foundation

// MARK: - Metric bundles
// Built-in test tasks own their typed metric bundles (Gloss.Metrics / Roleplay.Metrics, in Tasks/);
// RunMetrics carries them as optional fields so the generic scoring/aggregation can stay task-agnostic.

/// Everything measured for one Run (one Example through one Variant). For multi-turn tasks a Run is
/// multi-turn and the typed bundle aggregates across turns.
struct RunMetrics: Codable, Equatable, Sendable {
    var decoded: Bool
    var errorType: String?               // nil | "contextWindow" | "guardrail" | "unsupportedLanguage" | "decoding" | "refusal" | …
    var latencyMs: Int
    var promptTokensEst: Int
    var outputTokensEst: Int
    var contextTokensEst: Int            // cumulative context (peak, for role-play)
    var contextHeadroom: Int             // contextWindow - contextTokensEst
    var onTargetLanguage: Double?        // gloss: translations in native; role-play: lines in learning
    var gloss: Gloss.Metrics?
    var roleplay: Roleplay.Metrics?
    // Streaming/perf (generic lane streams internally to capture these). All optional → old runs decode.
    var ttftMs: Int? = nil               // time to first streamed token
    var tokensPerSec: Double? = nil      // estimated output tokens / generation seconds
    // Reference-based eval — set by ExperimentRunner when the example carries an expected output.
    var referenceMatch: Double? = nil    // 0–1: structural/exact = 1.0 else token-Jaccard similarity

    static func failure(_ errorType: String, latencyMs: Int) -> RunMetrics {
        RunMetrics(decoded: false, errorType: errorType, latencyMs: latencyMs,
                   promptTokensEst: 0, outputTokensEst: 0, contextTokensEst: 0,
                   contextHeadroom: TokenEstimator.contextWindow, onTargetLanguage: nil,
                   gloss: nil, roleplay: nil)
    }
}

// MARK: - Shared evaluator helpers
// Pure helpers the built-in task evaluators (Gloss.evaluate / Roleplay.evaluate, in Tasks/) reuse.

enum Evaluators {
    nonisolated static let knownPOS: Set<String> = [
        "noun", "proper noun", "propernoun", "verb", "adjective", "adverb", "pronoun",
        "preposition", "postposition", "adposition", "conjunction", "determiner", "article",
        "particle", "numeral", "number", "interjection", "auxiliary", "punctuation"
    ]

    nonisolated static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
    }

    nonisolated static func distinctTexts(_ texts: [String]) -> Bool {
        let cleaned = texts.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        return Set(cleaned).count == cleaned.count
    }
}

// MARK: - Generic evaluator (dynamic / custom-schema runs)
// A custom SchemaDef produces untyped GeneratedContent, so the typed Evaluators can't run. This
// schema-agnostic fallback measures only what's universal: did it decode, latency/tokens, and the
// on-target language across every string leaf of the produced JSON. gloss/roleplay stay nil, which
// VariantStats/GoldenThresholds already skip.

enum RunEvaluator {
    static func metrics(json: String, decoded: Bool, latencyMs: Int, resolvedPrompt: String,
                        expectedLanguage: String, context: Int,
                        ttftMs: Int? = nil, tokensPerSec: Double? = nil) -> RunMetrics {
        let strings = decoded ? stringLeaves(json) : []
        let lang = LanguageTools.matchScore(strings, expected: expectedLanguage)
        return RunMetrics(
            decoded: decoded, errorType: decoded ? nil : "decode", latencyMs: latencyMs,
            promptTokensEst: TokenEstimator.estimate(resolvedPrompt),
            outputTokensEst: TokenEstimator.estimate(json),
            contextTokensEst: context, contextHeadroom: TokenEstimator.headroom(context),
            onTargetLanguage: lang, gloss: nil, roleplay: nil,
            ttftMs: ttftMs, tokensPerSec: tokensPerSec)
    }

    /// Every String value nested anywhere in a JSON document.
    static func stringLeaves(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [] }
        var out: [String] = []
        func walk(_ any: Any) {
            switch any {
            case let s as String:          out.append(s)
            case let arr as [Any]:         arr.forEach(walk)
            case let dict as [String: Any]: dict.values.forEach(walk)
            default:                       break
            }
        }
        walk(obj)
        return out
    }
}

// MARK: - Reference-based evaluator (optional ground truth)
// When a dataset Example carries an expected output, score the run against it. Deterministic and
// cheap: a structural-JSON or normalized-text exact match is 1.0; otherwise token-set (Jaccard)
// overlap so near-misses score partially. (Semantic scoring stays the separate, optional LLM Judge.)

enum ReferenceEvaluator {
    static func match(output: String, expected: String) -> Double {
        let e = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty else { return 0 }
        if let a = canonicalJSON(output), let b = canonicalJSON(e), a == b { return 1.0 }
        let on = normalize(output), en = normalize(e)
        if on == en { return 1.0 }
        return jaccard(tokens(on), tokens(en))
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func tokens(_ s: String) -> Set<String> {
        Set(s.split { !$0.isLetter && !$0.isNumber }.map(String.init)).subtracting([""])
    }
    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1.0 }
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }
    /// Canonical (sorted-key) compact JSON, or nil when not a JSON object/array.
    private static func canonicalJSON(_ s: String) -> String? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: out, encoding: .utf8) else { return nil }
        return str
    }
}

// MARK: - Composite scoring

enum Scoring {
    /// 0–100 per-run objective composite. Hard gate: a run that didn't decode scores 0 — a
    /// schema the model can't satisfy is useless regardless of anything else.
    static func composite(_ m: RunMetrics) -> Double {
        guard m.decoded else { return 0 }
        let lang = m.onTargetLanguage ?? 0.6   // neutral prior when text was too short to detect

        if let g = m.gloss {
            let s = 0.25 * lang
                  + 0.20 * g.coverageRatio
                  + 0.25 * (1 - g.hallucinationRate)
                  + 0.15 * g.fieldCompleteness
                  + 0.10 * g.posPlausibility
                  + 0.05 * (1 - g.dedupRate)
            return 100 * s
        }
        if let r = m.roleplay {
            let headroomScore = max(0, min(1, Double(m.contextHeadroom) / Double(TokenEstimator.contextWindow)))
            let s = 0.30 * lang
                  + 0.20 * r.suggestionCountOK
                  + 0.15 * r.distinctSuggestions
                  + 0.15 * r.translationPresent
                  + 0.10 * (r.hitContextLimit ? 0 : 1)
                  + 0.10 * headroomScore
            return 100 * s
        }
        // Dynamic / custom-schema run (no typed bundle): reward decode conformance + on-target language.
        return 100 * (0.5 + 0.5 * lang)
    }
}

// MARK: - Variant aggregate + golden-readiness thresholds

/// Dataset-level rollup for one Variant — what the leaderboard ranks and what the
/// golden-readiness check is evaluated against.
struct VariantStats: Codable, Equatable, Sendable {
    var n: Int
    var decodeRate: Double
    var meanComposite: Double
    var meanOnTargetLanguage: Double?
    var p95LatencyMs: Int
    var p95ContextTokens: Int
    var meanCoverage: Double?
    var meanHallucination: Double?
    var meanSuggestionCountOK: Double?
    var meanDistinct: Double?
    var contextLimitRate: Double?
    var meanReferenceMatch: Double?      // mean 0–1 vs expected outputs (only runs that had a reference)
    var meanManualRating: Double?        // Phase 2 (1–5)
    var meanJudge: Double?               // Phase 2 (1–5)

    static func aggregate(_ runs: [RunMetrics],
                          manualRatings: [Int] = [],
                          judgeScores: [Double] = []) -> VariantStats {
        let n = runs.count
        guard n > 0 else {
            return VariantStats(n: 0, decodeRate: 0, meanComposite: 0, meanOnTargetLanguage: nil,
                                p95LatencyMs: 0, p95ContextTokens: 0, meanCoverage: nil,
                                meanHallucination: nil, meanSuggestionCountOK: nil, meanDistinct: nil,
                                contextLimitRate: nil, meanReferenceMatch: nil,
                                meanManualRating: nil, meanJudge: nil)
        }
        func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
        let decoded = runs.filter(\.decoded)

        let gloss = decoded.compactMap(\.gloss)
        let roleplay = decoded.compactMap(\.roleplay)

        return VariantStats(
            n: n,
            decodeRate: Double(decoded.count) / Double(n),
            meanComposite: runs.map(Scoring.composite).reduce(0, +) / Double(n),
            meanOnTargetLanguage: mean(decoded.compactMap(\.onTargetLanguage)),
            p95LatencyMs: percentile(runs.map(\.latencyMs), 0.95),
            p95ContextTokens: percentile(runs.map(\.contextTokensEst), 0.95),
            meanCoverage: mean(gloss.map(\.coverageRatio)),
            meanHallucination: mean(gloss.map(\.hallucinationRate)),
            meanSuggestionCountOK: mean(roleplay.map(\.suggestionCountOK)),
            meanDistinct: mean(roleplay.map(\.distinctSuggestions)),
            contextLimitRate: roleplay.isEmpty ? nil : Double(roleplay.filter(\.hitContextLimit).count) / Double(roleplay.count),
            meanReferenceMatch: mean(decoded.compactMap(\.referenceMatch)),
            meanManualRating: mean(manualRatings.map(Double.init)),
            meanJudge: mean(judgeScores)
        )
    }

    private static func percentile(_ xs: [Int], _ p: Double) -> Int {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        let idx = min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))
        return sorted[idx]
    }
}

/// One golden-readiness criterion outcome.
struct ReadinessCheck: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let pass: Bool
    let detail: String
}

/// Initial "call-it-a-day" thresholds (calibrate after the first real batch on M3). A Variant is
/// a golden candidate when every check passes. Subjective checks are skipped until rated/judged.
enum GoldenThresholds {
    static func evaluate(_ s: VariantStats, task: TaskKind) -> [ReadinessCheck] {
        func check(_ name: String, _ pass: Bool, _ detail: String) -> ReadinessCheck {
            ReadinessCheck(name: name, pass: pass, detail: detail)
        }
        var checks: [ReadinessCheck] = [
            check("Decode 100%", s.decodeRate >= 0.999, String(format: "%.0f%%", s.decodeRate * 100)),
            check("Context p95 ≤ 3000", s.p95ContextTokens <= 3000, "\(s.p95ContextTokens) tok"),
        ]
        if let lang = s.meanOnTargetLanguage {
            checks.append(check("On-target language ≥ 0.98", lang >= 0.98, String(format: "%.2f", lang)))
        }
        if let ref = s.meanReferenceMatch {
            checks.append(check("Reference match ≥ 0.90", ref >= 0.90, String(format: "%.2f", ref)))
        }
        switch task {
        case .gloss:
            if let c = s.meanCoverage { checks.append(check("Coverage ≥ 0.80", c >= 0.80, String(format: "%.2f", c))) }
            if let h = s.meanHallucination { checks.append(check("Hallucination ≤ 0.02", h <= 0.02, String(format: "%.2f", h))) }
        case .roleplay:
            if let two = s.meanSuggestionCountOK { checks.append(check("2 suggestions ≥ 0.95", two >= 0.95, String(format: "%.2f", two))) }
            if let d = s.meanDistinct { checks.append(check("Distinct ≥ 0.95", d >= 0.95, String(format: "%.2f", d))) }
            if let cl = s.contextLimitRate { checks.append(check("No context overflow", cl <= 0.0001, String(format: "%.2f", cl))) }
        case .custom:
            break   // no typed bundle — the universal decode/context/language checks above apply
        }
        if let r = s.meanManualRating { checks.append(check("Manual ≥ 4.0", r >= 4.0, String(format: "%.1f", r))) }
        if let j = s.meanJudge { checks.append(check("Judge ≥ 3.8", j >= 3.8, String(format: "%.1f", j))) }
        return checks
    }

    static func isGolden(_ s: VariantStats, task: TaskKind) -> Bool {
        evaluate(s, task: task).allSatisfy(\.pass)
    }
}
