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

struct GlossMetrics: Codable, Equatable, Sendable {
    var wordCount: Int
    var coverageRatio: Double           // share of source content words present among surfaces
    var hallucinationRate: Double       // share of surfaces NOT found in the source (lower better)
    var fieldCompleteness: Double       // required word fields + sentence translation non-empty
    var dedupRate: Double               // share of duplicate surfaces (lower better)
    var posPlausibility: Double         // share of partOfSpeech values in a known set
    var sentenceTranslationPresent: Bool
}

struct RoleplayMetrics: Codable, Equatable, Sendable {
    var turnCount: Int
    var suggestionCountOK: Double        // share of turns with exactly two suggestions
    var distinctSuggestions: Double      // share of turns whose suggestions are all distinct
    var replyLangOK: Double              // reply detected as the learning language
    var suggestionsLangOK: Double        // suggestions detected as the learning language
    var translationPresent: Double       // share of lines carrying a non-empty native translation
    var avgReplyChars: Double
    var peakContextTokensEst: Int        // worst-case cumulative context across the turns
    var hitContextLimit: Bool            // a turn failed with exceededContextWindowSize
}

/// Everything measured for one Run (one Example through one Variant). For role-play a Run is
/// multi-turn and the role-play bundle aggregates across turns.
struct RunMetrics: Codable, Equatable, Sendable {
    var decoded: Bool
    var errorType: String?               // nil | "contextWindow" | "guardrail" | "unsupportedLanguage" | "decoding" | "refusal" | …
    var latencyMs: Int
    var promptTokensEst: Int
    var outputTokensEst: Int
    var contextTokensEst: Int            // cumulative context (peak, for role-play)
    var contextHeadroom: Int             // contextWindow - contextTokensEst
    var onTargetLanguage: Double?        // gloss: translations in native; role-play: lines in learning
    var gloss: GlossMetrics?
    var roleplay: RoleplayMetrics?
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

// MARK: - Objective evaluators

enum Evaluators {
    static let knownPOS: Set<String> = [
        "noun", "proper noun", "propernoun", "verb", "adjective", "adverb", "pronoun",
        "preposition", "postposition", "adposition", "conjunction", "determiner", "article",
        "particle", "numeral", "number", "interjection", "auxiliary", "punctuation"
    ]

    /// Gloss output metrics. `sentence` is the learning-language input; `native` is where
    /// translations should land.
    static func gloss(_ r: GlossResultGen, sentence: String, native: String) -> (GlossMetrics, onTargetLanguage: Double?) {
        let surfaces = r.words
            .map { normalize($0.surface) }
            .filter { !$0.isEmpty }
        let sourceWords = Set(LanguageTools.words(sentence).map(normalize).filter { !$0.isEmpty })
        let surfaceSet = Set(surfaces)

        let covered = sourceWords.isEmpty ? 0 : sourceWords.filter { surfaceSet.contains($0) }.count
        let coverage = sourceWords.isEmpty ? 0 : Double(covered) / Double(sourceWords.count)

        let hallucinated = surfaces.filter { !sourceWords.contains($0) }.count
        let halluc = surfaces.isEmpty ? 0 : Double(hallucinated) / Double(surfaces.count)

        let dedup = surfaces.isEmpty ? 0 : 1 - Double(surfaceSet.count) / Double(surfaces.count)

        var checks = 0, passed = 0
        for w in r.words {
            // Skipped (already-known) words legitimately have a blank translation — don't penalize it.
            var fields = [w.surface, w.lemma, w.partOfSpeech]
            if w.glossed { fields.append(w.translation) }
            for field in fields {
                checks += 1
                if !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { passed += 1 }
            }
        }
        checks += 1
        let transPresent = !r.sentenceTranslation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if transPresent { passed += 1 }
        let completeness = checks == 0 ? 0 : Double(passed) / Double(checks)

        let pos = r.words.map { $0.partOfSpeech.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        let posOK = pos.isEmpty ? 0 : Double(pos.filter { knownPOS.contains($0) }.count) / Double(pos.count)

        // Language check: the generated translations must be in the native language.
        var nativeTexts = [r.sentenceTranslation] + r.words.map(\.translation)
        nativeTexts = nativeTexts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let lang = LanguageTools.matchScore(nativeTexts, expected: native)

        let m = GlossMetrics(wordCount: r.words.count, coverageRatio: coverage,
                             hallucinationRate: halluc, fieldCompleteness: completeness,
                             dedupRate: dedup, posPlausibility: posOK,
                             sentenceTranslationPresent: transPresent)
        return (m, lang)
    }

    /// Role-play metrics aggregated across the turns of one Run. `peakContext` is the worst-case
    /// estimated context size seen across turns; `hitLimit` flags an exceededContextWindowSize.
    static func roleplay(_ turns: [RoleplayTurnGen], learning: String, native: String,
                         peakContext: Int, hitLimit: Bool) -> (RoleplayMetrics, onTargetLanguage: Double?) {
        let n = max(turns.count, 1)
        let twoSuggestions = turns.filter { $0.suggestions.count == 2 }.count
        let distinct = turns.filter { distinctTexts($0.suggestions.map(\.text)) }.count

        let replies = turns.map(\.reply.text)
        let suggestionTexts = turns.flatMap { $0.suggestions.map(\.text) }
        let translations = (turns.map(\.reply.translation) + turns.flatMap { $0.suggestions.map(\.translation) })

        let replyLang = LanguageTools.matchScore(replies, expected: learning) ?? 0
        let suggLang = LanguageTools.matchScore(suggestionTexts, expected: learning) ?? 0
        let transPresent = translations.isEmpty ? 0 :
            Double(translations.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count) / Double(translations.count)
        let avgReply = replies.isEmpty ? 0 : Double(replies.map(\.count).reduce(0, +)) / Double(replies.count)

        let combinedLang = LanguageTools.matchScore(replies + suggestionTexts, expected: learning)

        let m = RoleplayMetrics(turnCount: turns.count,
                                suggestionCountOK: Double(twoSuggestions) / Double(n),
                                distinctSuggestions: Double(distinct) / Double(n),
                                replyLangOK: replyLang, suggestionsLangOK: suggLang,
                                translationPresent: transPresent, avgReplyChars: avgReply,
                                peakContextTokensEst: peakContext, hitContextLimit: hitLimit)
        return (m, combinedLang)
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
    }

    private static func distinctTexts(_ texts: [String]) -> Bool {
        let cleaned = texts.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        return Set(cleaned).count == cleaned.count
    }
}

// MARK: - Generic evaluator (dynamic / custom-schema runs)
// A custom SchemaDef produces untyped GeneratedContent, so the typed Evaluators can't run. This
// schema-agnostic fallback measures only what's universal: did it decode, latency/tokens, and the
// on-target language across every string leaf of the produced JSON. gloss/roleplay stay nil, which
// VariantStats/GoldenThresholds already skip.

enum GenericEvaluator {
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
        case .generic:
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
