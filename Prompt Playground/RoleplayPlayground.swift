//
//  RoleplayPlayground.swift
//  Prompt Playground
//
//  Multi-turn role-play test bench: the nested @Generable schema + a persistent-session
//  engine. Unlike GlossPlayground (a fresh session per run), RoleplayModel keeps ONE
//  LanguageModelSession alive across turns so the model has the full dialogue as context.
//  NO #Playground block — drive everything from the SwiftUI app (Role-play tab).
//

import Foundation
import Observation
import FoundationModels

// MARK: - @Generable schema
// The typed shipping schema. (Runtime DynamicGenerationSchema CAN express nested objects /
// arrays-of-objects too — see docs/reference/foundation-models.md — but the typed lane keeps the
// tappable suggestions + typed metrics, so it stays the default.) File scope, app target.

@Generable(description: "One spoken line of dialogue, with a translation")
struct RoleplayLineGen: Codable {
    @Guide(description: "What is said, written in the language the user is learning")        var text: String
    @Guide(description: "A natural translation of the line into the user's native language") var translation: String
}

@Generable(description: "The character's reply plus suggested things the user could say next")
struct RoleplayTurnGen: Codable {
    // Grounded field first (declaration order biases generation).
    @Guide(description: "What you (the character the user is talking to) say now — in the learning language, staying in role and moving the scene forward") var reply: RoleplayLineGen
    // Soft-targeted at two via the description (not a hard `.count(2)`, which would fail a
    // whole turn on a stray 1 or 3) — matches what ships to wiekant.
    @Guide(description: "Exactly two natural things the user could say next, in the learning language, fitting their role")                                  var suggestions: [RoleplayLineGen]
}

// MARK: - Transcript

/// One generated turn, kept in the dialogue log for rendering.
struct Turn: Identifiable {
    let id = UUID()
    let userText: String?      // nil = the opening turn (the character speaks first)
    let result: RoleplayTurnGen?   // nil = custom-schema turn (render `raw` JSON instead)
    let raw: String            // pretty JSON, to confirm the nested output decoded
    let elapsed: Double
}

// Pretty-JSON encoding now lives in PlaygroundCore.swift (shared `prettyJSON`).

// MARK: - Engine

@MainActor
@Observable
final class RoleplayModel {
    // Scene inputs — empty by default (NO baked-in test content); entered in the form.
    var learning: String = ""
    var native: String = ""
    var situation: String = ""
    var youRole: String = ""
    var aiRole: String = ""

    /// Editable system-prompt scaffold; {{...}} placeholders are resolved at start().
    var instructions: String = RoleplayModel.defaultInstructions

    // Live session state, surfaced in the view.
    var resolvedInstructions: String = ""
    var turns: [Turn] = []
    var replyText: String = ""
    var errorText: String?
    var isRunning: Bool = false

    // Generation config (additive) + the dynamic-schema prototyping lane.
    var config = GenConfig()
    var useCustomSchema = false
    var customSchema: SchemaDef = .roleplayLike

    /// The one session kept alive across turns (nil until start()).
    private var session: LanguageModelSession?

    /// Mirrors wiekant's buildRoleplayInstructions. Placeholders map to the 5 form fields.
    static let defaultInstructions = """
    You are running a spoken role-play to help someone practice {{learning}}. Their native language is {{native}}.
    Scene: {{situation}}.
    You always play: {{ai}}. The user always plays: {{you}}.
    Stay in character. Speak only in {{learning}}, naturally and briefly — one short turn at a time, suited to a learner.
    Each turn, give what you say (in {{learning}}) with a {{native}} translation, plus two short, natural things the user could say next (in {{learning}}) each with a {{native}} translation.
    """

    var hasStarted: Bool { session != nil }

    /// A role-play needs every slot filled before it can begin.
    var canStart: Bool {
        ![learning, native, situation, youRole, aiRole]
            .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var isModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Non-nil when the model can't run; explains why.
    var availabilityMessage: String? {
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

    /// Open one persistent session from the resolved scaffold and run the opening turn
    /// (the character speaks first — no user input yet).
    func start() async {
        guard !isRunning, session == nil else { return }
        errorText = nil
        turns = []

        let resolved = instructions
            .replacingOccurrences(of: "{{learning}}", with: learning)
            .replacingOccurrences(of: "{{native}}", with: native)
            .replacingOccurrences(of: "{{situation}}", with: situation)
            .replacingOccurrences(of: "{{you}}", with: youRole)
            .replacingOccurrences(of: "{{ai}}", with: aiRole)
        resolvedInstructions = resolved

        let s = LanguageModelSession(instructions: resolved)
        s.prewarm()
        session = s
        await runTurn(userText: nil)
    }

    /// Send the typed reply as the next user turn.
    func send() async {
        let text = replyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        replyText = ""
        await runTurn(userText: text)
    }

    /// Send a tapped suggestion as the next user turn.
    func send(suggestion: String) async {
        await runTurn(userText: suggestion)
    }

    /// Tear down the session so a fresh scene can be started.
    func reset() {
        session = nil
        turns = []
        replyText = ""
        errorText = nil
        resolvedInstructions = ""
    }

    /// One Foundation Models call on the SAME session. A nil userText opens the scene.
    private func runTurn(userText: String?) async {
        guard let session, !isRunning, !session.isResponding else { return }
        errorText = nil
        isRunning = true
        defer { isRunning = false }

        let prompt = userText ?? "Begin the conversation now: greet the user and speak first, in character."
        let start = Date()
        do {
            if useCustomSchema {
                let content = try await DynamicRun.respond(session: session, prompt: prompt,
                                                           def: customSchema, options: config.toOptions())
                turns.append(Turn(userText: userText, result: nil,
                                  raw: prettyJSONString(content.jsonString),
                                  elapsed: Date().timeIntervalSince(start)))
            } else {
                let turn = try await session.respond(
                    to: prompt,
                    generating: RoleplayTurnGen.self,
                    includeSchemaInPrompt: true,
                    options: config.toOptions()
                ).content
                turns.append(Turn(userText: userText, result: turn,
                                  raw: prettyJSON(turn),
                                  elapsed: Date().timeIntervalSince(start)))
            }
        } catch let error as LanguageModelSession.GenerationError {
            // Long dialogues can blow the context window — recover by resetting the scene.
            if case .exceededContextWindowSize = error {
                errorText = "The dialogue got too long for the model's context window. Press Reset to start a new scene."
            } else {
                errorText = "Generation failed: \(error.localizedDescription)"
            }
        } catch let e as SchemaWalker.ValidationError {
            errorText = "Schema error: \(e.localizedDescription)"
        } catch {
            errorText = "Generation failed: \(error.localizedDescription)"
        }
    }
}
