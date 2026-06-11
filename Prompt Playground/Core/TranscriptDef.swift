//
//  TranscriptDef.swift
//  Prompt Playground
//
//  Codable mirror of FoundationModels.Transcript — THE inter-node protocol value for the
//  conversation lane of a graph (docs/prd.md §5.2 node taxonomy, §6.1 KV-cache awareness).
//
//  Why a mirror: the SDK's `Transcript` is Sendable + Equatable + RandomAccessCollection but NOT
//  Codable (verified against the 26.2 swiftinterface), and the graph must persist, trace, and
//  display the conversation lane. So nodes exchange this mirror and bridge to the real Transcript
//  only at the FM boundary:
//
//    blocks ─▶ PROMPT GROUP assembles a TranscriptDef
//              (instructions entry + history prompt/response entries + the current turn as the
//               TRAILING prompt entry, carrying the guided schema name + sampling label)
//      ─▶ FM splits it: leading entries seed LanguageModelSession(transcript:); the trailing
//         prompt's text is the live respond(to:) argument (the framework appends the prompt +
//         response entries itself — putting the turn in the seed would double-send it)
//      ─▶ FM reads `session.transcript` BACK and emits the FULL conversation as its protocol
//         output (TranscriptDef on the node run + a readable text projection on the
//         `transcript` port), so chained FMs / downstream nodes see real conversation state.
//
//  Entries are append-only by construction, which is exactly what keeps the session KV cache
//  valid across shared upstream paths (mutating/removing entries invalidates it — PRD §6.1).
//

import Foundation
import FoundationModels

struct TranscriptDef: Codable, Equatable, Sendable {

    // MARK: Segment (text | structured-as-JSON)

    /// One segment of an entry. Structured content travels as its JSON projection —
    /// `GeneratedContent` is not Codable; `.jsonString` is its lossless wire form.
    struct Segment: Codable, Equatable, Sendable {
        var text: String? = nil
        var structuredJSON: String? = nil
        var source: String? = nil       // StructuredSegment.source (which schema/tool produced it)

        init(text: String) { self.text = text }

        init(_ segment: Transcript.Segment) {
            switch segment {
            case .text(let t):      text = t.content
            case .structure(let s): structuredJSON = s.content.jsonString; source = s.source
            @unknown default:       text = ""
            }
        }

        var displayText: String { text ?? structuredJSON.map(prettyJSONString) ?? "" }

        /// Bridge back to the SDK segment. A structured segment that no longer parses degrades to
        /// text rather than dropping content.
        func toSegment() -> Transcript.Segment {
            if let json = structuredJSON, let content = try? GeneratedContent(json: json) {
                return .structure(.init(source: source ?? "schema", content: content))
            }
            return .text(.init(content: text ?? structuredJSON ?? ""))
        }
    }

    // MARK: Entry

    /// One Transcript.Entry, mirrored. `kind` selects which extra fields mean anything
    /// (flat optionals — the node-payload house style in GraphCore).
    struct Entry: Codable, Equatable, Sendable, Identifiable {
        enum Kind: String, Codable, Sendable, CaseIterable {
            case instructions, prompt, response, toolCalls, toolOutput
        }

        var id = UUID()
        var kind: Kind
        var segments: [Segment] = []
        var toolName: String? = nil            // toolCalls / toolOutput
        var responseFormatName: String? = nil  // prompt: attached Guided Generation schema, if any
        var optionsLabel: String? = nil        // prompt: GenConfig.label in force for this turn

        var text: String { segments.map(\.displayText).filter { !$0.isEmpty }.joined(separator: "\n") }

        /// Display role for the entry-list UI and the text projection.
        var roleLabel: String {
            switch kind {
            case .instructions: return "SYSTEM"
            case .prompt:       return "USER"
            case .response:     return "ASSISTANT"
            case .toolCalls:    return "TOOL CALL"
            case .toolOutput:   return "TOOL OUTPUT"
            }
        }

        /// The official API symbol this entry maps to (UX-First §4.2 — surfaced in the entry list).
        var apiName: String {
            switch kind {
            case .instructions: return "Transcript.Instructions"
            case .prompt:       return "Transcript.Prompt"
            case .response:     return "Transcript.Response"
            case .toolCalls:    return "Transcript.ToolCalls"
            case .toolOutput:   return "Transcript.ToolOutput"
            }
        }
    }

    // MARK: Value

    var entries: [Entry] = []

    init(entries: [Entry] = []) { self.entries = entries }

    var isEmpty: Bool { entries.isEmpty }

    /// Role-labeled plain text of the whole conversation — the `transcript` port's dataflow value
    /// and the human-readable preview.
    var text: String {
        entries.map { "\($0.roleLabel): \($0.text)" }.joined(separator: "\n\n")
    }

    /// Heuristic token estimate of the carried conversation (TokenEstimator's caveats apply).
    var estimatedTokens: Int { TokenEstimator.estimate(entries.map(\.text).joined(separator: "\n")) }

    // MARK: Bridging — SDK Transcript ⇄ TranscriptDef

    /// Mirror a live `session.transcript` (the readback after a respond). Lossless for text;
    /// structured segments keep their JSON; tool calls keep name + argument JSON as text.
    init(_ transcript: Transcript) {
        entries = transcript.map { entry in
            switch entry {
            case .instructions(let i):
                return Entry(kind: .instructions, segments: i.segments.map(Segment.init))
            case .prompt(let p):
                var e = Entry(kind: .prompt, segments: p.segments.map(Segment.init))
                e.responseFormatName = p.responseFormat?.name
                return e
            case .response(let r):
                return Entry(kind: .response, segments: r.segments.map(Segment.init))
            case .toolCalls(let calls):
                var e = Entry(kind: .toolCalls,
                              segments: calls.map { Segment(text: "\($0.toolName)(\($0.arguments.jsonString))") })
                e.toolName = calls.first?.toolName
                return e
            case .toolOutput(let o):
                var e = Entry(kind: .toolOutput, segments: o.segments.map(Segment.init))
                e.toolName = o.toolName
                return e
            @unknown default:
                return Entry(kind: .response, segments: [])
            }
        }
    }

    /// Build the real SDK `Transcript` (the LanguageModelSession(transcript:) seed). Tool entries
    /// are re-emitted as plain text inside a response (a faithful ToolCall needs a live Tool, which
    /// v1 doesn't run); instructions carry no tool definitions for the same reason.
    func toTranscript() -> Transcript {
        var out: [Transcript.Entry] = []
        for entry in entries {
            let segments = entry.segments.map { $0.toSegment() }
            switch entry.kind {
            case .instructions:
                out.append(.instructions(.init(segments: segments, toolDefinitions: [])))
            case .prompt:
                out.append(.prompt(.init(segments: segments)))
            case .response:
                out.append(.response(.init(assetIDs: [], segments: segments)))
            case .toolCalls, .toolOutput:
                guard !entry.text.isEmpty else { continue }
                out.append(.response(.init(assetIDs: [], segments: [.text(.init(content: entry.text))])))
            }
        }
        return Transcript(entries: out)
    }

    // MARK: Request splitting (the FM-boundary contract)

    /// The trailing `.prompt` entry — the live turn an FM sends via respond(to:). nil when the
    /// last entry isn't a prompt (e.g. a readback that already ends in a response).
    var trailingPrompt: Entry? {
        entries.last.flatMap { $0.kind == .prompt ? $0 : nil }
    }

    /// Everything before the trailing prompt — the session seed. The whole value when there is
    /// no trailing prompt.
    var seed: TranscriptDef {
        trailingPrompt == nil ? self : TranscriptDef(entries: Array(entries.dropLast()))
    }
}
