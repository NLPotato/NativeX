//
//  GlossPlayground.swift
//  Prompt Playground
//
//  Core of the Foundation Models test bench: @Generable schemas, the prompt-preset
//  registry, and the run engine. NO #Playground block — Xcode auto-runs those and
//  crashes/re-instantiates the model. Drive everything from the SwiftUI app instead.
//

import Foundation
import Observation
import FoundationModels

// MARK: - @Generable schemas
// Keep @Generable structs at file scope in the APP TARGET (the macro expands here).
// Codable conformance lets the output pane render them as JSON for schema checking.

@Generable(description: "One mined word from the sentence")
struct GlossWordGen: Codable {
    @Guide(description: "Word exactly as it appears in the sentence")        var surface: String
    @Guide(description: "Dictionary / base (lemma) form of the word")        var lemma: String
    @Guide(description: "Part of speech, e.g. noun, verb, adjective, adverb, particle") var partOfSpeech: String
    @Guide(description: "Translation of this word in the context into the target language") var translation: String
    @Guide(description: "Register or usage note (e.g. formal, slang), if relevant")     var register: String?
    @Guide(description: "A few synonyms in the target language, if any")     var synonyms: [String]?
}

@Generable(description: "Learning material extracted from a sentence")
struct GlossResultGen: Codable {
    @Guide(description: "Each meaningful word in the sentence, in order")             var words: [GlossWordGen]
    @Guide(description: "Translation of the whole sentence into the target language") var sentenceTranslation: String
    @Guide(description: "One or two short grammar notes about the sentence")          var grammarNotes: [String]
    @Guide(description: "A short example sentence using the same pattern, if helpful") var exampleSentence: String?
}

// MARK: - Preset registry
// A preset bundles a default instructions template with the typed run closure that
// generates its concrete @Generable and returns the prompt sent + structured output.
// To test a new schema: add a @Generable struct above + a PromptPreset entry here.

struct PromptPreset: Identifiable {
    let id: String
    let name: String
    /// Use {{source}} and {{target}} as placeholders; substituted from the form at run time.
    let defaultInstructions: String
    let run: (_ session: LanguageModelSession, _ sentence: String, _ options: GenerationOptions) async throws -> RunResult
}

/// One run's inputs/outputs, surfaced in the output pane for schema verification.
struct RunResult {
    /// The exact user prompt string sent to `respond(to:)`.
    let userPrompt: String
    /// Pretty-printed JSON of the generated @Generable, to compare against the schema.
    let structuredOutput: String
}

let presets: [PromptPreset] = [
    PromptPreset(
        id: "gloss",
        name: "Gloss",
        defaultInstructions: """
        You are a language-learning assistant for the {{target}} language. Given a sentence, \
        break it into its meaningful words. For each word give the dictionary (lemma) form, \
        its part of speech, and a translation into {{source}}. Then translate the whole \
        sentence into {{source}} and add one or two short grammar notes. Only analyze words \
        that actually appear; do not invent words.
        """,
        run: { session, sentence, options in
            let prompt = "Sentence: \(sentence)"
            let r = try await session.respond(
                to: prompt,
                generating: GlossResultGen.self,
                includeSchemaInPrompt: true,
                options: options
            ).content
            return RunResult(userPrompt: prompt, structuredOutput: prettyJSON(r))
        }
    )
]

// Pretty-JSON encoding now lives in PlaygroundCore.swift (shared `prettyJSON`).

// MARK: - Engine

@MainActor
@Observable
final class PlaygroundModel {
    var sentence: String = "Der Hund schläft."
    var source: String = "German"
    var target: String = "English"
    var selectedPresetID: String
    var instructions: String

    // Surfaced in the output pane after a run.
    var resolvedInstructions: String = ""
    var userPrompt: String = ""
    var output: String = ""
    var errorText: String?
    var isRunning: Bool = false
    var elapsed: Double?

    // Generation config (additive: was Pipeline-only) + the dynamic-schema prototyping lane.
    var config = GenConfig()
    var useCustomSchema = false
    var customSchema: SchemaDef = .glossLike

    init() {
        let first = presets[0]
        selectedPresetID = first.id
        instructions = first.defaultInstructions
    }

    var selectedPreset: PromptPreset {
        presets.first { $0.id == selectedPresetID } ?? presets[0]
    }

    /// Reset the editable instructions to the chosen preset's default template.
    func loadPresetDefaults(for id: String) {
        if let p = presets.first(where: { $0.id == id }) {
            instructions = p.defaultInstructions
        }
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

    func run() async {
        guard !isRunning else { return }
        errorText = nil
        output = ""
        resolvedInstructions = ""
        userPrompt = ""
        elapsed = nil
        isRunning = true
        defer { isRunning = false }

        let resolved = instructions
            .replacingOccurrences(of: "{{source}}", with: source)
            .replacingOccurrences(of: "{{target}}", with: target)
        resolvedInstructions = resolved

        // Fresh session per run so a prior run never biases the next (clean A/B testing).
        let preset = selectedPreset
        let start = Date()
        do {
            let session = LanguageModelSession(instructions: resolved)
            if useCustomSchema {
                let prompt = "Sentence: \(sentence)"
                userPrompt = prompt
                let content = try await DynamicRun.respond(session: session, prompt: prompt,
                                                           def: customSchema, options: config.toOptions())
                output = prettyJSONString(content.jsonString)
            } else {
                let result = try await preset.run(session, sentence, config.toOptions())
                userPrompt = result.userPrompt
                output = result.structuredOutput
            }
        } catch let e as SchemaWalker.ValidationError {
            errorText = "Schema error: \(e.localizedDescription)"
        } catch {
            errorText = "Generation failed: \(error.localizedDescription)"
        }
        elapsed = Date().timeIntervalSince(start)
    }
}
