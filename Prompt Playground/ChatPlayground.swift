//
//  ChatPlayground.swift
//  Prompt Playground
//
//  Chat-mode counterpart to the Single-shot (completion-mode) tab — the LangSmith chat playground
//  for Apple Foundation Models. The conversation is authored as an editable list of role-labeled
//  message blocks (SYSTEM / HUMAN / AI); every block is a {{var}} template filled from a shared
//  Inputs map. "Start" substitutes the whole list, rebuilds a Transcript, seeds a FRESH
//  LanguageModelSession(transcript:), and runs the same traced pipeline as Single-shot
//  (variables → pre-hooks → final prompt → model → post-hooks) to generate the next AI turn.
//
//  The old language-learning Role-play tab lives on as the "Language role-play" preset (typed
//  RoleplayTurnGen schema + scene variables + tappable suggestions). NO #Playground block.
//
//  Transcript-seeding API verified against the macOS 26 SDK swiftinterface:
//    LanguageModelSession(transcript:) · Transcript(entries:) ·
//    Transcript.Entry.{instructions,prompt,response} · Transcript.{Instructions,Prompt,Response} ·
//    Transcript.Segment.text(.init(content:))
//

import Foundation
import Observation
import FoundationModels

// MARK: - Message model

/// One editable turn in the authored conversation. NOT Codable — Save-to-Lab serializes a derived
/// RoleplayInput/GenericInput, never this live list. The per-turn `trace` reuses the Single-shot
/// PipelineStage so one renderer (StageCardView) draws the live chat trace and the Single-shot trace.
struct ChatMessage: Identifiable {
    enum Role: String, CaseIterable, Hashable { case system, human, ai }

    var id = UUID()
    var role: Role
    var content: String = ""        // the RAW template (with {{vars}}); resolution happens at run
    var collapsed: Bool = false

    // AI-turn run artifacts (unused on system/human blocks).
    var raw: String = ""                          // model JSON (typed/dynamic lanes)
    var result: RoleplayTurnGen? = nil            // typed role-play render (reply + suggestions)
    var trace: [PlaygroundModel.PipelineStage] = []
    var elapsed: Double? = nil
    var errorText: String? = nil
    var isStreaming: Bool = false
}

extension ChatMessage.Role {
    var label: String {
        switch self {
        case .system: return "SYSTEM"
        case .human:  return "HUMAN"
        case .ai:     return "AI"
        }
    }
}

// MARK: - Presets

/// A named starting point: the seed message blocks + how AI turns are generated. Two only —
/// generic plain chat, and the language role-play that used to be its own tab.
struct ChatPreset: Identifiable {
    let id: String
    let name: String
    let seedMessages: [ChatMessage]
    /// Generate AI turns with the typed `RoleplayTurnGen` schema (rich reply + tappable suggestions).
    var useTypedRoleplay: Bool = false
    /// The AI speaks first: when there are no human/ai blocks yet, Start runs an opening turn.
    var opensWithAI: Bool = false
}

let chatPresets: [ChatPreset] = [
    ChatPreset(
        id: "generic",
        name: "Generic chat",
        seedMessages: [
            ChatMessage(role: .system, content: "You are a helpful assistant."),
            ChatMessage(role: .human, content: ""),
        ]),
    ChatPreset(
        id: "roleplay",
        name: "Language role-play",
        seedMessages: [
            ChatMessage(role: .system, content: defaultRoleplayInstructions),
        ],
        useTypedRoleplay: true,
        opensWithAI: true),
]

// MARK: - Engine

@MainActor
@Observable
final class ChatModel {
    /// The authored conversation — the source of truth. SYSTEM is conventionally first.
    var messages: [ChatMessage]
    /// Global Inputs: values for every {{var}} referenced across the blocks (LangSmith's Inputs panel).
    var inputs: [String: String] = [:]
    var config = GenConfig()
    var hooks: HookPipelineDef = .empty
    var useCustomSchema = false
    var customSchema: SchemaDef = .roleplayLike
    var presetID: String
    var isRunning = false

    init() {
        let first = chatPresets[0]
        presetID = first.id
        messages = first.seedMessages
    }

    var preset: ChatPreset { chatPresets.first { $0.id == presetID } ?? chatPresets[0] }

    /// Generation lane for the next AI turn. A custom schema overrides the preset's typed schema.
    enum Mode { case plain, typedRoleplay, dynamic }
    var mode: Mode {
        if useCustomSchema { return .dynamic }
        if preset.useTypedRoleplay { return .typedRoleplay }
        return .plain
    }

    // MARK: Derived authoring state (reuses the shared PromptAnalysis guards)

    /// All block contents concatenated — the template surface the Inputs/guards derive from.
    private var templateText: String { messages.map(\.content).joined(separator: "\n") }
    /// Leading SYSTEM block(s) → the FM Instructions for the transcript / Save-to-Lab.
    var systemInstructions: String {
        messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
    }
    /// Every authored user (HUMAN) block, in order — the replay script for Save-to-Lab.
    var userTurns: [String] {
        messages.filter { $0.role == .human }.map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var inputKeys: [String] { PromptAnalysis.variableKeys(instructions: templateText, input: "", hooks: hooks) }
    var hookOutputs: Set<String> { PromptAnalysis.hookOutputs(hooks) }
    var malformedTokens: [String] { PromptAnalysis.malformedTokens(in: templateText) }
    var unusedHookOutputs: [String] {
        PromptAnalysis.unusedHookOutputs(instructions: templateText, input: "", hooks: hooks)
    }

    var isModelAvailable: Bool { ModelAvailability.isAvailable }
    var availabilityMessage: String? { ModelAvailability.message }

    // MARK: Run gating

    /// Opening turn: the preset has the AI speak first and nothing has been said yet.
    private func isOpener(_ list: [ChatMessage]) -> Bool {
        preset.opensWithAI && !list.contains { $0.role == .human || $0.role == .ai }
    }
    var isOpener: Bool { isOpener(messages) }

    /// Index of the trailing HUMAN block (the turn Start will answer), if the list ends with one.
    private var trailingHumanIndex: Int? {
        guard let last = messages.indices.last, messages[last].role == .human else { return nil }
        return last
    }

    /// Start is enabled when there's a non-empty trailing user turn to answer (or it's the opener).
    var canStart: Bool {
        guard !isRunning, isModelAvailable else { return false }
        if isOpener { return true }
        if let i = trailingHumanIndex {
            return !messages[i].content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    // MARK: Block edits

    func loadPreset(_ id: String) {
        guard let p = chatPresets.first(where: { $0.id == id }) else { return }
        presetID = id
        messages = p.seedMessages
        inputs = [:]
        useCustomSchema = false
        customSchema = .roleplayLike
    }

    /// Reset the conversation to the current preset's seed (clears generated turns + Inputs).
    func reset() { loadPreset(presetID) }

    /// Set the leading SYSTEM block's content (used when loading a saved prompt template).
    func setSystemInstructions(_ text: String) {
        if let i = messages.firstIndex(where: { $0.role == .system }) {
            messages[i].content = text
        } else {
            messages.insert(ChatMessage(role: .system, content: text), at: 0)
        }
    }

    /// Append a fresh block — defaults to the role that naturally follows the last (HUMAN after AI).
    func addMessage() {
        let next: ChatMessage.Role = messages.last?.role == .human ? .ai : .human
        messages.append(ChatMessage(role: next))
    }

    func move(_ id: UUID, by offset: Int) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard messages.indices.contains(j) else { return }
        messages.swapAt(i, j)
    }

    func delete(_ id: UUID) { messages.removeAll { $0.id == id } }

    // MARK: Run entry points

    /// Generate the next AI turn (the Start button).
    func start() async {
        guard canStart else { return }
        await runAssistantTurn()
    }

    /// A tapped role-play suggestion becomes the next user turn, then runs.
    func sendSuggestion(_ text: String) async {
        messages.append(ChatMessage(role: .human, content: text))
        await runAssistantTurn()
    }

    /// Drop an AI turn (and everything after it) and re-answer the preceding user turn.
    func regenerate(from aiID: UUID) async {
        guard let i = messages.firstIndex(where: { $0.id == aiID }) else { return }
        messages.removeSubrange(i...)
        await runAssistantTurn()
    }

    // MARK: The traced pipeline (mirrors PlaygroundModel.run, seeded from the edited history)

    private func runAssistantTurn() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let overallStart = Date()

        // Snapshot the authored list and decide what we're answering BEFORE adding the placeholder.
        let prior = messages
        let opener = isOpener(prior)
        let trailingIdx: Int? = opener ? nil : (prior.last?.role == .human ? prior.count - 1 : nil)
        guard opener || trailingIdx != nil else { return }
        let promptRaw = opener ? RoleplayRunner.opening : prior[trailingIdx!].content
        // History fed to the session = everything before the trailing user turn (which is sent live).
        let history = opener ? prior : Array(prior[..<trailingIdx!])

        // Stream into a placeholder AI block so the bubble + its inline trace animate live.
        let aiID = UUID()
        messages.append(ChatMessage(id: aiID, role: .ai, isStreaming: true))
        var stages: [PlaygroundModel.PipelineStage] = []
        func pushTrace() { update(aiID) { $0.trace = stages } }

        // 1) Variables — seed ctx from Inputs; expose the user turn as {{prompt}}/{{input}} for hooks.
        var ctx = inputs
        ctx["prompt"] = promptRaw
        ctx["input"] = promptRaw
        stages.append(.init(kind: .variables, title: "Variables", status: .ok,
                            body: contextPreview(ctx, keys: inputKeys)))
        pushTrace()

        // 2) Pre-hooks — one at a time; each chains off the last.
        for hook in hooks.pre where hook.enabled {
            stages.append(.init(kind: .preHook, title: "Pre · \(hook.op.displayName)", status: .running))
            pushTrace()
            await Task.yield()
            let step = await HookEngine.runOne(hook, context: &ctx)
            let i = stages.count - 1
            stages[i].status = step.error == nil ? .ok : .error
            stages[i].ms = step.ms
            stages[i].note = hookNote(step, outputVar: hook.outputVar)
            stages[i].body = step.error == nil
                ? (hook.outputVar.isEmpty ? (step.output ?? "") : "{{\(hook.outputVar)}} =\n\(step.output ?? "")")
                : ""
            pushTrace()
        }

        // 3) Final prompt — resolve every block, build the transcript, note the FULL-history headroom.
        let resolvedSystem = Vars.substitute(systemInstructions(in: history), ctx)
        let resolvedPrompt = Vars.substitute(promptRaw, ctx)
        let transcript = buildTranscript(history: history, system: resolvedSystem, ctx: ctx)
        let schemaInjected = mode != .plain
        stages.append(.init(kind: .prompt, title: "Final prompt", status: .ok,
                            body: "INSTRUCTIONS\n\(resolvedSystem)\n\nPROMPT\n\(resolvedPrompt)",
                            note: promptNote(transcript: transcript, prompt: resolvedPrompt, schemaInjected: schemaInjected)))
        pushTrace()

        // 4) Model — fresh session seeded from the edited history.
        stages.append(.init(kind: .model, title: "Model output", status: .running))
        let mi = stages.count - 1
        pushTrace()
        await Task.yield()
        let modelStart = Date()
        let session = LanguageModelSession(transcript: transcript)
        var rawOutput = ""
        var typed: RoleplayTurnGen? = nil
        var ttft: Int? = nil
        do {
            switch mode {
            case .plain:
                for try await snapshot in session.streamResponse(to: resolvedPrompt, options: config.toOptions()) {
                    if ttft == nil { ttft = millis(since: modelStart) }
                    rawOutput = snapshot.content
                    stages[mi].body = rawOutput
                    update(aiID) { $0.content = rawOutput; $0.trace = stages }
                }
            case .dynamic:
                let schema = try SchemaBuilder.generationSchema(from: customSchema)
                for try await snapshot in session.streamResponse(to: resolvedPrompt, schema: schema,
                                                                 includeSchemaInPrompt: true, options: config.toOptions()) {
                    if ttft == nil { ttft = millis(since: modelStart) }
                    rawOutput = prettyJSONString(snapshot.rawContent.jsonString)
                    stages[mi].body = rawOutput
                    update(aiID) { $0.content = rawOutput; $0.raw = rawOutput; $0.trace = stages }
                }
            case .typedRoleplay:
                // Non-streaming (like the old RoleplayModel) — the partial-struct stream is fiddly and
                // role-play turns are short. The rich reply/suggestions render from the final `result`.
                let turn = try await session.respond(to: resolvedPrompt, generating: RoleplayTurnGen.self,
                                                     includeSchemaInPrompt: true, options: config.toOptions()).content
                ttft = millis(since: modelStart)
                typed = turn
                rawOutput = prettyJSON(turn)
                stages[mi].body = rawOutput
                update(aiID) { $0.content = turn.reply.text; $0.raw = rawOutput; $0.result = turn; $0.trace = stages }
            }
        } catch let error as LanguageModelSession.GenerationError {
            let msg: String
            if case .exceededContextWindowSize = error {
                msg = "The conversation got too long for the model's context window. Delete or trim earlier messages, or reset the chat."
            } else {
                msg = "Generation failed: \(error.localizedDescription)"
            }
            failTurn(aiID, mi, &stages, msg, since: modelStart); return
        } catch let e as SchemaWalker.ValidationError {
            failTurn(aiID, mi, &stages, "Schema error: \(e.localizedDescription)", since: modelStart); return
        } catch {
            failTurn(aiID, mi, &stages, "Generation failed: \(error.localizedDescription)", since: modelStart); return
        }

        let modelMs = millis(since: modelStart)
        stages[mi].status = .ok
        stages[mi].ms = modelMs
        stages[mi].body = rawOutput
        var note = [schemaInjected ? "Conforms to the Guided Generation schema (constrained decoding)"
                                   : "Free-text output (streamed)"]
        if let ttft { note.append("TTFT \(ttft) ms") }
        if let tps = tokensPerSec(rawOutput, ms: modelMs) { note.append(String(format: "~%.0f tok/s", tps)) }
        stages[mi].note = note.joined(separator: " · ")
        pushTrace()

        // 5) Post-hooks — thread the output through; the final result is the displayed AI text.
        var finalOut = rawOutput
        var postCtx = ctx
        postCtx["output"] = rawOutput
        let hasPost = hooks.post.contains { $0.enabled }
        for hook in hooks.post where hook.enabled {
            stages.append(.init(kind: .postHook, title: "Post · \(hook.op.displayName)", status: .running))
            pushTrace()
            await Task.yield()
            let step = await HookEngine.runOne(hook, context: &postCtx, defaultInput: finalOut)
            if let o = step.output { finalOut = o; postCtx["output"] = o }
            let i = stages.count - 1
            stages[i].status = step.error == nil ? .ok : .error
            stages[i].ms = step.ms
            stages[i].note = hookNote(step, outputVar: hook.outputVar, terminal: true)
            stages[i].body = step.error == nil ? (step.output ?? "") : ""
            pushTrace()
        }
        if hasPost { stages.append(.init(kind: .finalOutput, title: "Final output", status: .ok, body: finalOut)) }

        // Finalize the AI bubble. Typed role-play keeps its rich render (reply text); other lanes show
        // the post-hook final output.
        let elapsed = Date().timeIntervalSince(overallStart)
        update(aiID) {
            if typed == nil { $0.content = finalOut }
            $0.elapsed = elapsed
            $0.isStreaming = false
            $0.trace = stages
        }
    }

    // MARK: Helpers

    /// Mutate the live AI message by id (the streaming target). No-op if it was deleted mid-run.
    private func update(_ id: UUID, _ mutate: (inout ChatMessage) -> Void) {
        guard let idx = messages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&messages[idx])
    }

    private func failTurn(_ id: UUID, _ mi: Int, _ stages: inout [PlaygroundModel.PipelineStage],
                          _ message: String, since modelStart: Date) {
        stages[mi].status = .error
        stages[mi].ms = millis(since: modelStart)
        stages[mi].note = message
        let snapshot = stages
        update(id) { $0.errorText = message; $0.isStreaming = false; $0.trace = snapshot }
    }

    /// Leading SYSTEM block(s) of a given history slice → the FM Instructions text.
    private func systemInstructions(in list: [ChatMessage]) -> String {
        list.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
    }

    /// Build the seed Transcript: resolved system → Instructions; resolved HUMAN/AI → prompt/response.
    private func buildTranscript(history: [ChatMessage], system: String, ctx: [String: String]) -> Transcript {
        var entries: [Transcript.Entry] = []
        if !system.isEmpty {
            entries.append(.instructions(Transcript.Instructions(segments: [.text(.init(content: system))],
                                                                 toolDefinitions: [])))
        }
        for msg in history where msg.role != .system {
            let text = Vars.substitute(msg.content, ctx)
            switch msg.role {
            case .human:  entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: text))])))
            case .ai:     entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: text))])))
            case .system: break
            }
        }
        return Transcript(entries: entries)
    }

    /// "{{key}} = value" lines for the Variables stage body.
    private func contextPreview(_ ctx: [String: String], keys: [String]) -> String {
        let shown = keys.filter { ctx[$0]?.isEmpty == false }
        guard !shown.isEmpty else { return "—" }
        return shown.map { "{{\($0)}} = \(ctx[$0] ?? "")" }.joined(separator: "\n")
    }

    /// A finished hook's note: its error, else a warning when it succeeded but produced empty output.
    private func hookNote(_ step: HookStep, outputVar: String, terminal: Bool = false) -> String? {
        if let error = step.error { return error }
        guard (step.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if terminal { return "⚠︎ Produced empty output — the final output is now blank." }
        return outputVar.isEmpty ? nil : "⚠︎ Produced empty output — {{\(outputVar)}} resolves to blank."
    }

    /// Final-prompt note: schema mode + estimated headroom over the WHOLE history (it grows each turn).
    private func promptNote(transcript: Transcript, prompt: String, schemaInjected: Bool) -> String {
        let schema = schemaInjected
            ? "Guided Generation schema injected (includeSchemaInPrompt: true)"
            : "No schema — free-text output"
        let tokens = TokenEstimator.estimate(transcript) + TokenEstimator.estimate(prompt)
        let pct = Int((Double(tokens) / Double(TokenEstimator.contextWindow) * 100).rounded())
        let warn = tokens > Int(0.9 * Double(TokenEstimator.contextWindow)) ? "⚠︎ " : ""
        return "\(schema)\n\(warn)~\(tokens) estimated tokens · \(pct)% of the \(TokenEstimator.contextWindow)-token window (full history)"
    }
}
