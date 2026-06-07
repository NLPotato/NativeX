//
//  PlaygroundCore.swift
//  Prompt Playground
//
//  Shared LLMOps primitives used across the pipeline: task kinds, a Codable mirror of
//  GenerationOptions, on-device token ESTIMATION (Apple exposes no token API — see note),
//  and NaturalLanguage-based language detection / tokenization for the objective metrics.
//
//  FoundationModels API facts below were verified against the installed SDK
//  (…/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface), not assumed.
//

import Foundation
import NaturalLanguage
import FoundationModels

// MARK: - Task kind

enum TaskKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case gloss, roleplay
    var id: String { rawValue }
    var label: String { self == .gloss ? "Gloss" : "Role-play" }
}

// MARK: - Generation config (Codable mirror of GenerationOptions)
// GenerationOptions isn't Codable, so we persist this and rebuild it per run. Verified
// initializer: GenerationOptions(sampling:temperature:maximumResponseTokens:), with
// SamplingMode = .greedy | .random(top:seed:) | .random(probabilityThreshold:seed:).

struct GenConfig: Codable, Equatable, Hashable, Sendable {
    enum Sampling: String, Codable, CaseIterable, Sendable {
        case `default`, greedy
        var label: String { self == .greedy ? "greedy" : "default" }
    }
    var sampling: Sampling = .default
    var temperature: Double? = nil
    var maximumResponseTokens: Int? = nil

    func toOptions() -> GenerationOptions {
        GenerationOptions(
            sampling: sampling == .greedy ? .greedy : nil,
            temperature: temperature,
            maximumResponseTokens: maximumResponseTokens
        )
    }

    /// Short human label for leaderboards, e.g. "greedy · maxTok 512".
    var label: String {
        var parts = [sampling.label]
        if let t = temperature { parts.append("temp \(String(format: "%.2g", t))") }
        if let m = maximumResponseTokens { parts.append("maxTok \(m)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Token estimation
// FoundationModels exposes NO token-count API. Verified: the ONLY token-related symbols in
// the framework interface are GenerationOptions.maximumResponseTokens (an input cap) and
// LanguageModelSession.GenerationError.exceededContextWindowSize. There is no tokenCount(for:)
// and Response carries no usage. So all token figures here are ESTIMATES, labelled as such.
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
                return "Apple Intelligence is off. Enable it in System Settings ▸ Apple Intelligence & Siri, and make sure the Siri language matches your device language."
            case .modelNotReady:
                return "The on-device model is still downloading. Try again shortly."
            @unknown default:
                return "Foundation Models is currently unavailable."
            }
        }
    }
}
