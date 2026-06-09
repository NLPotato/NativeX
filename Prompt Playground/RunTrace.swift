//
//  RunTrace.swift
//  Prompt Playground
//
//  A serializable record of one headless run's pipeline. The headless runners compute every step
//  (variables → pre-hooks → final prompt → model → post-hooks → final output) and assemble a
//  RunTrace from those steps so the Lab can render a staged view per run instead of just the final
//  output. StageCardView renders the persisted trace.
//

import SwiftUI

// MARK: - Persisted trace model

struct RunTrace: Codable, Equatable, Sendable {
    struct Stage: Codable, Equatable, Sendable, Identifiable {
        var id = UUID()
        var kind: String          // "variables"|"preHook"|"prompt"|"model"|"postHook"|"finalOutput"
        var ok: Bool              // a persisted stage is terminal: ok or error (no "running")
        var title: String
        var body: String = ""
        var ms: Int? = nil
        var note: String? = nil
    }
    var stages: [Stage] = []
    static let empty = RunTrace()
    var isEmpty: Bool { stages.isEmpty }
}

// MARK: - Stage builders (assemble the Lab's staged trace from the headless-runner steps)

extension RunTrace.Stage {
    static func variables(ctx: [String: String], keys: [String]) -> Self {
        Self(kind: "variables", ok: true, title: "Variables", body: contextPreview(ctx, keys: keys))
    }

    static func preHook(_ hook: HookDef, _ step: HookStep) -> Self {
        Self(kind: "preHook", ok: step.error == nil, title: "Pre · \(hook.op.displayName)",
             body: step.error == nil
                ? (hook.outputVar.isEmpty ? (step.output ?? "") : "{{\(hook.outputVar)}} =\n\(step.output ?? "")")
                : "",
             ms: step.ms, note: hookNote(step, outputVar: hook.outputVar))
    }

    static func prompt(instructions: String, prompt: String, schemaInjected: Bool) -> Self {
        Self(kind: "prompt", ok: true, title: "Final prompt",
             body: "INSTRUCTIONS\n\(instructions)\n\nPROMPT\n\(prompt)",
             note: PromptAnalysis.headroomNote(instructions: instructions, prompt: prompt, schemaInjected: schemaInjected))
    }

    static func model(output: String, ms: Int, ttftMs: Int?, tokensPerSec: Double?, schemaInjected: Bool) -> Self {
        var notes: [String] = [schemaInjected
            ? "Conforms to the Guided Generation schema (constrained decoding)"
            : "Free-text output (streamed)"]
        if let ttftMs { notes.append("TTFT \(ttftMs) ms") }
        if let tokensPerSec { notes.append(String(format: "~%.0f tok/s", tokensPerSec)) }
        return Self(kind: "model", ok: true, title: "Model output", body: output, ms: ms,
                    note: notes.joined(separator: " · "))
    }

    static func modelError(_ message: String, ms: Int) -> Self {
        Self(kind: "model", ok: false, title: "Model output", ms: ms, note: message)
    }

    static func postHook(_ hook: HookDef, _ step: HookStep) -> Self {
        Self(kind: "postHook", ok: step.error == nil, title: "Post · \(hook.op.displayName)",
             body: step.error == nil ? (step.output ?? "") : "",
             ms: step.ms, note: hookNote(step, outputVar: hook.outputVar, terminal: true))
    }

    static func finalOutput(_ output: String) -> Self {
        Self(kind: "finalOutput", ok: true, title: "Final output", body: output)
    }

    /// One model call in a multi-turn run (role-play), titled by turn number.
    static func turn(_ index: Int, body: String, ms: Int?) -> Self {
        Self(kind: "model", ok: true, title: "Turn \(index) · model", body: body, ms: ms)
    }

    /// "{{key}} = value" lines for the given keys present in the context (the Variables stage body).
    private static func contextPreview(_ ctx: [String: String], keys: [String]) -> String {
        let shown = keys.filter { ctx[$0]?.isEmpty == false }
        guard !shown.isEmpty else { return "—" }
        return shown.map { "{{\($0)}} = \(ctx[$0] ?? "")" }.joined(separator: "\n")
    }

    /// A finished hook's note: its error, else a warning when it succeeded but produced empty output.
    private static func hookNote(_ step: HookStep, outputVar: String, terminal: Bool = false) -> String? {
        if let error = step.error { return error }
        guard (step.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if terminal { return "⚠︎ Produced empty output — the final output is now blank." }
        return outputVar.isEmpty ? nil : "⚠︎ Produced empty output — {{\(outputVar)}} resolves to blank."
    }
}

// MARK: - Stage card (draws the persisted RunTrace.Stage)

struct StageCardView: View {
    enum Status { case running, ok, error }
    let title: String
    let status: Status
    let text: String
    var ms: Int? = nil
    var note: String? = nil
    var raised: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                statusGlyph
                Text(title).font(.dsLabel)
                Spacer()
                if let ms { Text("\(ms) ms").font(.dsCaption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if let note, !note.isEmpty {
                Text(note).font(.dsCaption)
                    .foregroundStyle(status == .error ? Color.dsDanger : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !text.isEmpty {
                Text(text)
                    .font(.dsCode)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Space.sm)
                    .codeSurface()
            }
        }
        .dsCard(raised: raised)
    }

    @ViewBuilder private var statusGlyph: some View {
        switch status {
        case .running: ProgressView().controlSize(.small)
        case .ok:      Image(systemName: "checkmark.circle.fill").foregroundStyle(.dsSuccess).font(.dsCaption)
        case .error:   Image(systemName: "xmark.circle.fill").foregroundStyle(.dsDanger).font(.dsCaption)
        }
    }
}

extension StageCardView {
    /// Build the card from a persisted trace stage.
    init(_ stage: RunTrace.Stage) {
        self.init(title: stage.title, status: stage.ok ? .ok : .error, text: stage.body,
                  ms: stage.ms, note: stage.note, raised: stage.kind == "finalOutput")
    }
}
