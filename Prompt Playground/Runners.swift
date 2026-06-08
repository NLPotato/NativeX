//
//  Runners.swift
//  Prompt Playground
//
//  Headless run engines used by the pipeline (the single-shot SwiftUI tabs keep their own
//  view-model engines). Each runner opens a FRESH session, resolves the template, calls the
//  model, and returns the output plus a fully-evaluated RunMetrics.
//
//  Gloss = one shot. Role-play = scripted multi-turn on ONE persistent session, so cumulative
//  context growth (the 4096-token risk) is actually exercised and measured.
//

import Foundation
import FoundationModels

/// One headless run's payload, ready to persist as a RunModel.
struct RunResultData {
    var outputJSON: String       // last/only generated @Generable, pretty JSON
    var turnsJSON: String?       // role-play: all turns, pretty JSON
    var errorText: String?
    var metrics: RunMetrics
    var trace: RunTrace? = nil   // staged pipeline view (generic lane); nil for the typed lanes
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

/// Resolve {{learning}}/{{native}} (canonical) plus legacy {{source}}/{{target}} aliases.
func resolveGloss(_ template: String, _ input: GlossInput, proficiency: String = "intermediate") -> String {
    template
        .replacingOccurrences(of: "{{learning}}", with: input.learning)
        .replacingOccurrences(of: "{{native}}", with: input.native)
        .replacingOccurrences(of: "{{source}}", with: input.learning)
        .replacingOccurrences(of: "{{target}}", with: input.native)
        .replacingOccurrences(of: "{{proficiency}}", with: proficiency)
}

func resolveRoleplay(_ template: String, _ input: RoleplayInput) -> String {
    template
        .replacingOccurrences(of: "{{learning}}", with: input.learning)
        .replacingOccurrences(of: "{{native}}", with: input.native)
        .replacingOccurrences(of: "{{situation}}", with: input.situation)
        .replacingOccurrences(of: "{{you}}", with: input.youRole)
        .replacingOccurrences(of: "{{ai}}", with: input.aiRole)
}

/// Generic lane: resolve every {{name}} against the full variable map (no fixed token set).
func resolveGeneric(_ template: String, _ vars: [String: String]) -> String {
    Vars.substitute(template, vars)
}

// MARK: - Gloss

@MainActor
enum GlossRunner {
    static func run(template: String, input: GlossInput, config: GenConfig,
                    proficiency: Proficiency = .intermediate) async -> RunResultData {
        let resolved = resolveGloss(template, input, proficiency: proficiency.rawValue)
        let start = Date()
        do {
            let out = try await GlossPipeline.run(sentence: input.sentence, learning: input.learning,
                                                  proficiency: proficiency, instructions: resolved, config: config)
            let latency = millis(since: start)
            let outputJSON = prettyJSON(out.result)
            let (gloss, lang) = Evaluators.gloss(out.result, sentence: input.sentence, native: input.native)
            // GlossPipeline owns its sessions, so estimate context from the resolved text instead of a transcript.
            let context = TokenEstimator.estimate(resolved + "\n" + out.promptSent + "\n" + outputJSON)
            let metrics = RunMetrics(
                decoded: true, errorType: nil, latencyMs: latency,
                promptTokensEst: TokenEstimator.estimate(resolved + "\n" + out.promptSent),
                outputTokensEst: TokenEstimator.estimate(outputJSON),
                contextTokensEst: context, contextHeadroom: TokenEstimator.headroom(context),
                onTargetLanguage: lang, gloss: gloss, roleplay: nil)
            return RunResultData(outputJSON: outputJSON, turnsJSON: nil, errorText: nil, metrics: metrics)
        } catch {
            let (type, text) = classify(error)
            return RunResultData(outputJSON: "", turnsJSON: nil, errorText: text,
                                 metrics: .failure(type, latencyMs: millis(since: start)))
        }
    }
}

// MARK: - Role-play (scripted multi-turn)

@MainActor
enum RoleplayRunner {
    static let opening = "Begin the conversation now: greet the user and speak first, in character."

    static func run(template: String, input: RoleplayInput, config: GenConfig) async -> RunResultData {
        let resolved = resolveRoleplay(template, input)
        let session = LanguageModelSession(instructions: resolved)
        let options = config.toOptions()

        var turns: [RoleplayTurnGen] = []
        var peakContext = 0
        var hitLimit = false
        var errorText: String?
        var totalLatency = 0
        var scriptIndex = 0
        let maxTurns = max(1, input.maxTurns)

        for turnNo in 0..<maxTurns {
            // Decide the user's input for this turn.
            let userText: String
            if turnNo == 0 {
                userText = opening
            } else if scriptIndex < input.scriptedUserTurns.count {
                userText = input.scriptedUserTurns[scriptIndex]
                scriptIndex += 1
            } else if let first = turns.last?.suggestions.first {
                userText = first.text   // auto-advance using the model's own suggestion
            } else {
                break
            }

            let start = Date()
            do {
                let response = try await session.respond(to: userText,
                                                         generating: RoleplayTurnGen.self,
                                                         includeSchemaInPrompt: true,
                                                         options: options)
                totalLatency += millis(since: start)
                turns.append(response.content)
                peakContext = max(peakContext, TokenEstimator.estimate(session.transcript))
            } catch let g as LanguageModelSession.GenerationError {
                totalLatency += millis(since: start)
                if case .exceededContextWindowSize = g {
                    hitLimit = true
                    errorText = "Context window exceeded at turn \(turnNo + 1)."
                } else {
                    errorText = "Generation failed: \(g.localizedDescription)"
                }
                break
            } catch {
                totalLatency += millis(since: start)
                errorText = "Generation failed: \(error.localizedDescription)"
                break
            }
        }

        guard !turns.isEmpty else {
            return RunResultData(outputJSON: "", turnsJSON: nil, errorText: errorText ?? "No turns produced.",
                                 metrics: .failure(hitLimit ? "contextWindow" : "generation", latencyMs: totalLatency))
        }

        let (roleplay, lang) = Evaluators.roleplay(turns, learning: input.learning, native: input.native,
                                                   peakContext: peakContext, hitLimit: hitLimit)
        let turnsJSON = prettyJSON(turns)
        let metrics = RunMetrics(
            decoded: true, errorType: hitLimit ? "contextWindow" : nil, latencyMs: totalLatency,
            promptTokensEst: TokenEstimator.estimate(resolved),
            outputTokensEst: TokenEstimator.estimate(turnsJSON),
            contextTokensEst: peakContext, contextHeadroom: TokenEstimator.headroom(peakContext),
            onTargetLanguage: lang, gloss: nil, roleplay: roleplay)
        return RunResultData(outputJSON: prettyJSON(turns[turns.count - 1]), turnsJSON: turnsJSON,
                             errorText: errorText, metrics: metrics)
    }
}

// MARK: - Generic pipeline (the genericized Gloss tab's batch counterpart)
// One spine — seed ctx → pre-hooks → resolve → STREAM the model (capturing TTFT + tokens/sec) →
// post-hooks → assemble a RunTrace + metrics — shared by the text lane (GenericRunner) and the
// custom-schema lane (DynamicRunner.runGeneric), so a Lab run traces exactly like Single-shot.

@MainActor
enum GenericPipeline {
    /// The model call: given a session + resolved prompt, returns the raw output, TTFT, and gen time.
    /// Text lane streams a String; schema lane streams GeneratedContent snapshots (see callers).
    typealias Generate = (LanguageModelSession, String) async throws -> (raw: String, ttftMs: Int?, ms: Int)

    static func run(template: String, input: GenericInput, config: GenConfig, hooks: HookPipelineDef,
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

        let resolvedInstructions = resolveGeneric(template, ctx)
        let userPrompt = resolveGeneric(input.input, ctx)
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
            let metrics = GenericEvaluator.metrics(
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

    /// Plain text has no JSON leaves to language-score; wrap it so GenericEvaluator can read one.
    static func jsonWrap(_ text: String) -> String { JSONCoder.encode(["output": text]) }
}

@MainActor
enum GenericRunner {
    /// Free-text generic run: streams the String response (no schema).
    static func run(template: String, input: GenericInput, config: GenConfig,
                    hooks: HookPipelineDef, prewarm: Bool = false) async -> RunResultData {
        await GenericPipeline.run(template: template, input: input, config: config, hooks: hooks,
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
