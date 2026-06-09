//
//  GraphEngine.swift
//  Prompt Playground
//
//  @Observable view-model for the Graph tab: owns the live GraphDef, canvas transform, selection,
//  per-node run results, and the mutation API the canvas + inspector call. Instantiated as @State
//  in the tab root and fed the shared modelContext for save/load. Execution is delegated to
//  GraphExecutor.
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
    static let previewSlot: CGFloat = 70 // body band that shows a text block's content on the card

    static func rows(_ n: GraphNode) -> Int { max(n.inputPorts.count, n.outputKeys.count, 1) }

    /// The text a block shows on its card face (so the prompt is visible without opening the inspector),
    /// or nil for non-text nodes. Drives the preview band + whether a resize grip is offered.
    static func previewText(_ n: GraphNode) -> String? {
        let raw: String?
        switch n.kind {
        case .instruction: raw = n.instruction?.text
        case .history:     raw = n.history?.content
        case .current:     raw = n.current?.template
        case .tool:        raw = n.tool?.toolDescription
        case .fewshot:     raw = n.fewshot?.shots.first.map { "\($0.user) → \($0.assistant)" }
        default:           raw = nil
        }
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// Auto height with no manual override: header + ports + footer, plus a preview band for text blocks.
    static func autoHeight(_ n: GraphNode) -> CGFloat {
        header + CGFloat(rows(n)) * portSlot + footer + (previewText(n) != nil ? previewSlot : 0)
    }
    /// Floor for a manual resize — never smaller than the header + ports + footer.
    static func minHeight(_ n: GraphNode) -> CGFloat { header + CGFloat(rows(n)) * portSlot + footer }

    static func height(_ n: GraphNode) -> CGFloat {
        if let h = n.h { return max(minHeight(n), CGFloat(h)) }   // manual override (drag grip), clamped
        return autoHeight(n)
    }
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
    var selection: UUID? = nil { didSet { if selection != nil { selectedEdge = nil } } }  // node + edge selection are exclusive
    var selectedEdge: UUID? = nil      // a wire selected on the canvas (⌫ / context-menu deletes it)

    // Canvas transform (canvas → board: p*scale + offset).
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    var viewportSize: CGSize = .zero   // canvas pane size (written by GraphCanvas) — anchors button zoom

    // Run state.
    var isRunning = false
    var runs: [UUID: GraphNodeRun] = [:]
    var runError: String? = nil
    var lastTrace: ExecTrace? = nil    // the most recent execution's trace — GraphView persists it to Run History

    // Persistence link (which saved GraphModel is open).
    var loadedID: UUID? = nil

    // Transient wiring drag (canvas space). `pendingFrom` is a drag started at an OUTPUT port (seeking an
    // input); `pendingFromInput` is a drag started at an INPUT port (seeking an output) — wires connect
    // from either end. `pendingPoint` is the moving cursor end shared by both.
    var pendingFrom: (node: UUID, key: String)? = nil
    var pendingFromInput: (node: UUID, port: String)? = nil
    var pendingPoint: CGPoint? = nil

    // Click-to-connect: click an output port to ARM it, then click a target input to complete the wire
    // (the no-precision alternative to dragging a 11pt dot).
    var armedFrom: (node: UUID, key: String)? = nil

    // Group the block currently being dragged would drop into (drives the "+" frame affordance).
    var dropTargetGroup: UUID? = nil

    // The window's UndoManager (injected by GraphView). Structural edits snapshot the whole GraphDef
    // before mutating, so a single ⌘Z restores it. Kept out of @Observable tracking — it's plumbing.
    @ObservationIgnored var undoManager: UndoManager?

    init(graph: GraphDef = .init()) { self.graph = graph }

    // MARK: Undo (whole-graph snapshots)

    /// Record the CURRENT graph as the state a subsequent ⌘Z restores, then mutate. Call once per
    /// user-visible edit — at the START of a drag, or right before a discrete add/delete/connect.
    /// Batch ops (auto-wire) call it once for the whole batch. Pan/zoom/selection never snapshot.
    func snapshot() { registerUndoSnapshot(graph) }

    private func registerUndoSnapshot(_ previous: GraphDef) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { engine in
            let current = engine.graph          // capture for redo before we overwrite
            engine.applyUndoState(previous)
            engine.registerUndoSnapshot(current)  // registering inside undo turns it into redo
        }
    }

    private func applyUndoState(_ g: GraphDef) {
        graph = g
        if let s = selection, graph.node(s) == nil { selection = nil }
        if let e = selectedEdge, !graph.edges.contains(where: { $0.id == e }) { selectedEdge = nil }
    }

    var selectedNode: GraphNode? { selection.flatMap { sel in graph.nodes.first { $0.id == sel } } }
    var availabilityMessage: String? { ModelAvailability.message }

    // MARK: Validation (live; recomputed as the graph changes — see GraphValidator)

    /// Structural problems attributed to a single node (drives its canvas badge).
    func issues(for id: UUID) -> [GraphIssue] { GraphValidator.issues(for: id, in: graph) }
    /// All problems in one FM's pipeline (drives the FM inspector's warning section).
    func fmIssues(_ id: UUID) -> [GraphIssue] { GraphValidator.issues(forFM: id, in: graph) }
    /// Problems anywhere in a Prompt group — its own + its members' (so the frame reads "incomplete").
    func issues(inGroup groupID: UUID) -> [GraphIssue] {
        let ids = Set([groupID] + members(of: groupID).map(\.id))
        return GraphValidator.issues(in: graph).filter { ids.contains($0.nodeID) }
    }

    func index(_ id: UUID) -> Int? { graph.nodes.firstIndex { $0.id == id } }

    // MARK: Mutation

    func addNode(_ kind: NodeKind, at p: CGPoint) {
        snapshot()
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
        let before = graph                              // one undo step for the whole batch
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
        if made > 0 { registerUndoSnapshot(before) }
        return made
    }

    func deleteSelection() { if let id = selection { deleteNode(id) } }

    /// Clone the selected node (new id, nudged position), keeping a block's group membership. Edges are
    /// not copied — the clone starts unwired. A duplicated Prompt group starts empty (members aren't deep-copied).
    func duplicateSelection() {
        guard let id = selection, var n = graph.node(id) else { return }
        snapshot()
        n.id = UUID()
        n.x += 36; n.y += 36
        graph.nodes.append(n)
        selection = n.id
    }

    func deleteNode(_ id: UUID) {
        snapshot()
        // Deleting a Prompt group orphans its members (they keep groupID pointing at nothing) — clear it
        // so they become free blocks again rather than invisible ghosts.
        if graph.node(id)?.kind == .promptGroup {
            for i in graph.nodes.indices where graph.nodes[i].groupID == id { graph.nodes[i].groupID = nil }
        }
        graph.nodes.removeAll { $0.id == id }
        graph.edges.removeAll { $0.fromNodeID == id || $0.toNodeID == id }
        if selection == id { selection = nil }
        runs[id] = nil
    }

    func move(_ id: UUID, to p: CGPoint) {
        if let i = index(id) { graph.nodes[i].x = p.x; graph.nodes[i].y = p.y }
    }

    /// Set a node's manual card height (drag the resize grip), clamped to its content floor.
    func resizeNode(_ id: UUID, to h: CGFloat) {
        if let i = index(id) { graph.nodes[i].h = Double(max(NodeMetrics.minHeight(graph.nodes[i]), h)) }
    }

    /// Connect an upstream output key into a downstream input port (one edge per input port).
    func connect(from: UUID, key: String, to: UUID, port: String) {
        guard from != to else { return }
        graph.edges.removeAll { $0.toNodeID == to && $0.inputPort == port }
        graph.edges.append(GraphEdge(fromNodeID: from, outputKey: key, toNodeID: to, inputPort: port))
    }

    func deleteEdge(_ id: UUID) { graph.edges.removeAll { $0.id == id } }

    func selectEdge(_ id: UUID) { selectedEdge = id; selection = nil }

    /// ⌫ / Delete: remove the selected wire if one is selected, else the selected node.
    func deleteSelectionOrEdge() {
        if let e = selectedEdge { snapshot(); deleteEdge(e); selectedEdge = nil }
        else { deleteSelection() }
    }

    /// The two canvas-space endpoints of an edge (output side, input side), or nil if either is missing.
    /// Shared by the edge renderer and the edge hit-test layer so the visible curve and the click target
    /// are always the same geometry. A Prompt group's output anchors at its frame's right edge.
    func edgeAnchors(_ e: GraphEdge) -> (out: CGPoint, in: CGPoint)? {
        guard let from = graph.node(e.fromNodeID), let to = graph.node(e.toNodeID),
              let i = to.inputPorts.firstIndex(of: e.inputPort) else { return nil }
        let outP: CGPoint
        if from.kind == .promptGroup {
            guard let a = groupOutAnchor(from.id) else { return nil }
            outP = a
        } else {
            guard let j = from.outputKeys.firstIndex(of: e.outputKey) else { return nil }
            outP = NodeMetrics.outputAnchor(from, j)
        }
        return (outP, NodeMetrics.inputAnchor(to, i))
    }

    /// Remove the edge feeding a given input port (double-click an input port dot to unwire).
    func disconnect(to id: UUID, port: String) {
        graph.edges.removeAll { $0.toNodeID == id && $0.inputPort == port }
    }

    func isConnected(_ id: UUID, port: String) -> Bool {
        graph.edges.contains { $0.toNodeID == id && $0.inputPort == port }
    }

    // MARK: Click-to-connect + manual source picking

    /// Click an output port: arm it (or disarm if it's already the armed one).
    func armOutput(node: UUID, key: String) {
        if let a = armedFrom, a.node == node, a.key == key { armedFrom = nil }
        else { armedFrom = (node, key); selection = node }
    }
    func cancelArm() { armedFrom = nil }

    /// Click a target input while a wire is armed → complete it. Returns false if nothing was armed
    /// (so the caller can fall back to selecting the node).
    @discardableResult
    func completeArm(to node: UUID, port: String) -> Bool {
        guard let a = armedFrom, a.node != node else { return false }
        snapshot()
        connect(from: a.node, key: a.key, to: node, port: port)
        armedFrom = nil
        return true
    }

    /// Nodes that output a value named `port` (so they can feed that input by name) — drives the
    /// inspector's per-port source dropdown.
    func producers(of port: String, excluding id: UUID) -> [GraphNode] {
        graph.nodes.filter { $0.id != id && $0.outputKeys.contains(port) }
    }

    /// Manual wire from the inspector: snapshot + connect (one edge per port).
    func wire(from: UUID, key: String, to: UUID, port: String) { snapshot(); connect(from: from, key: key, to: to, port: port) }
    /// Manual unwire from the inspector.
    func unwire(to id: UUID, port: String) { snapshot(); disconnect(to: id, port: port) }

    func displayTitle(_ id: UUID) -> String {
        guard let n = graph.node(id) else { return "?" }
        return n.title.isEmpty ? n.kind.label : n.title
    }

    /// Nearest OUTPUT port to a canvas point (for a wire dragged FROM an input port). A Prompt group's
    /// single "prompt" output anchors at its frame's right edge.
    func hitOutputPort(near p: CGPoint, tolerance: CGFloat = 26) -> (node: UUID, key: String)? {
        var best: (node: UUID, key: String, d: CGFloat)? = nil
        func consider(_ id: UUID, _ key: String, _ a: CGPoint) {
            let d = hypot(a.x - p.x, a.y - p.y)
            if d < tolerance, best == nil || d < best!.d { best = (id, key, d) }
        }
        for n in graph.nodes {
            if n.kind == .promptGroup {
                if let a = groupOutAnchor(n.id) { consider(n.id, "prompt", a) }
            } else {
                for (j, key) in n.outputKeys.enumerated() { consider(n.id, key, NodeMetrics.outputAnchor(n, j)) }
            }
        }
        return best.map { ($0.node, $0.key) }
    }

    // MARK: Run

    func run() async {
        guard !isRunning else { return }
        isRunning = true; runError = nil; runs = [:]; lastTrace = nil
        defer { isRunning = false }
        do {
            let result = try await GraphExecutor.run(graph) { run in self.runs[run.nodeID] = run }
            lastTrace = result.trace
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

    /// Frame the whole graph: scale + offset so every node card and Prompt-group frame fits the viewport
    /// with padding (capped at 100% so a tiny graph isn't blown up). Unlike "reset", this finds the work.
    func fitToView() {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        var rects = graph.nodes.filter { $0.kind != .promptGroup }.map(NodeMetrics.frame)
        for g in graph.nodes where g.kind == .promptGroup { if let r = groupRect(g.id) { rects.append(r) } }
        guard let first = rects.first else { return }
        let content = rects.dropFirst().reduce(first) { $0.union($1) }
        let pad: CGFloat = 60
        let s = min(viewportSize.width / (content.width + pad * 2),
                    viewportSize.height / (content.height + pad * 2))
        let newScale = min(max(s, Self.zoomRange.lowerBound), 1)
        offset = CGSize(width: viewportSize.width / 2 - content.midX * newScale,
                        height: viewportSize.height / 2 - content.midY * newScale)
        scale = newScale
    }

    // MARK: Connected-node navigation (prev / next)

    /// Nodes one hop away along the dataflow. Downstream follows outgoing edges (and a block → its group);
    /// upstream follows incoming edges (and a group → its member blocks). De-duplicated, order preserved.
    func adjacent(of id: UUID, downstream: Bool) -> [UUID] {
        var r: [UUID] = []
        if downstream {
            r += graph.edges.filter { $0.fromNodeID == id }.map(\.toNodeID)
            if let n = graph.node(id), n.kind.isBlock, let g = n.groupID { r.append(g) }
        } else {
            r += graph.edges.filter { $0.toNodeID == id }.map(\.fromNodeID)
            if graph.node(id)?.kind == .promptGroup { r += members(of: id).map(\.id) }
        }
        var seen = Set<UUID>()
        return r.filter { seen.insert($0).inserted }
    }

    func hasAdjacent(downstream: Bool) -> Bool {
        guard let id = selection else { return false }
        return !adjacent(of: id, downstream: downstream).isEmpty
    }

    /// Move the selection to a connected node (prev = upstream, next = downstream) and bring it into view.
    func selectAdjacent(downstream: Bool) {
        guard let id = selection else {
            if let first = graph.nodes.first { selection = first.id; centerOn(first.id) }
            return
        }
        guard let next = adjacent(of: id, downstream: downstream).first else { return }
        selection = next
        centerOn(next)
    }

    /// Pan (keeping zoom) so a node — or a Prompt group's frame — sits at the viewport center.
    func centerOn(_ id: UUID) {
        guard viewportSize.width > 0, let n = graph.node(id) else { return }
        let rect = n.kind == .promptGroup ? (groupRect(id) ?? NodeMetrics.frame(n)) : NodeMetrics.frame(n)
        offset = CGSize(width: viewportSize.width / 2 - rect.midX * scale,
                        height: viewportSize.height / 2 - rect.midY * scale)
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
        case .compare:     return .compare()
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

    /// A/B demo: ONE shared Input feeding TWO prompt groups (terse vs explainer) that differ only in their
    /// instruction, each into its own FM, plus a Compare node already referencing both lanes. Select the
    /// Compare node and "Run comparison" to see them side-by-side.
    static func exampleCompare() -> GraphDef {
        let input = GraphNode.input(source: .staticLiteral,
                                    statics: ["input": "Translate to English and explain: „Der Hund schläft.“"],
                                    x: 40, y: 320, title: "Shared input")

        let groupA = GraphNode.promptGroup(title: "Prompt A · terse", x: 360, y: 40)
        let instrA = GraphNode.instruction("You are a terse translator. Reply with ONLY the English translation, nothing else.",
                                           groupID: groupA.id, x: 420, y: 120, title: "Instruction A")
        let currentA = GraphNode.current(template: "{{input}}", groupID: groupA.id, x: 420, y: 280, title: "Current A")
        let fmA = GraphNode.fm(x: 760, y: 120, title: "FM A")

        let groupB = GraphNode.promptGroup(title: "Prompt B · explainer", x: 360, y: 420)
        let instrB = GraphNode.instruction("You are a friendly German tutor. Give the English translation, then one short sentence on the grammar.",
                                           groupID: groupB.id, x: 420, y: 500, title: "Instruction B")
        let currentB = GraphNode.current(template: "{{input}}", groupID: groupB.id, x: 420, y: 660, title: "Current B")
        let fmB = GraphNode.fm(x: 760, y: 500, title: "FM B")

        let compare = GraphNode.compare(laneGroupIDs: [groupA.id, groupB.id], x: 1060, y: 300, title: "Compare A/B")

        var g = GraphDef(nodes: [input, groupA, instrA, currentA, fmA, groupB, instrB, currentB, fmB, compare])
        g.edges = [
            GraphEdge(fromNodeID: input.id,  outputKey: "input",  toNodeID: currentA.id, inputPort: "input"),
            GraphEdge(fromNodeID: input.id,  outputKey: "input",  toNodeID: currentB.id, inputPort: "input"),
            GraphEdge(fromNodeID: groupA.id, outputKey: "prompt", toNodeID: fmA.id,       inputPort: "prompt"),
            GraphEdge(fromNodeID: groupB.id, outputKey: "prompt", toNodeID: fmB.id,       inputPort: "prompt"),
        ]
        return g
    }
}
