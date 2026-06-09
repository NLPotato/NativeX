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

// MARK: - Wired-input mapping (one resolved incoming edge, for the inspector's "Wired inputs" view)

struct WiredInput: Identifiable {
    var id: String { port }          // one edge per input port (enforced by GraphEngine.connect)
    let port: String                 // input port on the selected node
    let sourceTitle: String          // upstream node's display title
    let sourceKey: String            // upstream output key feeding this port
    let value: String?               // value carried on the edge after a run (nil before)
}

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

    /// Canvas-space rect a single node card occupies (mirrors how GraphCanvas places it).
    static func frame(_ n: GraphNode) -> CGRect { CGRect(x: n.x, y: n.y, width: width, height: height(n)) }
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
    var viewportSize: CGSize = .zero   // canvas pane size (written by GraphCanvas) — anchors button zoom

    // Run state.
    var isRunning = false
    var runs: [UUID: GraphNodeRun] = [:]
    var runError: String? = nil

    // Persistence link (which saved GraphModel is open).
    var loadedID: UUID? = nil

    // Transient wiring drag (canvas space).
    var pendingFrom: (node: UUID, key: String)? = nil
    var pendingPoint: CGPoint? = nil

    // Group the block currently being dragged would drop into (drives the "+" frame affordance).
    var dropTargetGroup: UUID? = nil

    init(graph: GraphDef = .init()) { self.graph = graph }

    var selectedNode: GraphNode? { selection.flatMap { sel in graph.nodes.first { $0.id == sel } } }
    var availabilityMessage: String? { ModelAvailability.message }

    func index(_ id: UUID) -> Int? { graph.nodes.firstIndex { $0.id == id } }

    // MARK: Mutation

    func addNode(_ kind: NodeKind, at p: CGPoint) {
        var n = GraphEngine.make(kind)
        // Adding a block while a Prompt group is selected drops it INTO that group, stacked below its
        // current members so it lands inside the frame (not floating at the cursor as an orphan member).
        if kind.isBlock, let sel = selection, graph.node(sel)?.kind == .promptGroup {
            n.groupID = sel
            let ms = members(of: sel)
            if let lowest = ms.map({ $0.y + NodeMetrics.height($0) }).max(), let x = ms.map(\.x).min() {
                n.x = x; n.y = lowest + 20
            } else if let g = graph.node(sel) {
                n.x = g.x + 60; n.y = g.y + GraphEngine.groupHeader + 20
            }
        } else {
            n.x = p.x; n.y = p.y
        }
        graph.nodes.append(n)
        selection = n.id
    }

    /// Canvas-space point at the center of the visible pane — where menu/hotkey-added nodes appear.
    var viewportCenterCanvas: CGPoint {
        toCanvas(CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2))
    }

    /// Connect every UNCONNECTED input port `{{x}}` to a node that outputs `x` (preferring an Input node).
    /// Variables match by NAME — the dominant LLM-ops case (an Input's `learning` → a block's `{{learning}}`,
    /// a Prompt group's `prompt` → an FM's prompt port). Returns how many edges it made.
    @discardableResult
    func autoWireMatchingVars() -> Int {
        var producers: [String: [GraphNode]] = [:]
        for n in graph.nodes {
            for key in n.outputKeys { producers[key, default: []].append(n) }
        }
        var made = 0
        for n in graph.nodes {
            for port in n.inputPorts where !isConnected(n.id, port: port) {
                let cands = (producers[port] ?? []).filter { $0.id != n.id }
                guard let pick = cands.first(where: { $0.kind == .input }) ?? cands.first else { continue }
                connect(from: pick.id, key: port, to: n.id, port: port)
                made += 1
            }
        }
        return made
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

    static let zoomRange: ClosedRange<CGFloat> = 0.3...2.5

    /// Multiply the zoom by `factor`, keeping the board point `p` stationary under the cursor.
    func zoom(by factor: CGFloat, around p: CGPoint) {
        let newScale = min(max(scale * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        guard newScale != scale else { return }
        let k = newScale / scale
        offset = CGSize(width: p.x - (p.x - offset.width) * k,
                        height: p.y - (p.y - offset.height) * k)
        scale = newScale
    }

    private var viewportCenter: CGPoint { CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2) }
    func zoomIn()  { zoom(by: 1.15, around: viewportCenter) }
    func zoomOut() { zoom(by: 1 / 1.15, around: viewportCenter) }

    /// Each incoming edge resolved for display: which upstream node/output feeds an input port,
    /// plus the value carried on that edge after a run. Drives the inspector's "Wired inputs" map.
    func incomingMap(_ id: UUID) -> [WiredInput] {
        graph.incoming(id).map { e in
            let src = graph.node(e.fromNodeID)
            let title = (src?.title.isEmpty == false ? src?.title : src?.kind.label) ?? "?"
            return WiredInput(port: e.inputPort, sourceTitle: title,
                              sourceKey: e.outputKey, value: runs[e.fromNodeID]?.outputs[e.outputKey])
        }
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

    // MARK: Prompt groups (the framed container; membership = groupID)

    static let groupPad: CGFloat = 30      // breathing room around members (generous, so blocks aren't cramped)
    static let groupHeader: CGFloat = 30   // canvas-space header band reserved ABOVE the members
    static let groupDropMargin: CGFloat = 80  // how far OUTSIDE the frame a block still counts as "in" — generous
                                              // catch when dropping in, and hysteresis so repositioning never expels

    func members(of groupID: UUID) -> [GraphNode] { graph.nodes.filter { $0.groupID == groupID } }

    /// The frame enclosing a group's members (canvas space); the group node's own x/y/size when empty.
    func groupRect(_ groupID: UUID) -> CGRect? {
        guard let g = graph.node(groupID), g.kind == .promptGroup else { return nil }
        return frameRect(members(of: groupID).map(NodeMetrics.frame), group: g)
    }

    /// Same rect EXCLUDING one node — for drop-in/out hit-testing without a member containing itself.
    func rectExcluding(_ excluded: UUID, in groupID: UUID) -> CGRect? {
        guard let g = graph.node(groupID), g.kind == .promptGroup else { return nil }
        return frameRect(members(of: groupID).filter { $0.id != excluded }.map(NodeMetrics.frame), group: g)
    }

    private func frameRect(_ rects: [CGRect], group g: GraphNode) -> CGRect {
        guard let first = rects.first else {
            return CGRect(x: g.x, y: g.y, width: g.group?.width ?? 320, height: g.group?.height ?? 160)
        }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        let p = GraphEngine.groupPad
        return CGRect(x: union.minX - p, y: union.minY - p - GraphEngine.groupHeader,
                      width: union.width + p * 2, height: union.height + p * 2 + GraphEngine.groupHeader)
    }

    /// Canvas-space anchor of a group's single "out" port (right edge of the frame, mid-height).
    func groupOutAnchor(_ groupID: UUID) -> CGPoint? {
        groupRect(groupID).map { CGPoint(x: $0.maxX, y: $0.midY) }
    }

    /// The GENEROUS drop zone of a group for a block being dragged — the frame (excluding that block,
    /// so it can leave) expanded by a wide margin. The margin gives an easy catch when dropping a block
    /// in, and hysteresis so nudging a member around inside never accidentally expels it.
    func dropZone(_ groupID: UUID, excluding id: UUID) -> CGRect? {
        rectExcluding(id, in: groupID).map { $0.insetBy(dx: -GraphEngine.groupDropMargin, dy: -GraphEngine.groupDropMargin) }
    }

    /// Which group a dragged block belongs to, by its center. Sticky: a current member stays as long as
    /// it's within its (generous) zone, so you can freely reposition it; only a clear drag-away leaves.
    func dropGroup(for id: UUID) -> UUID? {
        guard let n = graph.node(id), n.kind.isBlock else { return nil }
        let c = CGPoint(x: n.x + NodeMetrics.width / 2, y: n.y + NodeMetrics.height(n) / 2)
        if let g = n.groupID, dropZone(g, excluding: id)?.contains(c) ?? false { return g }
        return graph.nodes.first { $0.kind == .promptGroup && (dropZone($0.id, excluding: id)?.contains(c) ?? false) }?.id
    }

    /// Live during a block drag: update its group membership + the highlighted drop target.
    func updateGroupDrag(_ id: UUID) {
        guard let i = index(id), graph.nodes[i].kind.isBlock else { return }
        let target = dropGroup(for: id)
        graph.nodes[i].groupID = target
        dropTargetGroup = target
    }
    func endGroupDrag() { dropTargetGroup = nil }

    // MARK: Factories

    static func make(_ kind: NodeKind) -> GraphNode {
        switch kind {
        case .promptGroup: return .promptGroup()
        case .instruction: return .instruction("You are a helpful assistant.")
        case .fewshot:     return .fewshot([FewShot()])
        case .history:     return .history(role: .human, content: "")
        case .current:     return .current(template: "{{input}}")
        case .guided:      return .guided(.glossLike)
        case .tool:        return .tool(name: "", description: "")
        case .input:       return .input(source: .staticLiteral, statics: ["input": ""])
        case .nativeAPI:   return .nativeAPI(op: .tokenizeWords, inputVar: "text", outputVar: "words", params: ["format": "numbered"])
        case .hook:        return .hook(op: .script, inputVar: "input", outputVar: "result", params: ["timeout": "30"])
        case .fm:          return .fm()
        }
    }

    /// Single-shot gloss as a Prompt group: instruction (NO data) + current turn (the sentence + its
    /// numbered words — the data lives in the USER turn) + guided schema, all wired from an Input node
    /// (the sentence) through a deterministic tokenizer. The FM consumes the group as one unit.
    static func exampleGloss() -> GraphDef {
        let group = GraphNode.promptGroup(title: "Prompt", x: 380, y: 40)
        let instr = GraphNode.instruction("""
            You are a German tutor; the learner's native language is English. For EACH numbered word in \
            the user's turn, in order, give its single best meaning in this sentence as one short English \
            gloss. Then give a natural English translation of the whole sentence.
            """, groupID: group.id, x: 440, y: 120, title: "Instruction")
        let current = GraphNode.current(template: "Sentence: {{sentence}}\n\nWords:\n{{words}}",
                                        groupID: group.id, x: 440, y: 400, title: "Current turn")
        let guided = GraphNode.guided(.glossLike, groupID: group.id, x: 720, y: 400, title: "Guided output")
        let input = GraphNode.input(source: .staticLiteral, statics: ["sentence": "Der Hund schläft."],
                                    x: 40, y: 300, title: "Sentence")
        let tok = GraphNode.nativeAPI(op: .tokenizeWords, inputVar: "text", outputVar: "words",
                                      params: ["format": "numbered"], x: 40, y: 520, title: "Tokenize words")
        let fm = GraphNode.fm(x: 1020, y: 240, title: "Foundation Model")
        var g = GraphDef(nodes: [group, instr, current, guided, input, tok, fm])
        g.edges = [
            GraphEdge(fromNodeID: input.id, outputKey: "sentence", toNodeID: tok.id,     inputPort: "text"),
            GraphEdge(fromNodeID: input.id, outputKey: "sentence", toNodeID: current.id, inputPort: "sentence"),
            GraphEdge(fromNodeID: tok.id,   outputKey: "words",    toNodeID: current.id, inputPort: "words"),
            GraphEdge(fromNodeID: group.id, outputKey: "prompt",   toNodeID: fm.id,      inputPort: "prompt"),
        ]
        return g
    }

    /// Multi-turn chat as a Prompt group: instruction + two PAST history turns (human/ai) + a current
    /// turn fed by an Input node. The FM consumes the group; no persistent session.
    static func exampleChat() -> GraphDef {
        let group = GraphNode.promptGroup(title: "Prompt", x: 380, y: 40)
        let instr = GraphNode.instruction("You are a friendly barista at a Berlin café. Reply only in German, one short turn.",
                                          groupID: group.id, x: 440, y: 120, title: "Instruction")
        let h1 = GraphNode.history(role: .human, content: "Guten Tag!", groupID: group.id, x: 440, y: 280, title: "History · human")
        let h2 = GraphNode.history(role: .ai, content: "Guten Tag! Was darf es sein?", groupID: group.id, x: 440, y: 400, title: "History · ai")
        let current = GraphNode.current(template: "{{input}}", groupID: group.id, x: 440, y: 520, title: "Current turn")
        let input = GraphNode.input(source: .staticLiteral, statics: ["input": "Einen Cappuccino, bitte."],
                                    x: 40, y: 520, title: "User input")
        let fm = GraphNode.fm(x: 780, y: 300, title: "Foundation Model")
        var g = GraphDef(nodes: [group, instr, h1, h2, current, input, fm])
        g.edges = [
            GraphEdge(fromNodeID: input.id, outputKey: "input",  toNodeID: current.id, inputPort: "input"),
            GraphEdge(fromNodeID: group.id, outputKey: "prompt", toNodeID: fm.id,      inputPort: "prompt"),
        ]
        return g
    }
}
