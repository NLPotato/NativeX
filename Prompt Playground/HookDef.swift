//
//  HookDef.swift
//  Prompt Playground
//
//  Codable description of the deterministic, non-LLM steps that run BEFORE (pre) and AFTER (post)
//  a Foundation Models call — the app's equivalent of Claude Code hooks, but built from native
//  Apple frameworks (NaturalLanguage / Foundation) so they are sandbox-safe and run identically on
//  macOS and iOS. A pre-hook reads a value from the run context, transforms it via a native op, and
//  writes the result back under `outputVar` — which the prompt can then reference as `{{outputVar}}`.
//
//  This is the hook counterpart of SchemaDef: a UI-authored, JSON-persisted config (HooksModel-style
//  storage lives on PromptTemplateModel.hooksJSON). The executor is HookEngine.
//

import Foundation

/// Where a hook runs relative to the model call.
enum HookPhase: String, Codable, Sendable { case pre, post, both }

/// Platform reach of a hook op, surfaced as a badge. The whole point of authoring on macOS is to
/// ship the same context to an iOS app — so an op that wouldn't carry to iOS is flagged here. Every
/// current op uses cross-platform Apple frameworks, hence `.universal`; the other cases exist so a
/// future non-portable op (shell, network) is visibly marked rather than silently breaking on iOS.
enum Portability: String, Codable, Sendable {
    case universal   // NaturalLanguage / Foundation — iOS + macOS
    case macOSOnly
    case network

    var label: String {
        switch self {
        case .universal: return "iOS · macOS"
        case .macOSOnly: return "macOS only"
        case .network:   return "needs network"
        }
    }
    /// universal is safe (green); the rest are caveats (amber).
    var isPortable: Bool { self == .universal }
}

/// Editable parameters an op reads out of `HookDef.params`. Each renders one labelled field.
enum HookParam: String, Sendable, Hashable {
    case language, format, pattern, group, replacement, path, mode, command, timeout

    var label: String {
        switch self {
        case .language:    return "language"
        case .format:      return "format"
        case .pattern:     return "pattern"
        case .group:       return "group"
        case .replacement: return "replace"
        case .path:        return "path"
        case .mode:        return "mode"
        case .command:     return "command"
        case .timeout:     return "timeout"
        }
    }
    var placeholder: String {
        switch self {
        case .language:    return "e.g. German or {{learning}}"
        case .format:      return "numbered | lines | comma"
        case .pattern:     return "regular expression"
        case .group:       return "capture group # (0 = whole match)"
        case .replacement: return "replacement / $1"
        case .path:        return "dotted key path, e.g. words.0.surface"
        case .mode:        return "trim | lower | upper | trimlines"
        case .command:     return "shell command — input on stdin, stdout becomes the output var"
        case .timeout:     return "seconds (default 30)"
        }
    }
}

/// A native, deterministic operation. String-backed (+ a flat `params` dict) so the whole config
/// round-trips through plain Codable with no hand-written enum coding — mirrors `taskRaw`.
enum HookOp: String, Codable, CaseIterable, Sendable {
    case tokenizeWords, enrichGloss, detectLanguage, sentenceSplit
    case regexExtract, regexReplace, jsonExtract, textTransform
    case script

    var displayName: String {
        switch self {
        case .tokenizeWords:  return "Tokenize words"
        case .enrichGloss:    return "Enrich tokens"
        case .detectLanguage: return "Detect language"
        case .sentenceSplit:  return "Split sentences"
        case .regexExtract:   return "Regex extract"
        case .regexReplace:   return "Regex replace"
        case .jsonExtract:    return "JSON extract"
        case .textTransform:  return "Text transform"
        case .script:         return "Run script"
        }
    }
    var detail: String {
        switch self {
        case .tokenizeWords:  return "NLTokenizer → a word list"
        case .enrichGloss:    return "NaturalLanguage POS + lemma + romanization per word"
        case .detectLanguage: return "NLLanguageRecognizer → dominant language code"
        case .sentenceSplit:  return "NLTokenizer → one sentence per line"
        case .regexExtract:   return "First match (or capture group) of a pattern"
        case .regexReplace:   return "Replace every match of a pattern"
        case .jsonExtract:    return "Read a dotted key path out of JSON"
        case .textTransform:  return "trim / lowercase / uppercase"
        case .script:         return "Shell command via /bin/zsh — input on stdin, stdout → output var, context vars as $PP_*"
        }
    }
    /// Pre-only ops produce text for the prompt; post-only consume model output; both are general.
    var phase: HookPhase {
        switch self {
        case .tokenizeWords, .enrichGloss, .sentenceSplit: return .pre
        case .jsonExtract:                                 return .post
        default:                                           return .both
        }
    }
    /// Native ops are byte-identical on iOS + macOS; a script shells out, so it can't port to the
    /// iOS app and is flagged `.macOSOnly` (amber badge) — the run still works here on macOS.
    var portability: Portability {
        switch self {
        case .script: return .macOSOnly
        default:      return .universal
        }
    }

    var paramKeys: [HookParam] {
        switch self {
        case .tokenizeWords:  return [.language, .format]
        case .enrichGloss:    return [.language]
        case .sentenceSplit:  return [.format]
        case .detectLanguage: return []
        case .regexExtract:   return [.pattern, .group]
        case .regexReplace:   return [.pattern, .replacement]
        case .jsonExtract:    return [.path]
        case .textTransform:  return [.mode]
        case .script:         return [.command, .timeout]
        }
    }
    /// A sensible default `outputVar` when the op is first added.
    var defaultOutputVar: String {
        switch self {
        case .tokenizeWords:  return "words"
        case .enrichGloss:    return "tokens"
        case .detectLanguage: return "language"
        case .sentenceSplit:  return "sentences"
        case .regexExtract:   return "match"
        case .regexReplace:   return "replaced"
        case .jsonExtract:    return "field"
        case .textTransform:  return "text"
        case .script:         return "result"
        }
    }

    /// Short editor suffix when an op only runs in one phase (`""` when it runs in both) — so the
    /// add-hook menu explains why, e.g., JSON extract is absent from the pre list.
    var phaseTag: String {
        switch phase {
        case .pre:  return " · pre only"
        case .post: return " · post only"
        case .both: return ""
        }
    }

    /// Ops offered for a given phase list in the editor (`.both` shows in both).
    static func choices(for phase: HookPhase) -> [HookOp] {
        allCases.filter { $0.phase == phase || $0.phase == .both }
    }
}

/// One configured hook step.
struct HookDef: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var enabled = true
    var opRaw: String
    var params: [String: String] = [:]
    var inputVar: String = "input"
    var outputVar: String = ""

    var op: HookOp { HookOp(rawValue: opRaw) ?? .textTransform }

    init(op: HookOp, inputVar: String = "input", outputVar: String? = nil, params: [String: String] = [:]) {
        self.opRaw = op.rawValue
        self.inputVar = inputVar
        self.outputVar = outputVar ?? op.defaultOutputVar
        self.params = params
    }
}

/// The pre/post hook pipeline persisted alongside a prompt.
struct HookPipelineDef: Codable, Equatable, Sendable {
    var pre: [HookDef] = []
    var post: [HookDef] = []

    static let empty = HookPipelineDef()
    var isEmpty: Bool { pre.isEmpty && post.isEmpty }
    /// Output variable names produced by enabled hooks — used to keep hook outputs out of the
    /// user-editable Variables list (they're computed, not entered).
    var producedVars: Set<String> {
        Set((pre + post).filter { $0.enabled && !$0.outputVar.isEmpty }.map(\.outputVar))
    }
}

/// One executed hook's result — drives the staged pipeline view + (optionally) logging.
struct HookStep: Identifiable, Sendable {
    let id = UUID()
    let hookID: UUID
    let displayName: String
    let outputVar: String
    var output: String?
    var error: String?
    var ms: Int
}
