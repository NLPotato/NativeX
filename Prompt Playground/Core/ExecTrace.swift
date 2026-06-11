//
//  ExecTrace.swift
//  Prompt Playground
//
//  The plain, Sendable record one graph execution produces — the value the headless GraphExecutor
//  returns and the Run History page persists (as TraceModel). LangSmith-style: a trace GROUPS the
//  consecutive steps of one run, and each step is one logged record — an LLM call (`.llm`, the rich
//  one: final prompt in blocks + token estimates + output + sampling), or a deterministic native-API
//  / hook step (`.api` / `.hook`: op + input + output). The executor stays pure (no SwiftData); the
//  view maps ExecTrace → TraceModel.
//

import Foundation

/// One graph execution: its steps in run order, total wall-clock, and an overall ok/error roll-up.
struct ExecTrace: Codable, Sendable {
    var steps: [ExecStep] = []
    var totalMs: Int = 0
    var status: String = "ok"          // "ok" | "error" (any step errored)

    /// How many LLM calls this execution made — the "records" the user counts.
    var llmRunCount: Int { steps.filter { $0.type == "llm" }.count }
}

/// One logged step. `type` selects which detail block is populated (flat optionals, matching the
/// node payload house style in GraphCore) — `.llm` fills the prompt/token/output fields; `.api` /
/// `.hook` fill the op/input/output fields.
struct ExecStep: Codable, Sendable, Identifiable {
    var id = UUID()                    // the run id (random) — stable per node execution
    var type: String                   // "llm" | "api" | "hook"
    var title: String
    var ms: Int = 0
    var ok: Bool = true
    var errorReason: String? = nil

    // LLM detail (the final prompt, in blocks + what it produced).
    var instructions: String? = nil    // system block (instructions + few-shot + tools, as assembled)
    var history: [TurnLine]? = nil      // past turns
    var currentTurn: String? = nil      // the live turn
    var schemaName: String? = nil       // guided-generation schema, if any
    var output: String? = nil
    var configLabel: String? = nil      // sampling summary (GenConfig.label)
    var promptTokens: Int? = nil        // heuristic estimate (native response.usage pending the 26.4 SDK — see TokenEstimator)
    var outputTokens: Int? = nil
    var contextTokens: Int? = nil
    var transcript: TranscriptDef? = nil // the conversation-lane readback (session.transcript), entry by entry

    // Native-API / hook detail.
    var op: String? = nil
    var input: String? = nil
    var stepOutput: String? = nil
}

/// One past turn in an LLM step's history block.
struct TurnLine: Codable, Sendable, Identifiable {
    var id = UUID()
    var role: String
    var text: String
}

extension ExecStep {
    static func llm(id: UUID, title: String, ms: Int, ok: Bool, error: String?,
                    instructions: String, history: [TurnLine], currentTurn: String,
                    schemaName: String?, output: String?, configLabel: String?,
                    promptTokens: Int, outputTokens: Int, transcript: TranscriptDef? = nil) -> ExecStep {
        var s = ExecStep(type: "llm", title: title)
        s.id = id; s.ms = ms; s.ok = ok; s.errorReason = error
        s.instructions = instructions; s.history = history; s.currentTurn = currentTurn
        s.schemaName = schemaName; s.output = output; s.configLabel = configLabel
        s.promptTokens = promptTokens; s.outputTokens = outputTokens
        s.contextTokens = promptTokens + outputTokens
        s.transcript = transcript
        return s
    }

    static func process(id: UUID, type: String, title: String, ms: Int, ok: Bool,
                        error: String?, op: String, input: String?, output: String?) -> ExecStep {
        var s = ExecStep(type: type, title: title)
        s.id = id; s.ms = ms; s.ok = ok; s.errorReason = error
        s.op = op; s.input = input; s.stepOutput = output
        return s
    }
}
