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
}

func millis(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

func classify(_ error: Error) -> (type: String, text: String) {
    if let g = error as? LanguageModelSession.GenerationError {
        if case .exceededContextWindowSize = g { return ("contextWindow", "Context window exceeded.") }
        return ("generation", g.localizedDescription)
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
