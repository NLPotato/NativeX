//
//  Roleplay.swift
//  Prompt Playground
//
//  Built-in TEST TASK — spoken role-play. The typed @Generable shipping schema plus the scripted
//  multi-turn runners, input shape, scaffold, and objective evaluator, all under one `Roleplay`
//  namespace so the generic ops core stays task-agnostic. A fixture, not core.
//  NO #Playground block — Xcode auto-runs those and crashes/re-instantiates the model.
//

import Foundation
import FoundationModels

enum Roleplay {

    // MARK: - Input
    struct Input: Codable, Equatable, Sendable {
        var learning: String
        var native: String
        var situation: String
        var youRole: String
        var aiRole: String
        /// Drives the conversation headlessly. When exhausted (or empty) the runner auto-picks the
        /// first suggestion so a scene can still be exercised over several turns.
        var scriptedUserTurns: [String]
        /// Total AI turns to generate, including the opening turn.
        var maxTurns: Int
    }

    // MARK: - @Generable schema (the typed shipping shape)
    // Runtime DynamicGenerationSchema CAN express nested objects / arrays-of-objects too — see
    // docs/reference/foundation-models.md — but the typed lane keeps the tappable suggestions + typed
    // metrics, so it stays the default.

    @Generable(description: "One spoken line of dialogue, with a translation")
    struct LineGen: Codable {
        @Guide(description: "What is said, written in the language the user is learning")        var text: String
        @Guide(description: "A natural translation of the line into the user's native language") var translation: String
    }

    @Generable(description: "The character's reply plus suggested things the user could say next")
    struct TurnGen: Codable {
        // Grounded field first (declaration order biases generation).
        @Guide(description: "What you (the character the user is talking to) say now — in the learning language, staying in role and moving the scene forward") var reply: LineGen
        // Soft-targeted at two via the description (not a hard `.count(2)`, which would fail a
        // whole turn on a stray 1 or 3) — matches what ships to wiekant.
        @Guide(description: "Exactly two natural things the user could say next, in the learning language, fitting their role")                                  var suggestions: [LineGen]
    }

    // MARK: - Scaffold
    static let opening = "Begin the conversation now: greet the user and speak first, in character."

    /// Mirrors wiekant's buildRoleplayInstructions. Placeholders map to the role-play scene Inputs
    /// ({{learning}}/{{native}}/{{situation}}/{{you}}/{{ai}}). Also seeds the Lab's "Role-play baseline"
    /// template (SeedData).
    static let defaultInstructions = """
    You are running a spoken role-play to help someone practice {{learning}}. Their native language is {{native}}.
    Scene: {{situation}}.
    You always play: {{ai}}. The user always plays: {{you}}.
    Stay in character. Speak only in {{learning}}, naturally and briefly — one short turn at a time, suited to a learner.
    Each turn, give what you say (in {{learning}}) with a {{native}} translation, plus two short, natural things the user could say next (in {{learning}}) each with a {{native}} translation.
    """

    // MARK: - Template resolution
    static func resolve(_ template: String, _ input: Input) -> String {
        template
            .replacingOccurrences(of: "{{learning}}", with: input.learning)
            .replacingOccurrences(of: "{{native}}", with: input.native)
            .replacingOccurrences(of: "{{situation}}", with: input.situation)
            .replacingOccurrences(of: "{{you}}", with: input.youRole)
            .replacingOccurrences(of: "{{ai}}", with: input.aiRole)
    }

    // MARK: - Metrics
    struct Metrics: Codable, Equatable, Sendable {
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

    // MARK: - Objective evaluator
    /// Metrics aggregated across the turns of one Run. `peakContext` is the worst-case estimated
    /// context size seen across turns; `hitLimit` flags an exceededContextWindowSize.
    static func evaluate(_ turns: [TurnGen], learning: String, native: String,
                         peakContext: Int, hitLimit: Bool) -> (Metrics, onTargetLanguage: Double?) {
        let n = max(turns.count, 1)
        let twoSuggestions = turns.filter { $0.suggestions.count == 2 }.count
        let distinct = turns.filter { Evaluators.distinctTexts($0.suggestions.map(\.text)) }.count

        let replies = turns.map(\.reply.text)
        let suggestionTexts = turns.flatMap { $0.suggestions.map(\.text) }
        let translations = (turns.map(\.reply.translation) + turns.flatMap { $0.suggestions.map(\.translation) })

        let replyLang = LanguageTools.matchScore(replies, expected: learning) ?? 0
        let suggLang = LanguageTools.matchScore(suggestionTexts, expected: learning) ?? 0
        let transPresent = translations.isEmpty ? 0 :
            Double(translations.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count) / Double(translations.count)
        let avgReply = replies.isEmpty ? 0 : Double(replies.map(\.count).reduce(0, +)) / Double(replies.count)

        let combinedLang = LanguageTools.matchScore(replies + suggestionTexts, expected: learning)

        let m = Metrics(turnCount: turns.count,
                        suggestionCountOK: Double(twoSuggestions) / Double(n),
                        distinctSuggestions: Double(distinct) / Double(n),
                        replyLangOK: replyLang, suggestionsLangOK: suggLang,
                        translationPresent: transPresent, avgReplyChars: avgReply,
                        peakContextTokensEst: peakContext, hitContextLimit: hitLimit)
        return (m, combinedLang)
    }

    // MARK: - Headless runner (typed lane, scripted multi-turn)
    @MainActor
    enum Runner {
        static func run(template: String, input: Input, config: GenConfig) async -> RunResultData {
            let resolved = Roleplay.resolve(template, input)
            let session = LanguageModelSession(instructions: resolved)
            let options = config.toOptions()

            var turns: [TurnGen] = []
            var peakContext = 0
            var hitLimit = false
            var errorText: String?
            var totalLatency = 0
            var scriptIndex = 0
            let maxTurns = max(1, input.maxTurns)
            var stages: [RunTrace.Stage] = [
                .variables(ctx: ["learning": input.learning, "native": input.native, "situation": input.situation,
                                 "you": input.youRole, "ai": input.aiRole],
                           keys: ["learning", "native", "situation", "you", "ai"]),
                .prompt(instructions: resolved, prompt: Roleplay.opening, schemaInjected: true),
            ]

            for turnNo in 0..<maxTurns {
                // Decide the user's input for this turn.
                let userText: String
                if turnNo == 0 {
                    userText = Roleplay.opening
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
                                                             generating: TurnGen.self,
                                                             includeSchemaInPrompt: true,
                                                             options: options)
                    let turnMs = millis(since: start)
                    totalLatency += turnMs
                    turns.append(response.content)
                    stages.append(.turn(turnNo + 1, body: prettyJSON(response.content), ms: turnMs))
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

            let (roleplay, lang) = Roleplay.evaluate(turns, learning: input.learning, native: input.native,
                                                     peakContext: peakContext, hitLimit: hitLimit)
            let turnsJSON = prettyJSON(turns)
            let metrics = RunMetrics(
                decoded: true, errorType: hitLimit ? "contextWindow" : nil, latencyMs: totalLatency,
                promptTokensEst: TokenEstimator.estimate(resolved),
                outputTokensEst: TokenEstimator.estimate(turnsJSON),
                contextTokensEst: peakContext, contextHeadroom: TokenEstimator.headroom(peakContext),
                onTargetLanguage: lang, gloss: nil, roleplay: roleplay)
            return RunResultData(outputJSON: prettyJSON(turns[turns.count - 1]), turnsJSON: turnsJSON,
                                 errorText: errorText, metrics: metrics, trace: RunTrace(stages: stages))
        }
    }

    // MARK: - Dynamic-lane runner (custom SchemaDef)
    @MainActor
    static func runDynamic(template: String, input: Input, def: SchemaDef, config: GenConfig) async -> RunResultData {
        let resolved = Roleplay.resolve(template, input)
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
        var stages: [RunTrace.Stage] = [
            .variables(ctx: ["learning": input.learning, "native": input.native, "situation": input.situation,
                             "you": input.youRole, "ai": input.aiRole],
                       keys: ["learning", "native", "situation", "you", "ai"]),
            .prompt(instructions: resolved, prompt: Roleplay.opening, schemaInjected: true),
        ]

        for turnNo in 0..<maxTurns {
            let userText: String
            if turnNo == 0 {
                userText = Roleplay.opening
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
                let turnMs = millis(since: start)
                totalLatency += turnMs
                lastContent = content
                let turnJSON = prettyJSONString(content.jsonString)
                turnJSONs.append(turnJSON)
                stages.append(.turn(turnNo + 1, body: turnJSON, ms: turnMs))
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
        let metrics = RunEvaluator.metrics(json: turnJSONs.joined(separator: "\n"), decoded: true,
                                           latencyMs: totalLatency, resolvedPrompt: resolved,
                                           expectedLanguage: input.learning, context: peakContext)
        return RunResultData(outputJSON: prettyJSONString(last.jsonString), turnsJSON: turnsJSON,
                             errorText: errorText, metrics: metrics, trace: RunTrace(stages: stages))
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
