//
//  DynamicRunner.swift
//  Prompt Playground
//
//  Headless run engines for the DYNAMIC lane (a custom SchemaDef) — the pipeline's counterpart to
//  GlossRunner/RoleplayRunner. Same session setup and template resolution (shared helpers from
//  Runners.swift), but generates against a runtime GenerationSchema and scores with the
//  schema-agnostic GenericEvaluator (the typed Evaluators need the concrete @Generable).
//

import Foundation
import FoundationModels

@MainActor
enum DynamicRunner {
    static func runGloss(template: String, input: GlossInput, def: SchemaDef, config: GenConfig) async -> RunResultData {
        let resolved = resolveGloss(template, input)
        let userPrompt = "Sentence: \(input.sentence)"
        let session = LanguageModelSession(instructions: resolved)
        let start = Date()
        do {
            let content = try await DynamicRun.respond(session: session, prompt: userPrompt,
                                                       def: def, options: config.toOptions())
            let latency = millis(since: start)
            let outputJSON = prettyJSONString(content.jsonString)
            let context = TokenEstimator.estimate(session.transcript)
            let metrics = GenericEvaluator.metrics(json: outputJSON, decoded: true, latencyMs: latency,
                                                   resolvedPrompt: resolved + "\n" + userPrompt,
                                                   expectedLanguage: input.native, context: context)
            return RunResultData(outputJSON: outputJSON, turnsJSON: nil, errorText: nil, metrics: metrics)
        } catch {
            let (type, text) = classify(error)
            return RunResultData(outputJSON: "", turnsJSON: nil, errorText: text,
                                 metrics: .failure(type, latencyMs: millis(since: start)))
        }
    }

    /// Generic lane with a custom output schema: pre-hooks → resolve → dynamic respond → post-hooks.
    /// Metrics are scored on the RAW model JSON; the stored output reflects any post-hook transform.
    static func runGeneric(template: String, input: GenericInput, def: SchemaDef, config: GenConfig,
                           hooks: HookPipelineDef) async -> RunResultData {
        var ctx = input.variables
        ctx["input"] = input.input
        _ = await HookEngine.runPre(hooks.pre, context: &ctx)
        let resolvedInstructions = resolveGeneric(template, ctx)
        let userPrompt = resolveGeneric(input.input, ctx)
        let session = LanguageModelSession(instructions: resolvedInstructions)
        let start = Date()
        do {
            let content = try await DynamicRun.respond(session: session, prompt: userPrompt,
                                                       def: def, options: config.toOptions())
            let raw = prettyJSONString(content.jsonString)
            let (final, _) = await HookEngine.runPost(hooks.post, output: raw, context: ctx)
            let latency = millis(since: start)
            let contextTokens = TokenEstimator.estimate(session.transcript)
            let metrics = GenericEvaluator.metrics(
                json: raw, decoded: true, latencyMs: latency,
                resolvedPrompt: resolvedInstructions + "\n" + userPrompt,
                expectedLanguage: ctx["native"] ?? ctx["learning"] ?? "", context: contextTokens)
            return RunResultData(outputJSON: final, turnsJSON: nil, errorText: nil, metrics: metrics)
        } catch {
            let (type, text) = classify(error)
            return RunResultData(outputJSON: "", turnsJSON: nil, errorText: text,
                                 metrics: .failure(type, latencyMs: millis(since: start)))
        }
    }

    static func runRoleplay(template: String, input: RoleplayInput, def: SchemaDef, config: GenConfig) async -> RunResultData {
        let resolved = resolveRoleplay(template, input)
        let session = LanguageModelSession(instructions: resolved)
        let options = config.toOptions()

        var turnJSONs: [String] = []
        var lastContent: GeneratedContent?
        var peakContext = 0
        var hitLimit = false
        var errorText: String?
        var totalLatency = 0
        var scriptIndex = 0
        let maxTurns = max(1, input.maxTurns)

        for turnNo in 0..<maxTurns {
            let userText: String
            if turnNo == 0 {
                userText = RoleplayRunner.opening
            } else if scriptIndex < input.scriptedUserTurns.count {
                userText = input.scriptedUserTurns[scriptIndex]
                scriptIndex += 1
            } else if let next = lastContent.flatMap(firstSuggestionText) {
                userText = next                          // best-effort auto-advance (custom schema)
            } else {
                break
            }

            let start = Date()
            do {
                let content = try await DynamicRun.respond(session: session, prompt: userText,
                                                           def: def, options: options)
                totalLatency += millis(since: start)
                lastContent = content
                turnJSONs.append(prettyJSONString(content.jsonString))
                peakContext = max(peakContext, TokenEstimator.estimate(session.transcript))
            } catch let g as LanguageModelSession.GenerationError {
                totalLatency += millis(since: start)
                if case .exceededContextWindowSize = g {
                    hitLimit = true; errorText = "Context window exceeded at turn \(turnNo + 1)."
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

        guard let last = lastContent, !turnJSONs.isEmpty else {
            return RunResultData(outputJSON: "", turnsJSON: nil, errorText: errorText ?? "No turns produced.",
                                 metrics: .failure(hitLimit ? "contextWindow" : "generation", latencyMs: totalLatency))
        }

        let turnsJSON = "[\n" + turnJSONs.joined(separator: ",\n") + "\n]"
        let metrics = GenericEvaluator.metrics(json: turnJSONs.joined(separator: "\n"), decoded: true,
                                               latencyMs: totalLatency, resolvedPrompt: resolved,
                                               expectedLanguage: input.learning, context: peakContext)
        return RunResultData(outputJSON: prettyJSONString(last.jsonString), turnsJSON: turnsJSON,
                             errorText: errorText, metrics: metrics)
    }

    /// Best-effort read of suggestions[0].text from a GeneratedContent (for auto-advance). Returns
    /// nil if the custom schema has no such shape — the loop then stops after the scripted turns.
    private static func firstSuggestionText(_ content: GeneratedContent) -> String? {
        guard case .structure(let props, _) = content.kind,
              let suggestions = props["suggestions"],
              case .array(let items) = suggestions.kind,
              let first = items.first else { return nil }
        switch first.kind {
        case .string(let s): return s
        case .structure(let p, _):
            if case .string(let t)? = p["text"]?.kind { return t }
            return nil
        default: return nil
        }
    }
}
