//
//  APICatalog.swift
//  Prompt Playground
//
//  The data-driven registry behind the developer-facing API surface (PRD §4.2 UX-First, §5.4):
//  every node — and every Native API / Hook operation — maps to its official Apple API: symbol,
//  framework, one-line signature, per-argument GUI mapping, and a developer.apple.com doc link
//  (a §8.3-lite). The inspector uses this for
//    (1) the searchable operation picker on Native API / Hook nodes,
//    (2) the "API mapping" section on EVERY node — which GUI control feeds which API argument,
//        with the live current value, and
//    (3) the node header's official-API chip (GraphNode.apiName reads the first call's symbol).
//
//  Ops the PRD specs that this build can't run yet (Vision OCR/barcode, Spotlight, Evaluate —
//  §5.4.1) are listed as `.planned`: searchable and documented, not selectable.
//
//  Adding an op = one HookOp case + one entry here + one HookEngine.apply branch.
//

import Foundation

// MARK: - Model

/// One argument of an underlying API call, mapped to the GUI control / wire that feeds it.
struct APIArgument: Identifiable {
    let name: String      // Swift argument label, e.g. "unit"
    let type: String      // e.g. "NLTokenUnit"
    let source: String    // what feeds it, e.g. "fixed — .word", "“language” param", "input wire"
    var id: String { name + source }

    init(_ name: String, _ type: String, _ source: String) {
        self.name = name; self.type = type; self.source = source
    }
}

/// One API call a node performs.
struct APICall: Identifiable {
    let symbol: String        // e.g. "NLTokenizer"
    let signature: String     // e.g. "init(unit:) · tokens(for:)"
    var args: [APIArgument] = []
    var returns: String? = nil
    var docPath: String? = nil   // appended to developer.apple.com/documentation/
    var note: String? = nil
    var id: String { symbol + signature }

    var docURL: URL? {
        docPath.flatMap {
            URL(string: "https://developer.apple.com/documentation/"
                + ($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0))
        }
    }
}

/// Catalog row for one Native API / Hook operation.
struct APICatalogEntry: Identifiable {
    enum Status { case available, planned }
    let op: HookOp?            // nil ⇒ planned (no executable HookOp case yet)
    let plannedKey: String?    // identity for planned rows
    let name: String           // friendly label (matches HookOp.displayName for available ops)
    let framework: String
    let summary: String
    let status: Status
    let portability: Portability
    let calls: [APICall]
    var keywords: [String] = []
    var id: String { op?.rawValue ?? plannedKey ?? name }

    /// Everything `search` matches against.
    var searchText: String {
        ([name, framework, summary] + calls.map(\.symbol) + keywords).joined(separator: " ").lowercased()
    }
}

// MARK: - Catalog

enum APICatalog {

    static func entry(for op: HookOp) -> APICatalogEntry? { entries.first { $0.op == op } }

    /// Case-insensitive token match over name / framework / symbols / summary / keywords.
    /// Empty query returns everything (the browse case).
    static func search(_ query: String, in candidates: [APICatalogEntry]) -> [APICatalogEntry] {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return candidates }
        return candidates.filter { e in tokens.allSatisfy { e.searchText.contains($0) } }
    }

    static let entries: [APICatalogEntry] = available + planned

    // MARK: Available operations (each backs a HookOp case)

    private static let available: [APICatalogEntry] = [
        APICatalogEntry(
            op: .tokenizeWords, plannedKey: nil, name: "Tokenize words",
            framework: "NaturalLanguage",
            summary: "Segment text into words (CJK-aware) and emit a formatted list.",
            status: .available, portability: .universal,
            calls: [APICall(
                symbol: "NLTokenizer",
                signature: "init(unit:) · setLanguage(_:) · tokens(for:)",
                args: [
                    APIArgument("unit", "NLTokenUnit", "fixed — .word"),
                    APIArgument("setLanguage", "NLLanguage", "“language” param (name or code; empty = auto)"),
                    APIArgument("string", "String", "input wire (in var)"),
                ],
                returns: "[Range<String.Index>] → formatted via “format” param (numbered | lines | comma)",
                docPath: "naturallanguage/nltokenizer")],
            keywords: ["segment", "word", "split", "cjk"]),

        APICatalogEntry(
            op: .sentenceSplit, plannedKey: nil, name: "Split sentences",
            framework: "NaturalLanguage",
            summary: "Split text into sentences, one per line.",
            status: .available, portability: .universal,
            calls: [APICall(
                symbol: "NLTokenizer",
                signature: "init(unit:) · tokens(for:)",
                args: [
                    APIArgument("unit", "NLTokenUnit", "fixed — .sentence"),
                    APIArgument("string", "String", "input wire (in var)"),
                ],
                returns: "[Range<String.Index>] → formatted via “format” param",
                docPath: "naturallanguage/nltokenizer")],
            keywords: ["sentence", "split", "segment"]),

        APICatalogEntry(
            op: .detectLanguage, plannedKey: nil, name: "Detect language",
            framework: "NaturalLanguage",
            summary: "Dominant language of the input as a BCP-47 code (e.g. “de”).",
            status: .available, portability: .universal,
            calls: [APICall(
                symbol: "NLLanguageRecognizer",
                signature: "processString(_:) · dominantLanguage",
                args: [APIArgument("string", "String", "input wire (in var)")],
                returns: "NLLanguage? → its rawValue (or “und”)",
                docPath: "naturallanguage/nllanguagerecognizer")],
            keywords: ["language", "detect", "recognizer", "locale"]),

        APICatalogEntry(
            op: .enrichGloss, plannedKey: nil, name: "Enrich tokens",
            framework: "NaturalLanguage",
            summary: "Per-word POS + lemma (8 NLTagger languages) and Latin reading (CJK) — the deterministic half of the gloss pipeline.",
            status: .available, portability: .universal,
            calls: [
                APICall(symbol: "NLTagger",
                        signature: "init(tagSchemes: [.lexicalClass, .lemma]) · tag(at:unit:scheme:)",
                        args: [
                            APIArgument("string", "String", "input wire (in var)"),
                            APIArgument("setLanguage", "NLLanguage", "“language” param"),
                        ],
                        returns: "POS + lemma per word (nil for untagged languages, e.g. CJK)",
                        docPath: "naturallanguage/nltagger"),
                APICall(symbol: "CFStringTokenizer",
                        signature: "kCFStringTokenizerAttributeLatinTranscription",
                        args: [APIArgument("locale", "CFLocale", "“language” param")],
                        returns: "romaja / pinyin / romaji reading (non-Latin scripts)",
                        docPath: "corefoundation/cfstringtokenizer-rf8"),
            ],
            keywords: ["gloss", "pos", "lemma", "reading", "romanization", "morphology"]),

        APICatalogEntry(
            op: .countTokens, plannedKey: nil, name: "Count tokens",
            framework: "FoundationModels",
            summary: "Token count of the input + its share of the model's context window. Heuristic estimate on this SDK; routes through the native 26.4 API when the SDK ships it.",
            status: .available, portability: .universal,
            calls: [
                APICall(symbol: "SystemLanguageModel",
                        signature: "tokenCount(for:) async throws -> Int · contextSize",
                        args: [APIArgument("for", "String", "input wire (in var)")],
                        returns: "Int — “format” param: count (number only) | report (≈tokens · % of window)",
                        docPath: "foundationmodels/systemlanguagemodel",
                        note: "macOS 26.4 (back-deployed). The 26.2 SDK this app builds with exposes neither symbol (verified against its swiftinterface), so the op currently uses TokenEstimator: CJK ≈ 1 tok/char, else ≈ 1 tok/4 chars, vs the 4,096-token on-device window."),
            ],
            keywords: ["token", "count", "context", "window", "estimate", "usage", "overflow"]),

        APICatalogEntry(
            op: .regexExtract, plannedKey: nil, name: "Regex extract",
            framework: "Foundation",
            summary: "First match (or capture group) of a pattern.",
            status: .available, portability: .universal,
            calls: [APICall(
                symbol: "NSRegularExpression",
                signature: "init(pattern:) · firstMatch(in:range:)",
                args: [
                    APIArgument("pattern", "String", "“pattern” param"),
                    APIArgument("in", "String", "input wire (in var)"),
                    APIArgument("range(at:)", "Int", "“group” param (0 = whole match)"),
                ],
                returns: "String — the matched text",
                docPath: "foundation/nsregularexpression")],
            keywords: ["regex", "match", "extract", "pattern", "capture"]),

        APICatalogEntry(
            op: .regexReplace, plannedKey: nil, name: "Regex replace",
            framework: "Foundation",
            summary: "Replace every match of a pattern.",
            status: .available, portability: .universal,
            calls: [APICall(
                symbol: "NSRegularExpression",
                signature: "init(pattern:) · stringByReplacingMatches(in:range:withTemplate:)",
                args: [
                    APIArgument("pattern", "String", "“pattern” param"),
                    APIArgument("in", "String", "input wire (in var)"),
                    APIArgument("withTemplate", "String", "“replace” param ($1 = capture group)"),
                ],
                returns: "String",
                docPath: "foundation/nsregularexpression")],
            keywords: ["regex", "replace", "substitute", "pattern"]),

        APICatalogEntry(
            op: .jsonExtract, plannedKey: nil, name: "JSON extract",
            framework: "Foundation",
            summary: "Read a dotted key path (objects by name, arrays by index) out of JSON.",
            status: .available, portability: .universal,
            calls: [APICall(
                symbol: "JSONSerialization",
                signature: "jsonObject(with:options:)",
                args: [
                    APIArgument("with", "Data", "input wire (in var)"),
                    APIArgument("path walk", "String", "“path” param, e.g. words.0.surface"),
                ],
                returns: "String — the scalar at the path",
                docPath: "foundation/jsonserialization")],
            keywords: ["json", "path", "extract", "field", "parse"]),

        APICatalogEntry(
            op: .textTransform, plannedKey: nil, name: "Text transform",
            framework: "Swift",
            summary: "trim / lowercase / uppercase / trim each line.",
            status: .available, portability: .universal,
            calls: [APICall(
                symbol: "String",
                signature: "trimmingCharacters(in:) · lowercased() · uppercased()",
                args: [
                    APIArgument("self", "String", "input wire (in var)"),
                    APIArgument("mode", "String", "“mode” param: trim | lower | upper | trimlines"),
                ],
                returns: "String",
                docPath: "swift/string")],
            keywords: ["trim", "lowercase", "uppercase", "clean", "whitespace"]),

        APICatalogEntry(
            op: .script, plannedKey: nil, name: "Run script",
            framework: "Foundation",
            summary: "External /bin/zsh command. Input → stdin; trimmed stdout → output var; context vars exported as $PP_*. Requires the App Sandbox off — never ships to iOS.",
            status: .available, portability: .macOSOnly,
            calls: [APICall(
                symbol: "Process",
                signature: "executableURL = /bin/zsh · arguments = [\"-c\", command] · run()",
                args: [
                    APIArgument("command", "String", "“command” param (the shell line)"),
                    APIArgument("standardInput", "Pipe", "input wire (in var) → stdin"),
                    APIArgument("environment", "[String: String]", "every context var as PP_<NAME>"),
                    APIArgument("timeout", "TimeInterval", "“timeout” param (seconds, default 30)"),
                ],
                returns: "trimmed stdout → out var (non-zero exit / timeout ⇒ stage error with stderr)",
                docPath: "foundation/process")],
            keywords: ["shell", "zsh", "script", "command", "stdin", "stdout"]),
    ]

    // MARK: Planned operations (PRD §5.4.1 — documented + searchable, not yet executable)

    private static let planned: [APICatalogEntry] = [
        APICatalogEntry(
            op: nil, plannedKey: "ocrText", name: "Recognize text (OCR)",
            framework: "Vision",
            summary: "Vision-backed text recognition from an image input (path/URL).",
            status: .planned, portability: .universal,
            calls: [APICall(
                symbol: "RecognizeTextRequest",
                signature: "perform(on:) async throws",
                args: [APIArgument("on", "URL · CGImage", "input wire (image path)")],
                returns: "[RecognizedTextObservation] → recognized text",
                docPath: "vision/recognizetextrequest")],
            keywords: ["ocr", "vision", "image", "text recognition"]),

        APICatalogEntry(
            op: nil, plannedKey: "readBarcode", name: "Read barcode / QR",
            framework: "Vision",
            summary: "Decode barcodes and QR codes from an image input.",
            status: .planned, portability: .universal,
            calls: [APICall(
                symbol: "DetectBarcodesRequest",
                signature: "perform(on:) async throws",
                args: [APIArgument("on", "URL · CGImage", "input wire (image path)")],
                returns: "[BarcodeObservation] → payloadString",
                docPath: "vision/detectbarcodesrequest")],
            keywords: ["barcode", "qr", "vision", "scan", "decode"]),

        APICatalogEntry(
            op: nil, plannedKey: "spotlightSearch", name: "Spotlight search",
            framework: "CoreSpotlight",
            summary: "Semantic document search against the device's Spotlight index — RAG-style retrieval.",
            status: .planned, portability: .universal,
            calls: [APICall(
                symbol: "CSUserQuery",
                signature: "init(userQueryString:userQueryContext:) · responses",
                args: [APIArgument("userQueryString", "String", "input wire (the query)")],
                returns: "matching items / snippets",
                docPath: "corespotlight/csuserquery")],
            keywords: ["spotlight", "search", "index", "rag", "retrieval", "semantic"]),

        APICatalogEntry(
            op: nil, plannedKey: "evaluate", name: "Evaluate (model judge)",
            framework: "FoundationModels",
            summary: "Apple's evaluation primitives — string-similarity matcher or on-device model judge — as a graph node (the Lab's evaluators stay separate).",
            status: .planned, portability: .universal,
            calls: [APICall(
                symbol: "ModelJudgeEvaluator",
                signature: "WWDC 2026 Evaluations framework",
                args: [APIArgument("target", "String", "input wire (value to score)")],
                returns: "score + rationale",
                docPath: "foundationmodels")],
            keywords: ["evaluate", "judge", "score", "similarity", "eval"]),
    ]
}

// MARK: - Per-node API mapping (the inspector's "API mapping" section, every node kind)

extension APICatalog {

    /// The Apple API call(s) `node` performs, each argument mapped to the GUI control / wire that
    /// feeds it — with live current values where they exist (UX-First §4.2: a developer always
    /// knows which control tunes which argument). Empty for pure data sources.
    static func calls(for node: GraphNode, graph: GraphDef) -> [APICall] {
        switch node.kind {
        case .input, .compare:
            return []   // data source / app-level reference node — no backing Apple API

        case .promptGroup:
            let memberCount = graph.members(of: node.id).count
            return [APICall(
                symbol: "Transcript",
                signature: "init(entries:)",
                args: [APIArgument("entries", "[Transcript.Entry]",
                                   "\(memberCount) member block(s), top→bottom — instructions · history · current turn")],
                returns: "the request — leading entries seed the session; the trailing prompt entry is the live turn",
                docPath: "foundationmodels/transcript")]

        case .instruction:
            return [APICall(
                symbol: "Transcript.Instructions",
                signature: "init(segments:toolDefinitions:)",
                args: [APIArgument("segments", "[Transcript.Segment]",
                                   "this block's text (+ few-shot + tool blocks, folded by the group)")],
                docPath: "foundationmodels/transcript/instructions")]

        case .fewshot:
            let n = node.fewshot?.shots.count ?? 0
            return [APICall(
                symbol: "Transcript.Instructions",
                signature: "labeled User/Assistant examples",
                args: [APIArgument("segments", "[Transcript.Segment]", "\(n) example pair(s), appended to the instructions text")],
                docPath: "foundationmodels/transcript/instructions",
                note: "v1 folds examples into the instructions entry — not separate prompt/response entries.")]

        case .history:
            let isHuman = (node.history?.role ?? .human) == .human
            return [APICall(
                symbol: isHuman ? "Transcript.Prompt" : "Transcript.Response",
                signature: isHuman ? "init(segments:)" : "init(assetIDs:segments:)",
                args: [
                    APIArgument("segments", "[Transcript.Segment]", "this block's content (resolved {{vars}})"),
                    APIArgument("role", "Entry", "Role picker — \(isHuman ? "Human → .prompt" : "AI → .response") entry"),
                ],
                docPath: "foundationmodels/transcript")]

        case .current:
            return [APICall(
                symbol: "LanguageModelSession",
                signature: "respond(to:options:)",
                args: [APIArgument("to", "String", "this template, resolved (recorded as the trailing Transcript.Prompt entry)")],
                docPath: "foundationmodels/languagemodelsession")]

        case .guided:
            let name = node.guided?.schemaDef?.typeName ?? "—"
            return [APICall(
                symbol: "DynamicGenerationSchema",
                signature: "GenerationSchema(root:dependencies:) → respond(to:schema:includeSchemaInPrompt:options:)",
                args: [
                    APIArgument("root", "DynamicGenerationSchema", "this schema tree (root “\(name)”)"),
                    APIArgument("includeSchemaInPrompt", "Bool", "fixed — true"),
                    APIArgument("responseFormat", "Transcript.ResponseFormat", "recorded on the prompt entry"),
                ],
                returns: "GeneratedContent (constrained decoding — token masking to schema-valid tokens)",
                docPath: "foundationmodels/dynamicgenerationschema")]

        case .tool:
            return [APICall(
                symbol: "Transcript.ToolDefinition",
                signature: "init(name:description:parameters:)",
                args: [
                    APIArgument("name", "String", "Name field"),
                    APIArgument("description", "String", "Description field"),
                ],
                docPath: "foundationmodels/transcript/tooldefinition",
                note: "v1 renders the tool as instructions text — a callable Tool needs compile-time Swift (Tool protocol).")]

        case .fm:
            let config = node.fm?.config ?? GenConfig()
            let group = graph.promptGroupID(feeding: node.id).flatMap { graph.node($0) }
            let groupName = group.map { $0.title.isEmpty ? "Prompt" : $0.title } ?? "(not wired)"
            let guided = group.flatMap { g in graph.members(of: g.id).first { $0.kind == .guided }?.guided?.schemaDef }
            let respond: APICall = guided.map { def in
                APICall(symbol: "LanguageModelSession",
                        signature: "respond(to:schema:includeSchemaInPrompt:options:)",
                        args: [
                            APIArgument("to", "String", "“\(groupName)” current turn"),
                            APIArgument("schema", "GenerationSchema", "Guided output “\(def.typeName)”"),
                            APIArgument("includeSchemaInPrompt", "Bool", "fixed — true"),
                            APIArgument("options", "GenerationOptions", "Sampling tab (below)"),
                        ],
                        returns: "Response<GeneratedContent> → output · json · transcript ports",
                        docPath: "foundationmodels/languagemodelsession")
            } ?? APICall(symbol: "LanguageModelSession",
                         signature: "respond(to:options:)",
                         args: [
                             APIArgument("to", "String", "“\(groupName)” current turn"),
                             APIArgument("options", "GenerationOptions", "Sampling tab (below)"),
                         ],
                         returns: "Response<String> → output · transcript ports",
                         docPath: "foundationmodels/languagemodelsession")
            return [
                APICall(symbol: "LanguageModelSession",
                        signature: "init(model:tools:transcript:)",
                        args: [
                            APIArgument("model", "SystemLanguageModel", "fixed — .default (on-device Apple Intelligence)"),
                            APIArgument("transcript", "Transcript", "“\(groupName)” — instructions + history (fresh session per run; append-only seeding preserves the KV cache)"),
                        ],
                        docPath: "foundationmodels/languagemodelsession"),
                respond,
                APICall(symbol: "GenerationOptions",
                        signature: "init(sampling:temperature:maximumResponseTokens:)",
                        args: [
                            APIArgument("sampling", "SamplingMode", samplingSource(config)),
                            APIArgument("temperature", "Double?",
                                        "Temperature control — " + (config.temperature.map { String(format: "%.2g", $0) } ?? "model default")),
                            APIArgument("maximumResponseTokens", "Int?",
                                        "Max tokens field — " + (config.maximumResponseTokens.map(String.init) ?? "unlimited")),
                        ],
                        docPath: "foundationmodels/generationoptions"),
            ]

        case .nativeAPI, .hook:
            guard let op = node.hook?.op, let entry = entry(for: op) else { return [] }
            return entry.calls
        }
    }

    private static func samplingSource(_ config: GenConfig) -> String {
        switch config.sampling {
        case .default: return "Sampling picker — model default"
        case .greedy:  return "Sampling picker — .greedy"
        case .topK:    return "Sampling picker — .random(top: \(config.topK ?? 50)\(config.seed.map { ", seed: \($0)" } ?? ""))"
        case .nucleus: return "Sampling picker — .random(probabilityThreshold: \(config.probabilityThreshold ?? 0.9)\(config.seed.map { ", seed: \($0)" } ?? ""))"
        }
    }
}
