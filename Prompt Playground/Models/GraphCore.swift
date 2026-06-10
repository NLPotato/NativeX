//
//  GraphCore.swift
//  Prompt Playground
//
//  Node-graph data model (v2) — the ComfyUI/FigJam-style canvas that unifies Single-shot + Chat.
//
//  THE MODEL. The overloaded word "Prompt" is unwound into distinct primitives:
//    • A **Prompt** is a framed GROUP — a container node (`.promptGroup`) that ASSEMBLES typed
//      member BLOCKS into one request fed to a model. Members carry `groupID` (the SINGLE source of
//      truth for membership — the executor does NOT walk edges to decide what's in a prompt).
//    • Blocks (each a wireable node, a member via `groupID`): instruction · fewshot · history ·
//      current · guided · tool. Blocks hold TEMPLATE text with {{vars}} and NO literal values.
//    • **Input** is the only place a {{var}} gets a value (static or JSON in v1; csv/excel/dataset
//      reserved for v2). It feeds blocks' {{vars}} through optional native-api / hook process nodes.
//    • **Foundation Model** consumes one Prompt group (via a single `promptGroup → fm` edge) + its
//      own sampling, runs, emits the Generation. Prompt = the request spec; FM = the call.
//
//  Persisted as ONE JSON blob on GraphModel (Storage.swift). The node payload is a struct-of-optionals
//  (not a Codable enum) so SwiftUI binds straight into a node's typed config and reuses the existing
//  control views (GenConfigControls, SchemaEditorView) verbatim. Old (v1: message/prompt/fm) graphs
//  are migrated up at load by GraphMigration.swift — see GraphDef.schemaVersion.
//
//  NO #Playground block (Xcode auto-runs them and crashes the model).
//

import Foundation

// MARK: - Node kind

enum NodeKind: String, Codable, CaseIterable, Sendable, Identifiable {
    // Container — the framed Prompt; assembles its member blocks.
    case promptGroup

    // Blocks — members of a prompt group (carry `groupID`).
    case instruction   // system / persona / rules text          (1..n per group)
    case fewshot       // demonstration user/assistant pairs      (0..n)
    case history       // one PAST turn (human / ai)              (0..n)
    case current       // the live turn (Input-fed)               (0..1)
    case guided        // output schema (SchemaDef)               (0..1)
    case tool          // title + description                     (0..n; v1 = instructions text)

    // Free nodes.
    case input         // variable source: static | json (csv/excel/dataset reserved for v2)
    case nativeAPI     // deterministic NaturalLanguage op (HookDef)
    case hook          // script / glue transform (HookDef)
    case fm            // the model call (sampling + execution)
    case compare       // A/B: references prompt groups + runs them side-by-side (GraphCompareRunner)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .promptGroup: return "Prompt"
        case .instruction: return "Instruction"
        case .fewshot:     return "Few-shot"
        case .history:     return "History"
        case .current:     return "Current turn"
        case .guided:      return "Guided output"
        case .tool:        return "Tool"
        case .input:       return "Input"
        case .nativeAPI:   return "Native API"
        case .hook:        return "Hook"
        case .fm:          return "Foundation Model"
        case .compare:     return "Compare"
        }
    }

    /// SF Symbol shown on the node face + palette.
    var symbol: String {
        switch self {
        case .promptGroup: return "rectangle.3.group"
        case .instruction: return "text.justify.left"
        case .fewshot:     return "list.bullet.rectangle"
        case .history:     return "clock.arrow.circlepath"
        case .current:     return "bubble.right.fill"
        case .guided:      return "curlybraces"
        case .tool:        return "wrench.and.screwdriver"
        case .input:       return "arrow.right.to.line"
        case .nativeAPI:   return "cpu"
        case .hook:        return "terminal"
        case .fm:          return "brain"
        case .compare:     return "rectangle.split.3x1"
        }
    }

    /// Block kinds are members of a prompt group (gated for drop-into-frame + the Add-block menu).
    var isBlock: Bool {
        switch self {
        case .instruction, .fewshot, .history, .current, .guided, .tool: return true
        default: return false
        }
    }
}

// MARK: - Payloads (struct-of-optionals on GraphNode; exactly one is non-nil per kind)

struct PromptGroupPayload: Codable, Equatable, Sendable {
    var width: Double = 320       // empty-state fallback frame size (when the group has no members)
    var height: Double = 160
}

struct InstructionPayload: Codable, Equatable, Sendable {
    var text: String = ""         // {{var}} template — persona / role / rules / NOT-TO-DO
}                                 // concat order follows canvas position (top→bottom), see GraphExecutor.assemble

/// One few-shot exemplar appended into the instructions as a User/Assistant pair.
struct FewShot: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var user: String = ""
    var assistant: String = ""
}

struct FewShotPayload: Codable, Equatable, Sendable {
    var shots: [FewShot] = []
}

enum TurnRole: String, Codable, CaseIterable, Sendable {
    case human, ai
    var label: String { self == .human ? "Human" : "AI" }
}

struct HistoryPayload: Codable, Equatable, Sendable {
    var role: TurnRole = .human   // PAST only — system text is an instruction block, not history
    var content: String = ""      // {{var}} template
}

struct CurrentTurnPayload: Codable, Equatable, Sendable {
    var template: String = "{{input}}"   // the present turn; an Input node feeds its {{vars}}
}

struct GuidedPayload: Codable, Equatable, Sendable {
    var schemaDef: SchemaDef? = nil      // the Guided Generation schema; nil = not yet authored
}

struct ToolPayload: Codable, Equatable, Sendable {
    var name: String = ""
    var toolDescription: String = ""     // v1: rendered into instructions text, NOT a callable Tool
}

/// Where an Input node's values come from. Only `.staticLiteral` / `.json` execute in v1; the rest are
/// stored (so the editor + persistence are forward-compatible) and throw a clear error at run.
enum InputSource: String, Codable, CaseIterable, Sendable {
    case staticLiteral, json, csv, excel, dataset

    var label: String {
        switch self {
        case .staticLiteral: return "Static"
        case .json:          return "JSON"
        case .csv:           return "CSV"
        case .excel:         return "Excel"
        case .dataset:       return "Dataset"
        }
    }
    var supportedV1: Bool { self == .staticLiteral || self == .json }
}

struct InputPayload: Codable, Equatable, Sendable {
    var source: InputSource = .staticLiteral
    var statics: [String: String] = [:]   // STATIC: literal {{var}} → value
    var jsonLiteral: String = ""           // JSON: an object whose top-level scalar keys become {{vars}}
    var datasetID: UUID? = nil             // DATASET: bound DatasetModel; each row feeds the wired {{vars}}
    var datasetColumns: [String]? = nil    // the bound dataset's variable names, denormalized so the node's
                                           // output ports are wireable without store access (Optional → old graphs decode)
    var rowIndex: Int? = nil               // v2: which row when previewing a dynamic source
}

struct FMPayload: Codable, Equatable, Sendable {
    var config: GenConfig = GenConfig()    // sampling / decode params; schema lives on the guided block
}

/// A Compare node references the prompt groups to pit against each other (by id — NOT nested). Running it
/// executes the graph once and collects each referenced lane's FM output side-by-side (GraphCompareRunner).
struct ComparePayload: Codable, Equatable, Sendable {
    var laneGroupIDs: [UUID] = []
}

// MARK: - Node

struct GraphNode: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var kind: NodeKind
    var x: Double = 0                       // canvas-space position
    var y: Double = 0
    var w: Double? = nil                    // manual card-width override (drag the resize grip); nil = default
    var h: Double? = nil                    // manual card-height override (drag the resize grip); nil = auto
    var title: String = ""
    var groupID: UUID? = nil                // non-nil ⇒ a member block of that prompt group

    // Exactly one payload is non-nil, selected by `kind`. `hook` backs both .hook and .nativeAPI.
    var group:       PromptGroupPayload? = nil
    var instruction: InstructionPayload? = nil
    var fewshot:     FewShotPayload?     = nil
    var history:     HistoryPayload?     = nil
    var current:     CurrentTurnPayload? = nil
    var guided:      GuidedPayload?      = nil
    var tool:        ToolPayload?        = nil
    var input:       InputPayload?       = nil
    var hook:        HookDef?            = nil
    var fm:          FMPayload?          = nil
    var compare:     ComparePayload?     = nil
}

extension GraphNode {
    static func promptGroup(title: String = "Prompt", x: Double = 0, y: Double = 0) -> GraphNode {
        GraphNode(kind: .promptGroup, x: x, y: y, title: title, group: PromptGroupPayload())
    }
    static func instruction(_ text: String = "", groupID: UUID? = nil,
                            x: Double = 0, y: Double = 0, title: String = "Instruction") -> GraphNode {
        GraphNode(kind: .instruction, x: x, y: y, title: title, groupID: groupID,
                  instruction: InstructionPayload(text: text))
    }
    static func fewshot(_ shots: [FewShot] = [], groupID: UUID? = nil,
                        x: Double = 0, y: Double = 0, title: String = "Few-shot") -> GraphNode {
        GraphNode(kind: .fewshot, x: x, y: y, title: title, groupID: groupID,
                  fewshot: FewShotPayload(shots: shots))
    }
    static func history(role: TurnRole = .human, content: String = "", groupID: UUID? = nil,
                        x: Double = 0, y: Double = 0, title: String? = nil) -> GraphNode {
        GraphNode(kind: .history, x: x, y: y, title: title ?? "History", groupID: groupID,
                  history: HistoryPayload(role: role, content: content))
    }
    static func current(template: String = "{{input}}", groupID: UUID? = nil,
                        x: Double = 0, y: Double = 0, title: String = "Current turn") -> GraphNode {
        GraphNode(kind: .current, x: x, y: y, title: title, groupID: groupID,
                  current: CurrentTurnPayload(template: template))
    }
    static func guided(_ def: SchemaDef? = nil, groupID: UUID? = nil,
                       x: Double = 0, y: Double = 0, title: String = "Guided output") -> GraphNode {
        GraphNode(kind: .guided, x: x, y: y, title: title, groupID: groupID,
                  guided: GuidedPayload(schemaDef: def))
    }
    static func tool(name: String = "", description: String = "", groupID: UUID? = nil,
                     x: Double = 0, y: Double = 0, title: String? = nil) -> GraphNode {
        GraphNode(kind: .tool, x: x, y: y, title: title ?? "Tool", groupID: groupID,
                  tool: ToolPayload(name: name, toolDescription: description))
    }
    static func input(source: InputSource = .staticLiteral, statics: [String: String] = [:],
                      jsonLiteral: String = "", x: Double = 0, y: Double = 0, title: String = "Input") -> GraphNode {
        GraphNode(kind: .input, x: x, y: y, title: title,
                  input: InputPayload(source: source, statics: statics, jsonLiteral: jsonLiteral))
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
    static func fm(config: GenConfig = GenConfig(), x: Double = 0, y: Double = 0,
                   title: String = "Foundation Model") -> GraphNode {
        GraphNode(kind: .fm, x: x, y: y, title: title, fm: FMPayload(config: config))
    }
    static func compare(laneGroupIDs: [UUID] = [], x: Double = 0, y: Double = 0,
                        title: String = "Compare") -> GraphNode {
        GraphNode(kind: .compare, x: x, y: y, title: title, compare: ComparePayload(laneGroupIDs: laneGroupIDs))
    }

    /// Output keys this node exposes as right-edge ports on the canvas. Blocks have NO output ports —
    /// the group reads them by `groupID` membership, not by an edge.
    var outputKeys: [String] {
        switch kind {
        case .promptGroup:      return ["prompt"]            // the assembled request → FM
        case .input:            return inputVarNames          // one port per produced variable
        case .nativeAPI, .hook: return [hook.map { $0.outputVar.isEmpty ? "output" : $0.outputVar } ?? "output"]
        case .fm:               return ["output", "json"]
        default:                return []                     // blocks: consumed by membership
        }
    }

    /// Named input ports this node accepts (left-edge). A {{var}} in a block's template is an input port
    /// (fed by an Input node or a process node). The FM consumes a Prompt group via its `prompt` port.
    var inputPorts: [String] {
        switch kind {
        case .promptGroup:      return []                     // assembles members by groupID, not ports
        case .instruction:      return Vars.keys(in: instruction?.text ?? "")
        case .history:          return Vars.keys(in: history?.content ?? "")
        case .current:          return Vars.keys(in: current?.template ?? "")
        case .fewshot, .guided, .tool, .input, .compare: return []
        case .nativeAPI, .hook: return [hook?.inputVar ?? "input"]
        case .fm:               return ["prompt"]
        }
    }

    /// Variables an Input node supplies (its output ports).
    var inputVarNames: [String] {
        guard kind == .input, let p = input else { return [] }
        switch p.source {
        case .staticLiteral: return p.statics.keys.sorted()
        case .json:          return GraphJSON.topLevelKeys(p.jsonLiteral)
        case .dataset:       return p.datasetColumns ?? []     // columns of the bound dataset (set on bind)
        default:             return []                         // csv/excel: ports come from the bound source (v2)
        }
    }

    /// The executor's stored-output key for a block (independent of canvas ports). The group reads these.
    var blockOutputKey: String? {
        switch kind {
        case .instruction: return "text"
        case .history:     return "turn"
        case .current:     return "currentturn"
        case .fewshot:     return "fewshot"
        default:           return nil
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
    /// Bumped when the node model changes shape. Absent in old JSON ⇒ treated as 1 (legacy) by the
    /// dict-level migrator (GraphMigration.swift). New in-memory graphs default to the current version.
    var schemaVersion: Int = GraphDef.currentVersion
    var nodes: [GraphNode] = []
    var edges: [GraphEdge] = []

    static let currentVersion = 2
    static let empty = GraphDef()

    func node(_ id: UUID) -> GraphNode? { nodes.first { $0.id == id } }

    /// Edges whose target is `id`.
    func incoming(_ id: UUID) -> [GraphEdge] { edges.filter { $0.toNodeID == id } }

    /// Member blocks of a prompt group (the SINGLE source of truth for group membership).
    func members(of groupID: UUID) -> [GraphNode] { nodes.filter { $0.groupID == groupID } }

    /// The prompt group feeding an FM node (the source of its single incoming `promptGroup → fm` edge).
    func promptGroupID(feeding fmID: UUID) -> UUID? {
        incoming(fmID).first { node($0.fromNodeID)?.kind == .promptGroup }?.fromNodeID
    }

    /// The FM node a prompt group feeds (the target of its single outgoing `promptGroup → fm` edge).
    /// Reverse of `promptGroupID(feeding:)` — `nil` ⇒ this group drives no model (an un-runnable lane).
    func fmID(fedBy groupID: UUID) -> UUID? {
        edges.first { $0.fromNodeID == groupID && node($0.toNodeID)?.kind == .fm }?.toNodeID
    }
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

// MARK: - JSON helpers (Input(json) variable extraction)

enum GraphJSON {
    /// Top-level keys of a JSON object literal whose values are scalars (the only ones that map cleanly
    /// onto a `[String:String]` dataflow value). Arrays/objects are skipped. `[]` if not a JSON object.
    static func topLevelKeys(_ literal: String) -> [String] {
        scalarObject(literal).keys.sorted()
    }

    /// Parse a JSON object literal into a `[String:String]` of its top-level SCALAR fields.
    static func scalarObject(_ literal: String) -> [String: String] {
        guard let data = literal.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj {
            switch v {
            case let s as String:   out[k] = s
            case let n as NSNumber: out[k] = n.stringValue   // numbers + booleans bridge through NSNumber
            default: break                                   // skip nested arrays/objects in v1
            }
        }
        return out
    }
}
