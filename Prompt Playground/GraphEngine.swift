//
//  GraphEngine.swift
//  Prompt Playground
//
//  @Observable view-model for the Graph tab: owns the live GraphDef, canvas transform, selection,
//  per-node run results, and the mutation API the canvas + inspector call. Mirrors the existing tab
//  engine convention (PlaygroundModel / ChatModel) — instantiated as @State in the tab root, fed the
//  shared modelContext for save/load. Execution is delegated to GraphExecutor.
//
//  NodeMetrics holds the analytic canvas geometry (fixed node width + per-port slot) so edge anchor
//  points are computed algebraically — no PreferenceKey layout feedback, no one-frame lag.
//

import SwiftUI

// MARK: - Canvas geometry (analytic anchors)

enum NodeMetrics {
    static let width: CGFloat = 216
    static let header: CGFloat = 60      // icon + title row + kind/summary row
    static let portSlot: CGFloat = 26
    static let footer: CGFloat = 14
    static let portDot: CGFloat = 11

    static func rows(_ n: GraphNode) -> Int { max(n.inputPorts.count, n.outputKeys.count, 1) }
    static func height(_ n: GraphNode) -> CGFloat { header + CGFloat(rows(n)) * portSlot + footer }
    static func rowCenterY(_ index: Int) -> CGFloat { header + CGFloat(index) * portSlot + portSlot / 2 }

    /// Canvas-space anchor of an input port (left edge) / output port (right edge).
    static func inputAnchor(_ n: GraphNode, _ i: Int) -> CGPoint { CGPoint(x: n.x, y: n.y + rowCenterY(i)) }
    static func outputAnchor(_ n: GraphNode, _ j: Int) -> CGPoint { CGPoint(x: n.x + width, y: n.y + rowCenterY(j)) }
}

// MARK: - Engine

@MainActor
@Observable
final class GraphEngine {
    var graph: GraphDef
    var selection: UUID? = nil

    // Canvas transform (canvas → board: p*scale + offset).
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    // Run state.
    var isRunning = false
    var runs: [UUID: GraphNodeRun] = [:]
    var runError: String? = nil

    // Persistence link (which saved GraphModel is open).
    var loadedID: UUID? = nil

    // Transient wiring drag (canvas space).
    var pendingFrom: (node: UUID, key: String)? = nil
    var pendingPoint: CGPoint? = nil

    init(graph: GraphDef = .init()) { self.graph = graph }

    var selectedNode: GraphNode? { selection.flatMap { sel in graph.nodes.first { $0.id == sel } } }
    var availabilityMessage: String? { ModelAvailability.message }

    func index(_ id: UUID) -> Int? { graph.nodes.firstIndex { $0.id == id } }

    // MARK: Mutation

    func addNode(_ kind: NodeKind, at p: CGPoint) {
        var n = GraphEngine.make(kind)
        n.x = p.x; n.y = p.y
        graph.nodes.append(n)
        selection = n.id
    }

    func deleteSelection() { if let id = selection { deleteNode(id) } }

    func deleteNode(_ id: UUID) {
        graph.nodes.removeAll { $0.id == id }
        graph.edges.removeAll { $0.fromNodeID == id || $0.toNodeID == id }
        if selection == id { selection = nil }
        runs[id] = nil
    }

    func move(_ id: UUID, to p: CGPoint) {
        if let i = index(id) { graph.nodes[i].x = p.x; graph.nodes[i].y = p.y }
    }

    /// Connect an upstream output key into a downstream input port (one edge per input port).
    func connect(from: UUID, key: String, to: UUID, port: String) {
        guard from != to else { return }
        graph.edges.removeAll { $0.toNodeID == to && $0.inputPort == port }
        graph.edges.append(GraphEdge(fromNodeID: from, outputKey: key, toNodeID: to, inputPort: port))
    }

    func deleteEdge(_ id: UUID) { graph.edges.removeAll { $0.id == id } }

    /// Remove the edge feeding a given input port (double-click an input port dot to unwire).
    func disconnect(to id: UUID, port: String) {
        graph.edges.removeAll { $0.toNodeID == id && $0.inputPort == port }
    }

    func isConnected(_ id: UUID, port: String) -> Bool {
        graph.edges.contains { $0.toNodeID == id && $0.inputPort == port }
    }

    // MARK: Run

    func run() async {
        guard !isRunning else { return }
        isRunning = true; runError = nil; runs = [:]
        defer { isRunning = false }
        do {
            try await GraphExecutor.run(graph) { run in self.runs[run.nodeID] = run }
        } catch {
            runError = error.localizedDescription
        }
    }

    // MARK: Transform helpers (board ↔ canvas)

    func toCanvas(_ b: CGPoint) -> CGPoint {
        CGPoint(x: (b.x - offset.width) / scale, y: (b.y - offset.height) / scale)
    }

    /// Nearest input port whose anchor is within tolerance of a canvas point (drag-to-connect drop).
    func hitInputPort(near p: CGPoint, tolerance: CGFloat = 26) -> (node: UUID, port: String)? {
        var best: (node: UUID, port: String, d: CGFloat)? = nil
        for n in graph.nodes {
            for (i, port) in n.inputPorts.enumerated() {
                let a = NodeMetrics.inputAnchor(n, i)
                let d = hypot(a.x - p.x, a.y - p.y)
                if d < tolerance, best == nil || d < best!.d { best = (n.id, port, d) }
            }
        }
        return best.map { ($0.node, $0.port) }
    }

    // MARK: Factories

    static func make(_ kind: NodeKind) -> GraphNode {
        switch kind {
        case .message:   return .message(role: .system, content: "")
        case .prompt:    return .prompt(template: "{{prompt}}")
        case .nativeAPI: return .nativeAPI(op: .tokenizeWords, inputVar: "text", outputVar: "words", params: ["format": "numbered"])
        case .hook:      return .hook(op: .script, inputVar: "input", outputVar: "result", params: ["timeout": "30"])
        case .fm:        return .fm()
        }
    }

    /// A runnable demo: message(system) ← tokenized words ; prompt(sentence) → FM(guided gloss).
    /// Same shape as the old Single-shot gloss preset, but with the hidden hook→{{words}} coupling
    /// made an explicit, visible edge.
    static func exampleGloss() -> GraphDef {
        let sys = GraphNode.message(
            role: .system,
            content: """
            You are a German tutor; the learner's native language is English. Below is a German \
            sentence and a numbered list of its words. For EACH listed word, in order, give its single \
            best meaning in this sentence as one short English gloss. Then give a natural English \
            translation of the whole sentence.

            Words:
            {{words}}
            """,
            x: 60, y: 80, title: "System")
        let prompt = GraphNode.prompt(template: "{{sentence}}",
                                      statics: ["sentence": "Der Hund schläft."],
                                      x: 60, y: 360, title: "Sentence")
        let tok = GraphNode.nativeAPI(op: .tokenizeWords, inputVar: "text", outputVar: "words",
                                      params: ["format": "numbered"], x: 380, y: 380, title: "Tokenize words")
        let fm = GraphNode.fm(useGuidedGen: true, schemaDef: .glossLike, x: 700, y: 200, title: "Foundation Model")
        var g = GraphDef(nodes: [sys, prompt, tok, fm])
        g.edges = [
            GraphEdge(fromNodeID: prompt.id, outputKey: "prompt", toNodeID: tok.id, inputPort: "text"),
            GraphEdge(fromNodeID: tok.id,    outputKey: "words",  toNodeID: sys.id, inputPort: "words"),
            GraphEdge(fromNodeID: prompt.id, outputKey: "prompt", toNodeID: fm.id,  inputPort: "prompt"),
            GraphEdge(fromNodeID: sys.id,    outputKey: "message", toNodeID: fm.id, inputPort: "history"),
        ]
        return g
    }

    /// A multi-turn chat: message(system) → message(human) → message(ai) chained by `prev`, the last
    /// wired into the FM's `history` port; a prompt node supplies the current user turn. Demonstrates
    /// the "conversation is data on the canvas" model — no persistent session.
    static func exampleChat() -> GraphDef {
        let sys = GraphNode.message(role: .system,
            content: "You are a friendly barista at a Berlin café. Reply only in German, one short turn.",
            x: 60, y: 60, title: "System")
        let user1 = GraphNode.message(role: .human, content: "Guten Tag!", x: 60, y: 220, title: "User turn 1")
        let ai1 = GraphNode.message(role: .ai, content: "Guten Tag! Was darf es sein?", x: 60, y: 360, title: "AI turn 1")
        let prompt = GraphNode.prompt(template: "Einen Cappuccino, bitte.", x: 380, y: 360, title: "User turn 2")
        let fm = GraphNode.fm(x: 700, y: 240, title: "Foundation Model")
        var g = GraphDef(nodes: [sys, user1, ai1, prompt, fm])
        g.edges = [
            GraphEdge(fromNodeID: sys.id,   outputKey: "message", toNodeID: user1.id, inputPort: "prev"),
            GraphEdge(fromNodeID: user1.id, outputKey: "message", toNodeID: ai1.id,   inputPort: "prev"),
            GraphEdge(fromNodeID: ai1.id,   outputKey: "message", toNodeID: fm.id,    inputPort: "history"),
            GraphEdge(fromNodeID: prompt.id, outputKey: "prompt", toNodeID: fm.id,    inputPort: "prompt"),
        ]
        return g
    }
}
