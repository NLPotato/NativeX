//
//  GraphCore.swift
//  Prompt Playground
//
//  Node-graph data model — the ComfyUI/FigJam-style canvas that unifies the Single-shot + Chat tabs.
//  A GraphDef is a DAG of typed nodes wired by EXPLICIT (outputKey → inputPort) edges over a
//  LangChain-style [String:String] dataflow. It reuses the existing pipeline primitives wholesale —
//  Vars substitution, HookDef/HookEngine, GenConfig, SchemaDef/DynamicRun — so the graph is mostly a
//  visual surface over logic that already ships. Execution lives in GraphExecutor.
//
//  Persisted as ONE JSON blob on GraphModel (Storage.swift), matching the SchemaModel.defJSON
//  convention. The node payload is a struct-of-optionals (not a Codable enum) so SwiftUI can bind
//  straight into a node's typed config (e.g. $node.fm.config) and reuse the existing control views.
//
//  NO #Playground block (Xcode auto-runs them and crashes the model).
//

import Foundation

// MARK: - Node kind

enum NodeKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case message    // a fixed conversation turn (system / human / ai) → FM transcript history
    case prompt     // a {{var}} template + few-shot → the current user turn
    case nativeAPI  // a deterministic NaturalLanguage op (HookOp native ops)
    case hook       // a script / glue transform (HookOp.script + regex/json/text)
    case fm         // one Foundation Models call (sampling + optional guided generation)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .message:   return "Message"
        case .prompt:    return "Prompt"
        case .nativeAPI: return "Native API"
        case .hook:      return "Hook"
        case .fm:        return "Foundation Model"
        }
    }

    /// SF Symbol shown on the node face + palette.
    var symbol: String {
        switch self {
        case .message:   return "bubble.left.and.bubble.right"
        case .prompt:    return "text.alignleft"
        case .nativeAPI: return "cpu"
        case .hook:      return "terminal"
        case .fm:        return "brain"
        }
    }
}

// MARK: - Payloads (struct-of-optionals on GraphNode; exactly one is non-nil per kind)

enum MessageRole: String, Codable, CaseIterable, Sendable {
    case system, human, ai
    var label: String { rawValue.uppercased() }
}

struct MessagePayload: Codable, Equatable, Sendable {
    var role: MessageRole = .human
    var content: String = ""        // {{var}} template, resolved at run
}

/// One few-shot exemplar appended into the resolved prompt as a User/Assistant pair.
struct FewShot: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var user: String = ""
    var assistant: String = ""
}

struct PromptPayload: Codable, Equatable, Sendable {
    var template: String = ""
    var statics: [String: String] = [:]   // variables filled by a literal value (vs wired by an edge)
    var fewShots: [FewShot] = []
}

struct FMPayload: Codable, Equatable, Sendable {
    var config: GenConfig = GenConfig()
    var useGuidedGen: Bool = false
    var schemaDef: SchemaDef? = nil       // the Guided Generation schema, when useGuidedGen
}

// MARK: - Node

struct GraphNode: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: NodeKind
    var x: Double = 0                      // canvas-space position
    var y: Double = 0
    var title: String = ""
    // Exactly one payload is non-nil, selected by `kind`. `hook` backs both .hook and .nativeAPI.
    var message: MessagePayload? = nil
    var prompt:  PromptPayload?  = nil
    var hook:    HookDef?        = nil
    var fm:      FMPayload?      = nil
}

extension GraphNode {
    static func message(role: MessageRole = .human, content: String = "",
                        x: Double = 0, y: Double = 0, title: String? = nil) -> GraphNode {
        GraphNode(kind: .message, x: x, y: y, title: title ?? "Message",
                  message: MessagePayload(role: role, content: content))
    }

    static func prompt(template: String = "", statics: [String: String] = [:], fewShots: [FewShot] = [],
                       x: Double = 0, y: Double = 0, title: String? = nil) -> GraphNode {
        GraphNode(kind: .prompt, x: x, y: y, title: title ?? "Prompt",
                  prompt: PromptPayload(template: template, statics: statics, fewShots: fewShots))
    }

    static func nativeAPI(op: HookOp = .tokenizeWords, inputVar: String = "input", outputVar: String? = nil,
                          params: [String: String] = [:], x: Double = 0, y: Double = 0, title: String? = nil) -> GraphNode {
        GraphNode(kind: .nativeAPI, x: x, y: y, title: title ?? op.displayName,
                  hook: HookDef(op: op, inputVar: inputVar, outputVar: outputVar, params: params))
    }

    static func hook(op: HookOp = .script, inputVar: String = "input", outputVar: String? = nil,
                     params: [String: String] = [:], x: Double = 0, y: Double = 0, title: String? = nil) -> GraphNode {
        GraphNode(kind: .hook, x: x, y: y, title: title ?? op.displayName,
                  hook: HookDef(op: op, inputVar: inputVar, outputVar: outputVar, params: params))
    }

    static func fm(config: GenConfig = GenConfig(), useGuidedGen: Bool = false, schemaDef: SchemaDef? = nil,
                   x: Double = 0, y: Double = 0, title: String? = nil) -> GraphNode {
        GraphNode(kind: .fm, x: x, y: y, title: title ?? "Foundation Model",
                  fm: FMPayload(config: config, useGuidedGen: useGuidedGen, schemaDef: schemaDef))
    }

    /// Output keys this node produces (used by the canvas to draw output ports + validation).
    var outputKeys: [String] {
        switch kind {
        case .message:           return ["message"]
        case .prompt:            return ["prompt"]
        case .nativeAPI, .hook:  return [hook.map { $0.outputVar.isEmpty ? "output" : $0.outputVar } ?? "output"]
        case .fm:                return (fm?.useGuidedGen ?? false) ? ["output", "json"] : ["output"]
        }
    }

    /// Named input ports this node accepts (declared; an edge may still target any port name).
    /// `prev` (message) and `history` (FM) are STRUCTURAL threading ports — they establish
    /// conversation order / ancestry for the FM transcript, not a data variable.
    var inputPorts: [String] {
        switch kind {
        case .message:           return ["prev"] + Vars.keys(in: message?.content ?? "")
        case .prompt:
            // Every {{var}} in the template that has no literal static value is an input port.
            let statics = prompt?.statics ?? [:]
            return Vars.keys(in: prompt?.template ?? "").filter { (statics[$0] ?? "").isEmpty }
        case .nativeAPI, .hook:  return [hook?.inputVar ?? "input"]
        case .fm:                return ["prompt", "history"]
        }
    }
}

// MARK: - Edge

struct GraphEdge: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var fromNodeID: UUID
    var outputKey: String
    var toNodeID: UUID
    var inputPort: String
}

// MARK: - Graph

struct GraphDef: Codable, Equatable, Sendable {
    var nodes: [GraphNode] = []
    var edges: [GraphEdge] = []

    static let empty = GraphDef()

    func node(_ id: UUID) -> GraphNode? { nodes.first { $0.id == id } }

    /// Edges whose target is `id`.
    func incoming(_ id: UUID) -> [GraphEdge] { edges.filter { $0.toNodeID == id } }
}

// MARK: - Per-node run result (drives the canvas status badges + inline trace)

struct GraphNodeRun: Identifiable, Sendable {
    enum Status: String, Sendable { case pending, running, ok, error }
    let id = UUID()
    let nodeID: UUID
    var status: Status = .pending
    var outputs: [String: String] = [:]
    var ms: Int? = nil
    var error: String? = nil
    var note: String? = nil
}
