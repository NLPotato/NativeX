//
//  Runners.swift
//  Prompt Playground
//
//  The generic, task-agnostic run engine for the Lab (batch eval). `RunPipeline` is the shared
//  execution spine — seed ctx → pre-hooks → resolve → STREAM the model (capturing TTFT + tokens/sec)
//  → post-hooks → assemble a RunTrace + metrics — and `TextRunner` is the free-text entry point.
//  Built-in test tasks (Gloss, Roleplay) bring their own runners under their namespaces.
//

import Foundation
import FoundationModels

/// One headless run's payload, ready to persist as a RunModel.
struct RunResultData {
    var outputJSON: String       // last/only generated output, pretty JSON
    var turnsJSON: String?       // multi-turn: all turns, pretty JSON
    var errorText: String?
    var metrics: RunMetrics
    var trace: RunTrace? = nil   // staged pipeline view (generic lane); nil for the typed task lanes
}

func millis(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

/// Estimated decoding throughput: output tokens (estimated — Apple exposes no token API) over the
/// generation wall-clock. nil when there's nothing to measure.
func tokensPerSec(_ output: String, ms: Int) -> Double? {
    guard ms > 0 else { return nil }
    let toks = TokenEstimator.estimate(output)
    guard toks > 0 else { return nil }
    return Double(toks) / (Double(ms) / 1000.0)
}

/// Map a thrown error to a first-class run outcome. Covers the full FoundationModels
/// GenerationError taxonomy (verified against the SDK swiftinterface) so the Lab can surface
/// guardrail / unsupported-language / decoding / refusal outcomes, not just "generation failed".
func classify(_ error: Error) -> (type: String, text: String) {
    if let g = error as? LanguageModelSession.GenerationError {
        let type: String
        switch g {
        case .exceededContextWindowSize:   type = "contextWindow"
        case .guardrailViolation:          type = "guardrail"
        case .unsupportedLanguageOrLocale: type = "unsupportedLanguage"
        case .unsupportedGuide:            type = "unsupportedGuide"
        case .decodingFailure:             type = "decoding"
        case .rateLimited:                 type = "rateLimited"
        case .concurrentRequests:          type = "concurrentRequests"
        case .assetsUnavailable:           type = "assets"
        case .refusal:                     type = "refusal"
        @unknown default:                  type = "generation"
        }
        return (type, g.localizedDescription)
    }
    return ("other", error.localizedDescription)
}

/// Resolve every `{{name}}` against the full variable map (no fixed token set).
func resolveVars(_ template: String, _ vars: [String: String]) -> String {
    Vars.substitute(template, vars)
}

// MARK: - Run pipeline (the generic execution spine)
// One spine — seed ctx → pre-hooks → resolve → STREAM the model (capturing TTFT + tokens/sec) →
// post-hooks → assemble a RunTrace + metrics — shared by the text lane (TextRunner) and the
// custom-schema lane (DynamicRunner.run), so a Lab run traces exactly like the Graph executor.

@MainActor
enum RunPipeline {
    /// The model call: given a session + resolved prompt, returns the raw output, TTFT, and gen time.
    /// Text lane streams a String; schema lane streams GeneratedContent snapshots (see callers).
    typealias Generate = (LanguageModelSession, String) async throws -> (raw: String, ttftMs: Int?, ms: Int)

    static func run(template: String, input: RunInput, config: GenConfig, hooks: HookPipelineDef,
                    prewarm: Bool, schemaInjected: Bool, expectedLanguageKeys: [String],
                    generate: Generate) async -> RunResultData {
        var stages: [RunTrace.Stage] = []
        var ctx = input.variables
        ctx["prompt"] = input.input
        ctx["input"] = input.input   // legacy alias for {{input}}
        let varKeys = PromptAnalysis.variableKeys(instructions: template, input: input.input, hooks: hooks)
        stages.append(.variables(ctx: ctx, keys: varKeys + ["prompt"]))

        for hook in hooks.pre where hook.enabled {           // pre-hooks, one trace stage each
            let step = await HookEngine.runOne(hook, context: &ctx)
            stages.append(.preHook(hook, step))
        }

        let resolvedInstructions = resolveVars(template, ctx)
        let userPrompt = resolveVars(input.input, ctx)
        stages.append(.prompt(instructions: resolvedInstructions, prompt: userPrompt, schemaInjected: schemaInjected))

        let session = LanguageModelSession(instructions: resolvedInstructions)
        if prewarm { session.prewarm() }
        let start = Date()
        do {
            let (raw, ttftMs, genMs) = try await generate(session, userPrompt)
            let tps = tokensPerSec(raw, ms: genMs)
            stages.append(.model(output: raw, ms: genMs, ttftMs: ttftMs, tokensPerSec: tps, schemaInjected: schemaInjected))

            var finalOut = raw                               // post-hooks thread the output through
            var postCtx = ctx
            postCtx["output"] = raw
            let hasPost = hooks.post.contains { $0.enabled }
            for hook in hooks.post where hook.enabled {
                let step = await HookEngine.runOne(hook, context: &postCtx, defaultInput: finalOut)
                if let o = step.output { finalOut = o; postCtx["output"] = o }
                stages.append(.postHook(hook, step))
            }
            if hasPost { stages.append(.finalOutput(finalOut)) }

            let contextTokens = TokenEstimator.estimate(session.transcript)
            let expected = expectedLanguageKeys.lazy.compactMap { ctx[$0] }.first ?? ""
            // Score the RAW model output (wrapped for the text lane so the JSON-leaf scorer can read it).
            let metrics = RunEvaluator.metrics(
                json: schemaInjected ? raw : jsonWrap(raw), decoded: true, latencyMs: genMs,
                resolvedPrompt: resolvedInstructions + "\n" + userPrompt,
                expectedLanguage: expected, context: contextTokens, ttftMs: ttftMs, tokensPerSec: tps)
            return RunResultData(outputJSON: finalOut, turnsJSON: nil, errorText: nil,
                                 metrics: metrics, trace: RunTrace(stages: stages))
        } catch {
            let (type, text) = classify(error)
            stages.append(.modelError(text, ms: millis(since: start)))
            return RunResultData(outputJSON: "", turnsJSON: nil, errorText: text,
                                 metrics: .failure(type, latencyMs: millis(since: start)),
                                 trace: RunTrace(stages: stages))
        }
    }

    /// Plain text has no JSON leaves to language-score; wrap it so RunEvaluator can read one.
    static func jsonWrap(_ text: String) -> String { JSONCoder.encode(["output": text]) }
}

@MainActor
enum TextRunner {
    /// Free-text generic run: streams the String response (no schema).
    static func run(template: String, input: RunInput, config: GenConfig,
                    hooks: HookPipelineDef, prewarm: Bool = false) async -> RunResultData {
        await RunPipeline.run(template: template, input: input, config: config, hooks: hooks,
                              prewarm: prewarm, schemaInjected: false,
                              expectedLanguageKeys: ["learning", "native"]) { session, prompt in
            var raw = ""
            var ttft: Int? = nil
            let s = Date()
            for try await snapshot in session.streamResponse(to: prompt, options: config.toOptions()) {
                if ttft == nil { ttft = millis(since: s) }
                raw = snapshot.content                       // cumulative — last snapshot is complete
            }
            return (raw, ttft, millis(since: s))
        }
    }
}
