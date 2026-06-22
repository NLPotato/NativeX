//
//  PlaygroundCore.swift
//  Prompt Playground
//
//  Shared LLMOps primitives used across the pipeline: task kinds, a Codable mirror of
//  GenerationOptions, on-device token estimation (heuristic fallback — see the note at
//  TokenEstimator), and NaturalLanguage-based language detection / tokenization for the
//  objective metrics.
//
//  FoundationModels API facts below were verified against the installed SDK
//  (…/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface), not assumed.
//

import Foundation
import NaturalLanguage
import FoundationModels
import SQLite3

// MARK: - Task kind

enum TaskKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case gloss, roleplay
    case custom = "generic"   // rawValue pinned to "generic" so already-saved datasets keep loading
    var id: String { rawValue }
    var label: String {
        switch self {
        case .gloss:    return "Gloss"
        case .roleplay: return "Role-play"
        case .custom:   return "Custom"
        }
    }
}

// MARK: - Variable substitution (one source of truth for {{name}} placeholders)
// Shared by the Graph executor, the headless runners, and the hook engine so detection and
// substitution can never drift. A name is letters/digits/underscore; inner whitespace is trimmed.

enum Vars {
    static let pattern = /\{\{\s*([A-Za-z0-9_]+)\s*\}\}/

    /// Replace every `{{name}}` with `values[name]`, or "" when the name is unbound.
    static func substitute(_ template: String, _ values: [String: String]) -> String {
        template.replacing(pattern) { values[String($0.1)] ?? "" }
    }

    /// Variable names referenced in `template`, in first-appearance order, deduped.
    static func keys(in template: String) -> [String] {
        var seen = Set<String>(), keys: [String] = []
        for m in template.matches(of: pattern) where seen.insert(String(m.1)).inserted {
            keys.append(String(m.1))
        }
        return keys
    }
}

// MARK: - Prompt analysis (the mis-wiring guards, shared)
// Pure, stateless authoring-time guards. One home so the Graph executor, the Lab variant inspector,
// and the Datasets editor can't drift on what counts as a user variable / a malformed token / an
// unused hook output.

enum PromptAnalysis {
    /// Keys the Prompt field provides (`{{prompt}}` canonical + legacy `{{input}}`) — never editable.
    static let reservedVars: Set<String> = ["prompt", "input"]

    /// User-editable variables: every `{{name}}` in instructions or input that ISN'T produced by a
    /// hook and isn't reserved. First-appearance order, deduped.
    static func variableKeys(instructions: String, input: String, hooks: HookPipelineDef) -> [String] {
        let produced = hooks.producedVars
        var seen = Set<String>(), keys: [String] = []
        for key in Vars.keys(in: instructions) + Vars.keys(in: input)
        where !produced.contains(key) && !reservedVars.contains(key) {
            if seen.insert(key).inserted { keys.append(key) }
        }
        return keys
    }

    /// True when the prompt references the Prompt-field token (`{{prompt}}` or legacy `{{input}}`).
    static func usesPromptToken(instructions: String, input: String) -> Bool {
        !Set(Vars.keys(in: instructions) + Vars.keys(in: input)).isDisjoint(with: reservedVars)
    }

    /// Variables produced by enabled hooks.
    static func hookOutputs(_ hooks: HookPipelineDef) -> Set<String> { hooks.producedVars }

    /// `{{…}}` fragments whose contents aren't a clean variable name (letters/digits/underscore) —
    /// so malformed tokens like `{{na me}}` or `{{}}` are flagged rather than silently dropped.
    static func malformedTokens(in text: String) -> [String] {
        var bad: [String] = []
        for match in text.matches(of: /\{\{(.*?)\}\}/) {
            let inner = String(match.1)
            if inner.trimmingCharacters(in: .whitespaces).wholeMatch(of: /[A-Za-z0-9_]+/) == nil {
                bad.append("{{\(inner)}}")
            }
        }
        return bad
    }

    /// Enabled pre-hooks whose `outputVar` is consumed nowhere — not by an instructions/input
    /// `{{token}}`, a later hook's input var, or any hook's params. Usually a typo of the `{{token}}`
    /// the prompt actually expects; flagged before a run wastes a model call on a blank variable.
    static func unusedHookOutputs(instructions: String, input: String, hooks: HookPipelineDef) -> [String] {
        let produced = hooks.pre.filter { $0.enabled && !$0.outputVar.isEmpty }
        guard !produced.isEmpty else { return [] }
        var consumed = Set(Vars.keys(in: instructions) + Vars.keys(in: input))
        for hook in hooks.pre + hooks.post where hook.enabled {
            consumed.insert(hook.inputVar)
            for value in hook.params.values { consumed.formUnion(Vars.keys(in: value)) }
        }
        var seen = Set<String>(), unused: [String] = []
        for hook in produced where !consumed.contains(hook.outputVar) {
            if seen.insert(hook.outputVar).inserted { unused.append(hook.outputVar) }
        }
        return unused
    }

    /// Final-prompt stage note: the schema mode plus an estimated token-headroom reading, so an
    /// over-long prompt is visible *before* it trips the 4096-token window at runtime.
    static func headroomNote(instructions: String, prompt: String, schemaInjected: Bool) -> String {
        let schema = schemaInjected
            ? "Guided Generation schema injected (includeSchemaInPrompt: true)"
            : "No schema — free-text output"
        let tokens = TokenEstimator.estimate(instructions + "\n" + prompt)
        let pct = Int((Double(tokens) / Double(TokenEstimator.contextWindow) * 100).rounded())
        let warn = tokens > Int(0.9 * Double(TokenEstimator.contextWindow)) ? "⚠︎ " : ""
        return "\(schema)\n\(warn)~\(tokens) estimated tokens · \(pct)% of the \(TokenEstimator.contextWindow)-token window"
    }
}

// MARK: - Proficiency
// Drives deterministic word-selection in the gloss pipeline: words whose Zipf frequency is at or
// above `glossCutoff` are assumed already-known and are NOT sent to the model to gloss (beginner
// glosses everything). A single numeric knob so the three levels just sample a curve that can be
// re-tuned without touching call sites. Cutoffs are tuned empirically — see ADR-20260608.

enum Proficiency: String, Codable, CaseIterable, Sendable {
    case beginner, intermediate, advanced

    /// Zipf threshold (≈1–8) at/above which a word is assumed known and skipped. nil = gloss all.
    var glossCutoff: Double? {
        switch self {
        case .beginner:     return nil
        case .intermediate: return 6.0
        case .advanced:     return 5.0
        }
    }

    /// Lenient parse from a free-text label ("Advanced"/"advanced"); defaults to intermediate.
    init(label: String) {
        let key = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = Proficiency(rawValue: key) ?? .intermediate
    }
}

// MARK: - Generation config (Codable mirror of GenerationOptions)
// GenerationOptions isn't Codable, so we persist this and rebuild it per run. Verified
// initializer: GenerationOptions(sampling:temperature:maximumResponseTokens:), with
// SamplingMode = .greedy | .random(top:seed:) | .random(probabilityThreshold:seed:).

struct GenConfig: Codable, Equatable, Hashable, Sendable {
    enum Sampling: String, Codable, CaseIterable, Sendable {
        case `default`, greedy, topK, nucleus
        var label: String {
            switch self {
            case .default: return "default"
            case .greedy:  return "greedy"
            case .topK:    return "top-k"
            case .nucleus: return "nucleus"
            }
        }
    }
    var sampling: Sampling = .default
    var temperature: Double? = nil
    var maximumResponseTokens: Int? = nil
    // Sampling-mode params (used only by the matching mode). seed makes random sampling reproducible.
    var topK: Int? = nil
    var probabilityThreshold: Double? = nil   // nucleus / top-p
    var seed: UInt64? = nil

    func toOptions() -> GenerationOptions {
        let mode: GenerationOptions.SamplingMode?
        switch sampling {
        case .default: mode = nil
        case .greedy:  mode = .greedy
        case .topK:    mode = .random(top: topK ?? 50, seed: seed)
        case .nucleus: mode = .random(probabilityThreshold: probabilityThreshold ?? 0.9, seed: seed)
        }
        return GenerationOptions(sampling: mode, temperature: temperature,
                                 maximumResponseTokens: maximumResponseTokens)
    }

    /// Short human label for leaderboards, e.g. "nucleus p0.9 · seed 42 · temp 0.7 · maxTok 512".
    var label: String {
        var parts: [String]
        switch sampling {
        case .default: parts = ["default"]
        case .greedy:  parts = ["greedy"]
        case .topK:    parts = ["top-k \(topK ?? 50)"]
        case .nucleus: parts = [String(format: "nucleus p%.2g", probabilityThreshold ?? 0.9)]
        }
        if let t = temperature { parts.append("temp \(String(format: "%.2g", t))") }
        if let s = seed, sampling == .topK || sampling == .nucleus { parts.append("seed \(s)") }
        if let m = maximumResponseTokens { parts.append("maxTok \(m)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Token estimation
// macOS 26.4 added native token introspection: `model.tokenCount(for:)` before a call and
// `response.usage` (input / output / cached / reasoning counts) after one — see docs/prd.md §6.3
// and docs/reference/foundation-models.md. Those are the preferred source of truth on 26.4+.
//
// HOWEVER: this project currently builds with the Xcode 26.2 SDK, whose FoundationModels
// interface contains NEITHER symbol (verified 2026-06: zero `tokenCount`/`usage` matches in
// …/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface). The native path cannot
// compile until the 26.4 SDK ships in Xcode, so every figure here is a heuristic ESTIMATE,
// labelled as such in the UI.
//
// TODO(Xcode 26.4 SDK): behind `#available(macOS 26.4, *)`, route `estimate(_:)` through
// `model.tokenCount(for:)` and surface `response.usage.*` in GraphExecutor's trace steps
// (ExecStep.promptTokens/outputTokens); keep this heuristic as the 26.0–26.3 fallback.
//
// Heuristic: dense scripts (CJK ideographs, Hangul, Kana) ≈ 1 token per character; everything
// else ≈ 1 token per 4 characters. Deliberately slightly conservative so headroom warnings
// fire early rather than late.

enum TokenEstimator {
    /// On-device session context window, per Apple TN3193 ("Managing the on-device foundation
    /// model's context window"). There is no API constant, so it's defined here.
    static let contextWindow = 4096

    static func estimate(_ text: String) -> Int {
        var dense = 0, other = 0
        for scalar in text.unicodeScalars {
            if isDenseScript(scalar) { dense += 1 } else { other += 1 }
        }
        return dense + Int((Double(other) / 4.0).rounded(.up))
    }

    /// Cumulative context size from the live transcript — the real headroom signal for
    /// multi-turn role-play (instructions + every prompt + every response).
    static func estimate(_ transcript: Transcript) -> Int {
        estimate(transcript.estimationText)
    }

    static func headroom(_ contextTokens: Int) -> Int { contextWindow - contextTokens }

    private static func isDenseScript(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x1100...0x11FF,   // Hangul Jamo
             0x3040...0x30FF,   // Hiragana + Katakana
             0x3400...0x4DBF,   // CJK Extension A
             0x4E00...0x9FFF,   // CJK Unified Ideographs
             0xAC00...0xD7AF,   // Hangul Syllables
             0xF900...0xFAFF:   // CJK Compatibility Ideographs
            return true
        default:
            return false
        }
    }
}

extension Transcript {
    /// Best-effort plain text of the whole transcript, for token ESTIMATION only.
    var estimationText: String {
        map { entry in
            switch entry {
            case .instructions(let i): return i.segments.map(\.estimationText).joined(separator: " ")
            case .prompt(let p):       return p.segments.map(\.estimationText).joined(separator: " ")
            case .response(let r):     return r.segments.map(\.estimationText).joined(separator: " ")
            case .toolOutput(let o):   return o.segments.map(\.estimationText).joined(separator: " ")
            case .toolCalls(let calls): return calls.map { String(describing: $0.arguments) }.joined(separator: " ")
            @unknown default: return ""
            }
        }.joined(separator: "\n")
    }
}

extension Transcript.Segment {
    var estimationText: String {
        switch self {
        case .text(let t):      return t.content
        case .structure(let s): return String(describing: s.content)
        @unknown default:       return ""
        }
    }
}

// MARK: - Language tools (NaturalLanguage)
// Used by the objective metrics to check generated text is actually in the expected language
// and to tokenize sentences for gloss coverage/hallucination.

enum LanguageTools {
    /// Human language name → NLLanguage. Extend as the bench takes on more languages.
    static let nameToLanguage: [String: NLLanguage] = [
        "english": .english, "german": .german, "korean": .korean, "japanese": .japanese,
        "chinese": .simplifiedChinese, "simplified chinese": .simplifiedChinese,
        "traditional chinese": .traditionalChinese, "spanish": .spanish, "french": .french,
        "italian": .italian, "portuguese": .portuguese, "dutch": .dutch, "russian": .russian,
        "arabic": .arabic, "hindi": .hindi, "turkish": .turkish, "polish": .polish,
        "swedish": .swedish, "vietnamese": .vietnamese, "thai": .thai, "indonesian": .indonesian
    ]

    /// Resolve a language name ("German") or ISO code ("de") to an NLLanguage, else nil.
    static func language(named name: String) -> NLLanguage? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let mapped = nameToLanguage[key] { return mapped }
        if (2...3).contains(key.count), key.allSatisfy(\.isLetter) { return NLLanguage(rawValue: key) }
        return nil
    }

    /// Dominant language of a string, or nil when too short to call reliably.
    static func detect(_ text: String) -> NLLanguage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        return recognizer.dominantLanguage
    }

    /// Fraction of `texts` whose detected language matches `expected`. Strings too short to
    /// detect are skipped (neither help nor hurt). Returns nil when nothing was measurable or
    /// the expected language is unknown.
    static func matchScore(_ texts: [String], expected name: String) -> Double? {
        guard let expected = language(named: name) else { return nil }
        var measured = 0, ok = 0
        for t in texts {
            guard let d = detect(t) else { continue }
            measured += 1
            if d == expected { ok += 1 }
        }
        return measured == 0 ? nil : Double(ok) / Double(measured)
    }

    /// Lowercased word tokens of a string (NaturalLanguage handles CJK word segmentation too).
    static func words(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]).lowercased() }
    }

    /// Named entities (people · places · organizations) via NLTagger's `.nameType` scheme — one
    /// list item per entity as "surface  ·  Type". `.joinNames` folds multi-word names into a single
    /// span; languages NLTagger can't tag yield an empty list. On-device, full iOS↔macOS parity.
    static func namedEntities(_ text: String, language name: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        if let lang = language(named: name) {
            tagger.setLanguage(lang, range: text.startIndex..<text.endIndex)
        }
        let labels: [NLTag: String] = [.personalName: "Person", .placeName: "Place",
                                       .organizationName: "Organization"]
        var out: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if let tag, let label = labels[tag] { out.append("\(String(text[range]))  ·  \(label)") }
            return true
        }
        return out
    }

    /// Overall sentiment as (score ∈ -1…1, label). Averages NLTagger's per-paragraph
    /// `.sentimentScore`; languages without a sentiment model yield 0 / "neutral".
    static func sentiment(_ text: String) -> (score: Double, label: String) {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text
        var scores: [Double] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .paragraph,
                             scheme: .sentimentScore, options: []) { tag, _ in
            if let raw = tag?.rawValue, let v = Double(raw) { scores.append(v) }
            return true
        }
        let score = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
        let label = score > 0.1 ? "positive" : (score < -0.1 ? "negative" : "neutral")
        return (score, label)
    }

    /// Length statistics for context budgeting (pairs with the Count-tokens op): characters
    /// (grapheme clusters), CJK-aware word + sentence counts (NLTokenizer), newline-delimited lines.
    static func textStats(_ text: String) -> (characters: Int, words: Int, sentences: Int, lines: Int) {
        func count(_ unit: NLTokenUnit) -> Int {
            let tok = NLTokenizer(unit: unit)
            tok.string = text
            return tok.tokens(for: text.startIndex..<text.endIndex).count
        }
        let lines = text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count
        return (text.count, count(.word), count(.sentence), lines)
    }
}

// MARK: - Deterministic gloss enrichment (NaturalLanguage + CFStringTokenizer)
// The on-device model is unreliable at producing the word list, POS, lemma, or readings: it
// alters surfaces and romanizes CJK despite instructions (verified empirically — see the eval
// harness). So the gloss pipeline lets DETERMINISTIC APIs own those fields. NLTokenizer segments
// (coverage 100%, surfaces verbatim); NLTagger supplies POS+lemma for the 8 languages it covers;
// CFStringTokenizer supplies the Latin reading (pinyin/romaji/romaja) for non-Latin scripts. The
// model then only annotates this fixed list (in-context meaning, sentence translation).

/// One deterministically-analyzed token. `pos`/`lemma` are nil for languages NLTagger can't tag
/// (CJK, Arabic, …); `romanization` is nil for Latin-script languages.
struct EnrichedToken: Codable, Equatable, Sendable {
    var surface: String
    var pos: String?
    var lemma: String?
    var romanization: String?
    /// Zipf frequency (≈1–8) of the word family (looked up by lemma where available, else surface),
    /// or nil when rarer than the bundled list's floor. Drives proficiency word-selection.
    var zipf: Double?
}

extension LanguageTools {
    /// The only 8 languages NLTagger supports for `.lexicalClass` / `.lemma` (verified).
    static let taggedLanguages: Set<NLLanguage> = [.english, .german, .french, .spanish,
                                                   .italian, .portuguese, .russian, .turkish]
    /// POS vocabulary aligned to `NLTag.lexicalClass` raw values (lowercased) — used both as the
    /// model's `partOfSpeech` enum and as the normalization target for the deterministic tags.
    static let posVocabulary = ["noun", "verb", "adjective", "adverb", "pronoun", "determiner",
                                "preposition", "particle", "number", "conjunction", "interjection",
                                "classifier", "other"]

    private static let nonLatinLanguages: Set<NLLanguage> = [.japanese, .simplifiedChinese,
        .traditionalChinese, .korean, .russian, .arabic, .hindi, .thai, .greek, .hebrew]

    /// Segment a sentence and attach deterministic POS+lemma (where supported) and romanization
    /// (non-Latin scripts). This is the authoritative word list for the gloss; the model annotates it.
    static func enrich(_ sentence: String, language name: String) -> [EnrichedToken] {
        let lang = language(named: name)
        let tokenizer = NLTokenizer(unit: .word)
        if let lang { tokenizer.setLanguage(lang) }
        tokenizer.string = sentence
        let ranges = tokenizer.tokens(for: sentence.startIndex..<sentence.endIndex)

        let canTag = lang.map(taggedLanguages.contains) ?? false
        let nonLatin = lang.map(nonLatinLanguages.contains) ?? false
        let tagger: NLTagger? = canTag ? NLTagger(tagSchemes: [.lexicalClass, .lemma]) : nil
        if let tagger, let lang {
            tagger.string = sentence
            tagger.setLanguage(lang, range: sentence.startIndex..<sentence.endIndex)
        }
        let localeID = lang?.rawValue ?? name
        let freqCode = lang.map(wordfreqCode(for:))

        return ranges.map { range in
            let surface = String(sentence[range])
            var pos: String?
            var lemma: String?
            if let tagger {
                if let raw = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lexicalClass).0?.rawValue {
                    let p = raw.lowercased() == "otherword" ? "other" : raw.lowercased()
                    pos = posVocabulary.contains(p) ? p : "other"
                }
                lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            }
            let rom = nonLatin ? latinTranscription(surface, localeID: localeID) : nil
            // Look up by lemma where available (word-family frequency), else by surface.
            let zipf = freqCode.flatMap { FrequencyDB.shared.zipf(lemma ?? surface, lang: $0) }
            return EnrichedToken(surface: surface, pos: pos, lemma: lemma,
                                 romanization: (rom?.isEmpty == false) ? rom : nil, zipf: zipf)
        }
    }

    /// wordfreq language code (base subtag of the NLLanguage code: "zh-Hans" → "zh", "de" → "de"),
    /// used to query the bundled frequency DB.
    static func wordfreqCode(for lang: NLLanguage) -> String {
        String(lang.rawValue.split(separator: "-").first ?? Substring(lang.rawValue))
    }

    /// Rule-based Latin reading via CFStringTokenizer (pinyin / romaji / romaja). Deterministic,
    /// on-device, full iOS↔macOS parity — the model is never trusted with this.
    static func latinTranscription(_ text: String, localeID: String) -> String {
        let cf = text as CFString
        let locale = Locale(identifier: localeID) as CFLocale
        let tok = CFStringTokenizerCreate(nil, cf, CFRangeMake(0, CFStringGetLength(cf)),
                                          kCFStringTokenizerUnitWord, locale)
        var parts: [String] = []
        var t = CFStringTokenizerAdvanceToNextToken(tok)
        while t.rawValue != 0 {
            if let r = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription) as? String {
                parts.append(r)
            }
            t = CFStringTokenizerAdvanceToNextToken(tok)
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Bundled word-frequency lookup (Stage 4)
// There is no on-device word-frequency API, so the proficiency word-selection lever ships its own
// data: a small read-only SQLite (word → Zipf) bundled with the app, derived from wordfreq
// (CC-BY-SA 4.0; see Resources/freq_LICENSE.txt + tools/build_freq_db.py). libsqlite3 + the bundled
// file work identically on iOS (verified against the iOS 26 SDK). Missing word → nil → treat as rare.

final class FrequencyDB: @unchecked Sendable {
    static let shared = FrequencyDB()
    private let db: OpaquePointer?
    // SQLite wants to copy bound strings (they're Swift temporaries), so pass the TRANSIENT destructor.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private init() {
        var handle: OpaquePointer?
        if let url = Bundle.main.url(forResource: "freq", withExtension: "sqlite"),
           sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            db = handle
        } else {
            db = nil   // DB absent (e.g. headless harness) → all lookups return nil → gloss everything.
        }
    }

    /// Zipf frequency (≈1–8) of `word` in wordfreq language code `lang` (e.g. "de"), or nil when the
    /// word is absent (rarer than the bundled floor) or the DB is unavailable.
    func zipf(_ word: String, lang: String) -> Double? {
        guard let db, !word.isEmpty else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT z FROM freq WHERE lang=? AND word=? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, lang, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, word.lowercased(), -1, Self.transient)
        return sqlite3_step(stmt) == SQLITE_ROW ? Double(sqlite3_column_int(stmt, 0)) / 100.0 : nil
    }
}

// MARK: - JSON helpers

/// Pretty JSON (declaration order preserved) for schema-vs-output checking and storage.
func prettyJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let json = String(data: data, encoding: .utf8) else {
        return String(describing: value)
    }
    return json
}

// MARK: - Model availability (shared)

enum ModelAvailability {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// BCP-47 languages the on-device model supports, queried at runtime (coverage widens across OS
    /// point releases — never hardcode). Mirrors the iOS port's `getAvailability()`.
    static var supportedLanguages: [String] {
        SystemLanguageModel.default.supportedLanguages.map { $0.maximalIdentifier }.sorted()
    }

    /// Whether the current device locale is one the model supports (`supportsLocale`). A *truthful*
    /// language-mismatch signal — Apple folds the mismatch into `.appleIntelligenceNotEnabled`, so
    /// without this the cause can't be told apart from "AI simply off". (iOS-port parity.)
    static var localeSupported: Bool {
        SystemLanguageModel.default.supportsLocale(Locale.current)
    }

    /// Non-nil when the model can't run; explains why.
    static var message: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "Foundation Models isn't available on this Mac (requires Apple silicon)."
            case .appleIntelligenceNotEnabled:
                // Distinguish the two folded-together causes via the now-truthful locale check.
                return localeSupported
                    ? "Apple Intelligence is off. Enable it in System Settings ▸ Apple Intelligence & Siri."
                    : "The device language (\(Locale.current.identifier(.bcp47))) isn't supported by the on-device model. Set System Settings ▸ Apple Intelligence & Siri to a supported language, with the Siri language matching."
            case .modelNotReady:
                return "The on-device model is still downloading. Try again shortly."
            @unknown default:
                return "Foundation Models is currently unavailable."
            }
        }
    }
}
