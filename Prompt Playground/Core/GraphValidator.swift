//
//  GraphValidator.swift
//  Prompt Playground
//
//  Pre-run structural checks for the node graph — the thing that turns "your long pipeline fails at the
//  LAST node" into "the canvas told you before you pressed Run." Pure + cheap, so it runs both:
//    • live — the engine recomputes it as the graph changes; GraphCanvas badges the offending node and
//      the FM inspector lists the problems (see GraphEngine.issues / NodeInspector FMEditor).
//    • at run start — GraphExecutor.run aborts up front if any issue exists, so nothing in the queue runs.
//
//  It validates the REQUEST SHAPE the executor relies on (GraphExecutor.runFM): every Foundation Model
//  must be fed a Prompt group that resolves to a NON-EMPTY current turn (the live `respond(to:)` argument
//  — instructions alone send an empty user turn), and every {{var}} in a content block must be bound by an
//  incoming edge (an unbound one renders literally as `{{name}}` into the prompt). It deliberately checks
//  the CURRENT-TURN block, not "an Input node exists" — a current turn can carry a literal, and an Input
//  node with no current turn still fails. Only groups feeding an FM are checked, so a half-built graph
//  (no FM yet) doesn't nag.
//

import Foundation

/// One structural problem, attributed to the node that should surface it (the FM, its Prompt group, or a
/// member block) so the canvas can badge exactly that node and the run-abort can name it.
///
/// `id` (for SwiftUI ForEach) is the (node, message) pair — NOT `nodeID` alone: one node can raise several
/// problems at once (e.g. a block with two unbound {{vars}}), and a ForEach over same-`id` rows traps.
struct GraphIssue: Identifiable, Equatable {
    let nodeID: UUID    // the node to badge / attribute the problem to
    var message: String
    var id: String { "\(nodeID.uuidString):\(message)" }
}

enum GraphValidator {
    /// Every structural problem in the graph (across all FM pipelines). `[]` ⇒ ready to run.
    static func issues(in graph: GraphDef) -> [GraphIssue] {
        graph.nodes.filter { $0.kind == .fm }.flatMap { issues(forFM: $0.id, in: graph) }
    }

    /// Problems for ONE Foundation Model's pipeline — its Prompt group + member blocks.
    static func issues(forFM fmID: UUID, in graph: GraphDef) -> [GraphIssue] {
        guard let fm = graph.node(fmID), fm.kind == .fm else { return [] }
        guard let groupID = graph.promptGroupID(feeding: fmID) else {
            return [GraphIssue(nodeID: fmID,
                               message: "No Prompt wired into this model — drag a Prompt group’s output into its prompt port.")]
        }

        var out: [GraphIssue] = []
        let members = graph.members(of: groupID)

        // The current turn is the live respond(to:) argument. No current turn (or an empty one) ⇒ the model
        // is handed an empty user turn — the exact failure that only blew up at Run before.
        if let cur = members.first(where: { $0.kind == .current }) {
            if (cur.current?.template ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(GraphIssue(nodeID: cur.id, message: "Current turn is empty — the model has no user turn to answer."))
            }
        } else {
            out.append(GraphIssue(nodeID: groupID,
                                  message: "This Prompt has no Current-turn block — the model has no user turn to answer. Add a Current-turn block and wire an Input into it (per-request data belongs in the turn, not the Instruction)."))
        }

        // Unbound {{vars}} in content blocks — they'd substitute to nothing and ship literally to the model.
        for block in members where block.kind == .instruction || block.kind == .history || block.kind == .current {
            let bound = Set(graph.incoming(block.id).map(\.inputPort))
            for v in block.inputPorts where !bound.contains(v) {
                let name = block.title.isEmpty ? block.kind.label : block.title
                out.append(GraphIssue(nodeID: block.id, message: "Unbound {{\(v)}} in “\(name)” — wire a value into it."))
            }
            // Wired BUT empty: the edge exists, but its upstream static Input has no value → the block would
            // resolve {{v}} to "" and the model runs on a blank. (Distinct from the unbound case above.)
            for edge in graph.incoming(block.id) {
                guard let src = graph.node(edge.fromNodeID), src.kind == .input,
                      src.input?.source == .staticLiteral else { continue }
                let value = (src.input?.statics[edge.outputKey] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty {
                    let nm = src.title.isEmpty ? src.kind.label : src.title
                    out.append(GraphIssue(nodeID: src.id,
                        message: "Input “\(nm)” has no value for {{\(edge.outputKey)}} — fill it in or the model runs on a blank."))
                }
            }
        }
        return out
    }

    /// Problems attributed to a single node (for its canvas badge).
    static func issues(for nodeID: UUID, in graph: GraphDef) -> [GraphIssue] {
        issues(in: graph).filter { $0.nodeID == nodeID }
    }
}
