//
//  GraphCanvas.swift
//  Prompt Playground
//
//  The pannable/zoomable node board. Everything is drawn in CANVAS coordinates inside one layer that
//  is scaled + offset as a whole (so node positions and edge anchors share one coordinate space and
//  there's no per-node transform math). Edges are Bézier curves in a Canvas underlay; nodes are cards
//  with input ports (left) / output ports (right). Drag an output port to wire it to an input port.
//

import SwiftUI
import SwiftData
import AppKit

let graphBoardSpace = "graphboard"

/// Identifiable wrapper so a bare node UUID can drive a `.sheet(item:)` (the compare config sheet).
private struct CanvasSheetID: Identifiable { let id: UUID }

/// Category color per node FAMILY (design.md §5.2) — the 30% budget. Used on the node icon, the header
/// wash, the selected border/glow, and selection-adjacent wires. Never applied as a solid fill.
func kindTint(_ kind: NodeKind) -> Color {
    switch kind {
    case .promptGroup: return Theme.accent                  // container — accent identity on selection
    case .instruction, .fewshot, .history, .current:
        return Theme.cyan                                   // prompt blocks — dsInfo
    case .guided, .tool: return Theme.cyan.opacity(0.6)     // schema/tool blocks — dsInfo @ 60%
    case .input:       return .gray                         // data source — neutral, no category color
    case .nativeAPI:   return .gray                         // utility — neutral (the cyan badge carries the hue)
    case .hook:        return Theme.gold                    // developer/power — macOS-only gold
    case .fm:          return Theme.accent                  // execution — accent + radiance
    case .compare:     return Theme.pink                    // analysis — pink
    }
}

struct GraphCanvas: View {
    @Bindable var engine: GraphEngine
    var onRun: () -> Void = {}            // logs the finished run to Run History (GraphView.persistRun)
    var batch: GraphBatchRunner? = nil    // dataset batch lane (non-nil ⇒ an Input is dataset-bound)
    var boundDataset: DatasetModel? = nil
    var onRunDataset: () -> Void = {}
    var onOpenLab: () -> Void = {}        // batch summary "View in Lab" → switch to the Lab tab

    @State private var panStart: CGSize? = nil
    @State private var zoomStart: CGFloat? = nil

    /// The compare node the current result belongs to (matches by referenced lane group ids) — anchors the
    /// on-canvas lane cards beneath it.
    private var compareAnchor: GraphNode? {
        guard let outcome = engine.compareOutcome else { return nil }
        let laneIDs = Set(outcome.lanes.map(\.id))
        return engine.graph.nodes.first {
            $0.kind == .compare && !Set($0.compare?.laneGroupIDs ?? []).isDisjoint(with: laneIDs)
        }
    }

    var body: some View {
        // GeometryReader + explicit frame so the huge edge Canvas (below) can't drive the pane's
        // intrinsic size; the oversized scaled layer simply overflows and is clipped.
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Background — captures pan / zoom / deselect.
                Color(nsColor: .underPageBackgroundColor)
                    .contentShape(Rectangle())
                    .onTapGesture { engine.clearSelection(); engine.selectedEdge = nil; engine.cancelArm() }
                    .gesture(pan)
                    .simultaneousGesture(zoom)

                // Scaled content layer (canvas space). Group frames paint FIRST (behind edges + cards),
                // then wires, then the wire hit-targets, then the node cards (which win any overlap).
                ZStack(alignment: .topLeading) {
                    GroupFrameLayer(engine: engine)
                    EdgeLayer(engine: engine)
                    EdgeHitLayer(engine: engine)
                    ForEach(engine.graph.nodes.filter { $0.kind != .promptGroup }) { node in
                        NodeCardView(engine: engine, node: node)
                            .frame(width: NodeMetrics.width(node), height: NodeMetrics.height(node), alignment: .topLeading)
                            .offset(x: node.x, y: node.y)
                            // Hover/selection lift the card above overlapping neighbors — z-order only, so the
                            // analytic port anchors don't move and wires stay glued (never .scaleEffect the card).
                            .zIndex(engine.hoveredNode == node.id ? 3 : (engine.selection == node.id ? 2 : 0))
                    }
                    // Single-run result: a white, full-opacity card beside the terminal FM (NOT a graph node;
                    // view-only, never in GraphDef / topo / exec). Lives in the scaled layer so it pans+zooms.
                    if let fm = engine.terminalFM, let text = engine.singleRunOutput, !engine.resultCardDismissed {
                        let f = NodeMetrics.frame(fm)
                        CanvasResultCard(engine: engine, text: text)
                            .offset(x: f.maxX + 28 + engine.resultCardOffset.width,
                                    y: f.minY + engine.resultCardOffset.height)
                            .zIndex(5)
                    }
                    // Compare results: side-by-side lane cards beneath the compare node (view-only overlay),
                    // tethered to the node by a dashed connector so the link is unmistakable.
                    if let outcome = engine.compareOutcome, let anchor = compareAnchor {
                        let cf = NodeMetrics.frame(anchor)
                        let off = engine.compareCardsOffset
                        let top = CGPoint(x: cf.minX + off.width, y: cf.maxY + 22 + off.height)
                        CompareLinkLine(from: CGPoint(x: cf.midX, y: cf.maxY),
                                        to: CGPoint(x: top.x + 26, y: top.y))
                            .zIndex(5)
                        CompareResultCluster(engine: engine, outcome: outcome)
                            .offset(x: top.x, y: top.y)
                            .zIndex(6)
                    }
                }
                .scaleEffect(engine.scale, anchor: .topLeading)
                .offset(engine.offset)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .background(ScrollZoomMonitor { factor, p in engine.zoom(by: factor, around: p) })
            .clipped()
            .contentShape(Rectangle())
            .coordinateSpace(name: graphBoardSpace)
            .onDeleteCommand { engine.deleteSelectionOrEdge() }
            .onChange(of: geo.size, initial: true) { _, size in engine.viewportSize = size }
            // ALL floating chrome lives in ONE overlay inside a GlassEffectContainer, so co-located glass
            // surfaces merge into a single optical piece instead of stacking (design.md §3.5 glass-on-glass
            // rule). Empty space in the ZStack stays transparent → canvas gestures pass through.
            .overlay {
                GlassEffectContainer {
                    ZStack {
                        // The primary action — a prominent accent Run pill, bottom-left (⌘↩), pulled out of
                        // the top toolbar so the most important command lives on the canvas and stands out.
                        CanvasRunControl(engine: engine, onRun: onRun, batch: batch,
                                         boundDataset: boundDataset, onRunDataset: onRunDataset)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        // Figma/Photoshop-style floating bar — actions for the selection, bottom-center.
                        CanvasContextBar(engine: engine)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        // Zoom control in the corner (Figma/Adobe convention) — keeps the toolbar uncluttered.
                        CanvasZoomControl(engine: engine)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        // Live run feedback: the executing node (top-center pill) + run errors (top-right toast).
                        CanvasRunningPill(engine: engine)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        CanvasErrorToast(engine: engine)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        // Batch completion summary (top-left), deep-linking to the Lab sweep.
                        if let batch {
                            CanvasBatchSummaryCard(batch: batch, onOpenLab: onOpenLab)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                    .padding(DS.Space.lg)
                }
            }
            // Compare config sheet — opened by double-clicking a .compare node (clear guidance + lanes + Run).
            .sheet(item: Binding(
                get: { engine.compareConfigFor.map(CanvasSheetID.init) },
                set: { engine.compareConfigFor = $0?.id }
            )) { item in
                CompareConfigSheet(engine: engine, nodeID: item.id)
            }
        }
    }

    private var pan: some Gesture {
        DragGesture(coordinateSpace: .named(graphBoardSpace))
            .onChanged { v in
                if panStart == nil { panStart = engine.offset }
                let base = panStart ?? .zero
                engine.offset = CGSize(width: base.width + v.translation.width,
                                       height: base.height + v.translation.height)
            }
            .onEnded { _ in panStart = nil }
    }

    private var zoom: some Gesture {
        MagnificationGesture()
            .onChanged { val in
                if zoomStart == nil { zoomStart = engine.scale }
                let base = zoomStart ?? 1
                engine.scale = min(max(base * val, 0.3), 2.5)
            }
            .onEnded { _ in zoomStart = nil }
    }
}

// MARK: - Edges

/// The S-curve between two canvas-space anchors (output `a` → input `b`). Shared by the renderer
/// (EdgeLayer) and the hit layer (EdgeHitLayer) so the drawn wire and its click target are identical.
///
/// The control offset is horizontal (ports exit right / enter left). For FORWARD edges (target to the
/// right) it's half the gap — a clean S. For BACKWARD edges (target dragged to the LEFT of the source)
/// a linear offset overshoots and the curve tangles into a cusp; a sqrt-scaled offset (ReactFlow's
/// trick) keeps the loop bounded and rounded instead. Fixes "the edge breaks when I move a node."
func graphEdgeCurve(_ a: CGPoint, _ b: CGPoint) -> Path {
    let dx = b.x - a.x
    let offset: CGFloat = dx >= 0 ? dx * 0.5 : 6.25 * sqrt(-dx)   // 6.25 = curvature(0.25) × 25
    var p = Path()
    p.move(to: a)
    p.addCurve(to: b, control1: CGPoint(x: a.x + offset, y: a.y), control2: CGPoint(x: b.x - offset, y: b.y))
    return p
}

private struct EdgeLayer: View {
    @Bindable var engine: GraphEngine

    var body: some View {
        // The hue of the selected node — selection-touching wires adopt it so the local topology reads in
        // one colour instead of everything defaulting to green.
        let selTint = engine.selection.flatMap { engine.graph.node($0) }.map { kindTint($0.kind) } ?? Theme.accent
        return Canvas { ctx, _ in
            for edge in engine.graph.edges {
                guard let (a, b) = engine.edgeAnchors(edge) else { continue }
                // A selected wire is the ONE bright edge; otherwise muted chrome, brightened in the selected
                // node's hue when it touches the selection so the topology you're editing stands out.
                let selected = engine.selectedEdge == edge.id
                let touchesSelection = engine.selection != nil
                    && (edge.fromNodeID == engine.selection || edge.toNodeID == engine.selection)
                let style: GraphicsContext.Shading = selected
                    ? .color(Theme.accent)
                    : (touchesSelection ? .color(selTint.opacity(0.9)) : .color(.white.opacity(0.18)))
                ctx.stroke(graphEdgeCurve(a, b), with: style, lineWidth: selected ? 3 : (touchesSelection ? 2.5 : 1.5))
            }
            // Pending wire while dragging from a port — from an output (a→cursor) or an input (cursor→a).
            if let pt = engine.pendingPoint {
                let dash = StrokeStyle(lineWidth: 2, dash: [6, 4])
                if let pf = engine.pendingFrom, let a = pendingOutputAnchor(pf) {
                    ctx.stroke(graphEdgeCurve(a, pt), with: .color(Theme.accent.opacity(0.5)), style: dash)
                } else if let pi = engine.pendingFromInput, let a = pendingInputAnchor(pi) {
                    ctx.stroke(graphEdgeCurve(pt, a), with: .color(Theme.accent.opacity(0.5)), style: dash)
                }
            }
        }
        .frame(width: 8000, height: 8000, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func pendingOutputAnchor(_ pf: (node: UUID, key: String)) -> CGPoint? {
        guard let n = engine.graph.node(pf.node) else { return nil }
        if n.kind == .promptGroup { return engine.groupOutAnchor(n.id) }
        guard let j = n.outputKeys.firstIndex(of: pf.key) else { return nil }
        return NodeMetrics.outputAnchor(n, j)
    }
    private func pendingInputAnchor(_ pi: (node: UUID, port: String)) -> CGPoint? {
        guard let n = engine.graph.node(pi.node), let i = n.inputPorts.firstIndex(of: pi.port) else { return nil }
        return NodeMetrics.inputAnchor(n, i)
    }
}

/// Transparent thick hit targets over each wire, so an edge can be clicked to select it (then ⌫ to
/// delete) or right-clicked for a Delete menu. Painted above the visual EdgeLayer but below the node
/// cards, so a node always wins where they overlap; in the empty space between nodes the wire is hittable.
private struct EdgeHitLayer: View {
    @Bindable var engine: GraphEngine

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(engine.graph.edges) { edge in
                if let (a, b) = engine.edgeAnchors(edge) {
                    let path = graphEdgeCurve(a, b)
                    path.stroke(Color.white.opacity(0.001), lineWidth: 16)
                        .contentShape(path.strokedPath(StrokeStyle(lineWidth: 16, lineCap: .round)))
                        .onTapGesture { engine.selectEdge(edge.id) }
                        .contextMenu {
                            Button(role: .destructive) {
                                engine.snapshot(); engine.deleteEdge(edge.id)
                                if engine.selectedEdge == edge.id { engine.selectedEdge = nil }
                            } label: { Label("Delete wire", systemImage: "scissors") }
                        }
                }
            }
        }
        .frame(width: 8000, height: 8000, alignment: .topLeading)
    }
}

// MARK: - Node card

private struct NodeCardView: View {
    @Bindable var engine: GraphEngine
    let node: GraphNode

    @State private var dragStarts: [UUID: CGPoint]? = nil   // start positions for a (possibly multi-) node drag
    @State private var resizeStart: CGSize? = nil
    @State private var hoveredInput: String? = nil    // port currently hovered → grows its chip + dot
    @State private var hoveredOutput: String? = nil
    @State private var editingTitle = false
    @FocusState private var titleFocused: Bool

    private var run: GraphNodeRun? { engine.runs[node.id] }
    private var selected: Bool { engine.isNodeSelected(node.id) }   // primary OR part of a multi-selection
    private var nodeHovered: Bool { engine.hoveredNode == node.id }
    private var issues: [GraphIssue] { engine.issues(for: node.id) }   // pre-run structural problems

    /// Compact "header chip" nodes (design.md §5.1/§5.2): no heavy content → the card is one glass piece.
    private var isGlassChip: Bool {
        switch node.kind {
        case .input, .nativeAPI, .hook, .compare: return true
        default: return false
        }
    }

    var body: some View {
        surfaced
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
            .strokeBorder(borderColor, lineWidth: selected ? 2.5 : 1))
        .runningRadiance(active: run?.status == .running, corner: DS.Radius.md)   // the running node blooms
        .shadow(color: selected ? tint.opacity(0.55) : .black.opacity(0.28),
                radius: selected ? 12 : 4, y: selected ? 0 : 2)   // selected node lifts off the board
        .overlay(alignment: .topLeading) { portDots }
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        .contentShape(Rectangle())
        .onHover { engine.hoveredNode = $0 ? node.id : (engine.hoveredNode == node.id ? nil : engine.hoveredNode) }
        .onTapGesture(count: 2) {
            engine.selectOnly(node.id)
            // Compare nodes open a clear config sheet (not the generic inspector) — guidance + lanes + Run.
            if node.kind == .compare { engine.compareConfigFor = node.id } else { engine.showInspector = true }
        }
        .onTapGesture {
            // Shift+click extends the selection (multi-select); a plain click replaces it.
            if NSEvent.modifierFlags.contains(.shift) { engine.toggleSelect(node.id) } else { engine.selectOnly(node.id) }
        }
        .gesture(moveGesture)
    }

    /// §5.2 surface application: glass chip for compact nodes (selected = accent-of-kind tinted glass),
    /// opaque material card for content nodes — with the prompt-block cyan left stripe.
    @ViewBuilder private var surfaced: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
        if isGlassChip {
            content.glassEffect(selected ? .regular.tint(tint.opacity(0.16)) : .regular, in: shape)
        } else {
            content.background(
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(tint.opacity(selected ? 0.16 : 0.05)))   // kind identity wash
                    .overlay(alignment: .leading) {
                        if node.kind.isBlock {   // prompt-block identity stripe (§5.2)
                            Rectangle().fill(tint.opacity(0.8)).frame(width: 3)
                        }
                    }
                    .clipShape(shape)
            )
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.25)
            ForEach(0..<NodeMetrics.rows(node), id: \.self) { row in
                portRow(row).frame(height: NodeMetrics.portSlot)
            }
            if let preview = NodeMetrics.previewText(node) {
                promptBand(preview)
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(width: NodeMetrics.width(node), height: NodeMetrics.height(node), alignment: .topLeading)
    }

    /// Bottom-right corner grip: drag to freely resize the card in BOTH axes (width + height), each
    /// clamped to its floor. Available on every node, not just text blocks.
    private var resizeGrip: some View {
        Image(systemName: "arrow.down.right")
            .font(.dsMicro.weight(.bold)).foregroundStyle(.tertiary)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .named(graphBoardSpace))
                    .onChanged { v in
                        if resizeStart == nil {
                            engine.snapshot()
                            resizeStart = CGSize(width: NodeMetrics.width(node), height: NodeMetrics.height(node))
                        }
                        let s = resizeStart ?? .zero
                        engine.resizeNode(node.id, to: CGSize(width:  s.width  + v.translation.width  / engine.scale,
                                                              height: s.height + v.translation.height / engine.scale))
                    }
                    .onEnded { _ in resizeStart = nil; engine.settleLayout(after: [node.id]) }
            )
            .help("Drag to resize (width + height)")
    }

    private var tint: Color { kindTint(node.kind) }

    @ViewBuilder private var header: some View {
        let top = UnevenRoundedRectangle(topLeadingRadius: DS.Radius.md, topTrailingRadius: DS.Radius.md)
        let row = HStack(spacing: DS.Space.sm) {
            Image(systemName: node.kind.symbol)
                .font(.dsBody.weight(.semibold))
                .foregroundStyle(tint)                  // each kind's hue rides on its icon
                .frame(width: 22)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                // Line 1: the distinguishing NAME — user title, else a computed default. Double-click to rename.
                if editingTitle {
                    TextField("", text: titleBinding)
                        .textFieldStyle(.plain).font(.dsLabel).lineLimit(1).focused($titleFocused)
                        .onSubmit { editingTitle = false }
                        .onChange(of: titleFocused) { _, f in if !f { editingTitle = false } }
                } else {
                    Text(displayTitle)
                        .font(.dsLabel).lineLimit(1)
                        .foregroundStyle(.primary)
                        .onTapGesture(count: 2) { startTitleEdit() }
                }
                // Line 2: the STATIC node-type label ("Input", "Foundation Model", …). No third row — the
                // node body band already previews content, and the result card shows the run output.
                Text(node.kind.label).font(.dsMicro).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            statusDot
        }
        .padding(.horizontal, DS.Space.md)
        .frame(height: NodeMetrics.header, alignment: .center)

        if node.kind == .fm {
            row.glassEffect(.regular, in: top)   // glass header chip on an opaque body (§5.2)
        } else if isGlassChip {
            row                                  // the whole card is already one glass chip
        } else {
            row.background(tint.opacity(selected ? 0.18 : 0.10), in: top)   // colored header strip
        }
    }

    @ViewBuilder private var statusDot: some View {
        switch run?.status {
        case .ok:      Image(systemName: "checkmark.circle.fill").foregroundStyle(.dsSuccess).font(.dsCaption)
        case .error:   Image(systemName: "xmark.octagon.fill").foregroundStyle(.dsDanger).font(.dsCaption)
        case .running: ProgressView().controlSize(.mini)
        default:
            // No run yet: surface a structural problem so the user fixes it BEFORE pressing Run.
            if !issues.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.dsWarning).font(.dsCaption)
                    .help(issues.map(\.message).joined(separator: "\n"))
            }
        }
    }

    private func portRow(_ row: Int) -> some View {
        HStack(spacing: DS.Space.sm) {
            if row < node.inputPorts.count {
                let p = node.inputPorts[row]
                varChip(p, wired: engine.isConnected(node.id, port: p), hovered: hoveredInput == p)
            }
            Spacer(minLength: 0)
            if row < node.outputKeys.count {
                let k = node.outputKeys[row]
                let outWired = engine.graph.edges.contains { $0.fromNodeID == node.id && $0.outputKey == k }
                varChip(k, wired: outWired, hovered: hoveredOutput == k, output: true)
            }
        }
        .padding(.horizontal, DS.Space.md)
    }

    /// A port name rendered as a small monospaced "variable" pill — so it reads clearly as a wired variable,
    /// visually distinct from the prompt prose in the band below. Tints when wired/hovered and grows on hover
    /// (the requested "variable name gets bigger on hover" affordance).
    private func varChip(_ name: String, wired: Bool, hovered: Bool, output: Bool = false) -> some View {
        let active = wired || hovered
        return Text(name)
            .font(.dsCodeMicro.weight(.medium)).lineLimit(1)
            .foregroundStyle(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            .padding(.horizontal, DS.Space.xs).padding(.vertical, DS.Space.xxs)
            .background(Capsule().fill(active ? AnyShapeStyle(Theme.accent.opacity(0.16)) : AnyShapeStyle(.quaternary)))
            .overlay(Capsule().strokeBorder(active ? AnyShapeStyle(Theme.accent.opacity(0.4)) : AnyShapeStyle(.dsHairline), lineWidth: 0.8))
            .scaleEffect(hovered ? 1.12 : (nodeHovered ? 1.05 : 1), anchor: output ? .trailing : .leading)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.12), value: nodeHovered)
    }

    /// The block's content shown on the card face: a recessed band (separated from the variable lane above
    /// by a divider + darker fill) where {{var}} tokens are highlighted — so template variables read apart
    /// from the literal prompt prose (feedback #6).
    private func promptBand(_ text: String) -> some View {
        Text(highlightedPrompt(text))
            .font(.dsMicro).foregroundStyle(.primary)   // bright prose; {{var}} runs override with accent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, DS.Space.md).padding(.top, DS.Space.xs).padding(.bottom, DS.Space.sm)
            // Bottom corners match the card so the recess doesn't poke past the rounded edge.
            .background(Color.black.opacity(0.24), in: UnevenRoundedRectangle(
                bottomLeadingRadius: DS.Radius.md, bottomTrailingRadius: DS.Radius.md))
            .overlay(alignment: .top) { Divider().opacity(0.3) }
            .clipped()
    }

    /// Template text as an AttributedString where {{var}} tokens are tinted + monospaced; prose runs carry
    /// no color so they inherit the band's secondary tone. Cheap; scoped to the small (clipped) preview band.
    private func highlightedPrompt(_ s: String) -> AttributedString {
        var attr = AttributedString()
        var rest = Substring(s)
        let varFont = Font.dsCodeMicro.weight(.semibold)
        func append(_ str: Substring, variable: Bool) {
            guard !str.isEmpty else { return }
            var run = AttributedString(String(str))
            if variable { run.foregroundColor = Theme.accent; run.font = varFont }
            attr.append(run)
        }
        while let open = rest.range(of: "{{") {
            append(rest[rest.startIndex..<open.lowerBound], variable: false)
            if let close = rest.range(of: "}}", range: open.upperBound..<rest.endIndex) {
                append(rest[open.lowerBound..<close.upperBound], variable: true)   // includes the {{ }}
                rest = rest[close.upperBound...]
            } else {
                append(rest[open.lowerBound...], variable: false)
                return attr
            }
        }
        append(rest, variable: false)
        return attr
    }

    // Each port has a WIDE transparent grab zone (covering the dot + its variable chip), not just the 11pt
    // dot — so a wire can be started by dragging anywhere along the port. The visual dot sits at the exact
    // analytic anchor (so edges line up) and is non-interactive; hover/arm state drives its glow + growth.
    private var portDots: some View {
        let w = NodeMetrics.width(node)
        let half = max(40, w / 2 - DS.Space.sm) + (nodeHovered ? 16 : 0)   // grab-zone width per side; fatter while hovering this node
        return ZStack(alignment: .topLeading) {
            ForEach(Array(node.inputPorts.enumerated()), id: \.offset) { i, port in
                // Neon fill = wired. While a wire is armed (or this port is mid input-drag), every input
                // lights up as a candidate target.
                let wired = engine.isConnected(node.id, port: port)
                let candidate = engine.armedFrom != nil
                    || (engine.pendingFromInput?.node == node.id && engine.pendingFromInput?.port == port)
                let y = NodeMetrics.rowCenterY(i)
                Color.clear
                    .frame(width: half, height: NodeMetrics.portSlot)
                    .contentShape(Rectangle())
                    .onHover { hoveredInput = $0 ? port : (hoveredInput == port ? nil : hoveredInput) }
                    .gesture(inputConnectGesture(port: port))
                    .onTapGesture(count: 2) { engine.snapshot(); engine.disconnect(to: node.id, port: port) }
                    .onTapGesture { if !engine.completeArm(to: node.id, port: port) { engine.selection = node.id } }
                    .help(engine.armedFrom != nil
                          ? "Click to connect the armed wire here"
                          : "Drag to an output, or double-click to disconnect")
                    // .position LAST: onHover/gestures scope to THIS port's small frame. (After .position the
                    // view fills the parent, so every input's hover fired across the whole card → only the
                    // topmost port ever lit up. Hangs ~6pt past the left edge so the dot sits inside.)
                    .position(x: half / 2 - 6, y: y)
                PortDotView(filled: wired, tint: wired ? Theme.accent : .secondary,
                            active: candidate || hoveredInput == port, enlarged: nodeHovered)
                    .position(x: 0, y: y).allowsHitTesting(false)
            }
            ForEach(Array(node.outputKeys.enumerated()), id: \.offset) { j, key in
                let armed = engine.armedFrom.map { $0.node == node.id && $0.key == key } ?? false
                let y = NodeMetrics.rowCenterY(j)
                Color.clear
                    .frame(width: half, height: NodeMetrics.portSlot)
                    .contentShape(Rectangle())
                    .onHover { hoveredOutput = $0 ? key : (hoveredOutput == key ? nil : hoveredOutput) }
                    .gesture(connectGesture(key: key))
                    .onTapGesture { engine.armOutput(node: node.id, key: key) }
                    .help("Drag to an input — drag again to fan this variable out to more inputs. Or click to arm, then click a target.")
                    .position(x: w - half / 2 + 6, y: y)   // .position LAST (see input port note above)
                PortDotView(filled: armed, tint: armed ? Theme.accent : .secondary,
                            active: armed || hoveredOutput == key, enlarged: nodeHovered)
                    .position(x: w, y: y).allowsHitTesting(false)
            }
        }
        .frame(width: w, height: NodeMetrics.height(node), alignment: .topLeading)
    }

    private var borderColor: Color {
        if selected { return tint }                      // selected border carries the node's own hue
        if run?.status == .error { return Color.dsDanger.opacity(0.7) }
        if run == nil, !issues.isEmpty { return Theme.gold.opacity(0.65) }   // amber = not ready
        // Persistent category borders (§5.2): FM accent, Hook gold, Compare pink; the rest neutral.
        switch node.kind {
        case .fm:      return Theme.accent.opacity(0.45)
        case .hook:    return Theme.gold.opacity(0.55)
        case .compare: return Theme.pink.opacity(0.55)
        default:       return .dsHairline                // success is shown by the status dot, not chrome
        }
    }

    /// Display name: the user's title, else a computed default (schema name for guided, else Kind_N).
    private var displayTitle: String { node.title.isEmpty ? engine.defaultTitle(for: node) : node.title }

    /// Writes the title straight into the graph node (same index-write the inspector uses).
    private var titleBinding: Binding<String> {
        Binding(
            get: { node.title },
            set: { v in
                if let i = engine.graph.nodes.firstIndex(where: { $0.id == node.id }) { engine.graph.nodes[i].title = v }
            })
    }

    /// Enter inline rename: snapshot once for undo, seed the field with the shown default so editing
    /// starts from what's on screen, then focus.
    private func startTitleEdit() {
        engine.snapshot()
        if node.title.isEmpty, let i = engine.graph.nodes.firstIndex(where: { $0.id == node.id }) {
            engine.graph.nodes[i].title = engine.defaultTitle(for: node)
        }
        editingTitle = true
        DispatchQueue.main.async { titleFocused = true }
    }

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .named(graphBoardSpace))
            .onChanged { v in
                if dragStarts == nil {
                    engine.snapshot()
                    if !engine.isNodeSelected(node.id) { engine.selectOnly(node.id) }   // drag an unselected node → select it
                    // Move the whole multi-selection together; otherwise just this node.
                    let ids: Set<UUID> = engine.selectedSet.count > 1 ? engine.selectedIDs : [node.id]
                    dragStarts = Dictionary(uniqueKeysWithValues:
                        ids.compactMap { id in engine.graph.node(id).map { (id, CGPoint(x: $0.x, y: $0.y)) } })
                }
                let dx = v.translation.width / engine.scale, dy = v.translation.height / engine.scale
                for (id, s) in dragStarts ?? [:] { engine.move(id, to: CGPoint(x: s.x + dx, y: s.y + dy)) }
                if node.kind.isBlock, (dragStarts?.count ?? 0) <= 1 { engine.updateGroupDrag(node.id) }   // single-block join/leave
            }
            .onEnded { _ in
                let moved = Set((dragStarts ?? [:]).keys)
                dragStarts = nil; engine.endGroupDrag()
                engine.settleLayout(after: moved.isEmpty ? [node.id] : moved)   // push aside overlaps; refit groups
            }
    }

    private func connectGesture(key: String) -> some Gesture {
        DragGesture(coordinateSpace: .named(graphBoardSpace))
            .onChanged { v in
                engine.pendingFrom = (node.id, key)
                engine.pendingPoint = engine.toCanvas(v.location)
            }
            .onEnded { v in
                let drop = engine.toCanvas(v.location)
                if let hit = engine.hitInputPort(near: drop) {
                    engine.snapshot()
                    engine.connect(from: node.id, key: key, to: hit.node, port: hit.port)
                }
                engine.pendingFrom = nil
                engine.pendingPoint = nil
            }
    }

    /// Drag FROM an input port to an output port (the reverse direction). The fixed end is this input;
    /// the moving end snaps to the nearest output on release.
    private func inputConnectGesture(port: String) -> some Gesture {
        DragGesture(coordinateSpace: .named(graphBoardSpace))
            .onChanged { v in
                engine.pendingFromInput = (node.id, port)
                engine.pendingPoint = engine.toCanvas(v.location)
            }
            .onEnded { v in
                let drop = engine.toCanvas(v.location)
                if let hit = engine.hitOutputPort(near: drop) {
                    engine.snapshot()
                    engine.connect(from: hit.node, key: hit.key, to: node.id, port: port)
                }
                engine.pendingFromInput = nil
                engine.pendingPoint = nil
            }
    }
}

/// The visual port dot — purely a marker at the analytic anchor; it grows + lights up when `active`
/// (hovered/armed/candidate). Hit-testing lives on the wide grab zone in `portDots`, not here.
private struct PortDotView: View {
    let filled: Bool
    let tint: Color
    let active: Bool
    var enlarged: Bool = false   // node-level hover: grow every dot so ports are easier to grab

    var body: some View {
        Circle()
            .fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(.background))
            .overlay(Circle().strokeBorder(active ? Theme.accent : tint, lineWidth: active ? 2 : 1.5))
            .frame(width: NodeMetrics.portDot, height: NodeMetrics.portDot)
            .scaleEffect(active ? 1.4 : (enlarged ? 1.25 : 1))
            .animation(.easeOut(duration: 0.12), value: active)
            .animation(.easeOut(duration: 0.12), value: enlarged)
    }
}

// MARK: - Prompt group frame

/// Draws each Prompt group as a labeled, dashed frame ENCLOSING its member blocks. Painted first in the
/// scaled layer (behind edges + cards); the frame body is non-hit-testing so panning falls through, and
/// only the header band (reserved ABOVE the members) + the right-edge out-port are interactive.
private struct GroupFrameLayer: View {
    @Bindable var engine: GraphEngine
    var body: some View {
        ForEach(engine.graph.nodes.filter { $0.kind == .promptGroup }) { group in
            if let rect = engine.groupRect(group.id) {
                GroupFrameView(engine: engine, group: group, rect: rect)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
    }
}

private struct GroupFrameView: View {
    @Bindable var engine: GraphEngine
    let group: GraphNode
    let rect: CGRect
    @State private var dragStart: [UUID: CGPoint]? = nil
    @State private var resizeStart: CGSize? = nil

    private var selected: Bool { engine.selection == group.id }
    private var dropping: Bool { engine.dropTargetGroup == group.id }
    private var issues: [GraphIssue] { engine.issues(inGroup: group.id) }   // group + members, once it feeds an FM

    /// Amber dashed frame when the Prompt is incomplete (no current turn / unbound var) — the at-a-glance
    /// "this won't run" signal. Accent identity appears on the selected/dropping state only (§5.2);
    /// an idle, healthy frame is neutral chrome.
    private var frameStroke: Color {
        if dropping || selected { return Theme.accent.opacity(0.85) }
        return issues.isEmpty ? Color.white.opacity(0.18) : Theme.gold.opacity(0.6)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                // Neutral fill (a faint dark veil) so member blocks read clearly — the green is reserved
                // for the dashed frame + header, not a wash over everything. Greens only while dropping in.
                .fill(dropping ? Theme.accent.opacity(0.10) : Color.white.opacity(0.025))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                    .strokeBorder(frameStroke,
                                  style: StrokeStyle(lineWidth: dropping ? 2.5 : (selected ? 2 : 1.5), dash: [7, 5])))
                .allowsHitTesting(false)               // body transparent → background pan falls through
            header
            outPort
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) { resizeGrip }
    }

    /// Bottom-right grip: drag to resize the Prompt frame itself (an explicit container now, not auto-hugged).
    private var resizeGrip: some View {
        Image(systemName: "arrow.down.right")
            .font(.dsMicro.weight(.bold)).foregroundStyle(Theme.accent.opacity(0.8))
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .named(graphBoardSpace))
                    .onChanged { v in
                        if resizeStart == nil { engine.snapshot(); resizeStart = CGSize(width: rect.width, height: rect.height) }
                        let s = resizeStart ?? .zero
                        engine.resizeGroup(group.id, to: CGSize(width:  s.width  + v.translation.width  / engine.scale,
                                                                height: s.height + v.translation.height / engine.scale))
                    }
                    .onEnded { _ in resizeStart = nil }
            )
            .help("Drag to resize the Prompt frame")
    }

    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: dropping ? "plus.circle.fill" : "rectangle.3.group")
                .font(.dsCaption).foregroundStyle(dropping ? Theme.accent : .secondary)
            Text(group.title.isEmpty ? "Prompt" : group.title).font(.dsLabel).lineLimit(1)
            Text("\(engine.members(of: group.id).count)").font(.dsMicro).foregroundStyle(.tertiary).monospacedDigit()
            if dropping { Text("add").font(.dsMicro.weight(.semibold)).foregroundStyle(Theme.accent) }
            if !dropping, !issues.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").font(.dsMicro).foregroundStyle(.dsWarning)
                    .help(issues.map(\.message).joined(separator: "\n"))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.md)
        .frame(width: rect.width, height: GraphEngine.groupHeader, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { engine.selection = group.id; engine.showInspector = true }
        .onTapGesture { engine.selection = group.id }
        .gesture(moveGesture)
    }

    /// The group's single "out" port (right edge, mid-height) — drag to an FM's prompt port.
    private var outPort: some View {
        Circle()
            .fill(Theme.accent.opacity(0.9))
            .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1))
            .frame(width: NodeMetrics.portDot, height: NodeMetrics.portDot)
            .scaleEffect(armed ? 1.4 : 1)
            .contentShape(Circle().inset(by: -10))
            .position(x: rect.width, y: rect.height / 2)
            .gesture(connectGesture)
            .onTapGesture { engine.armOutput(node: group.id, key: "prompt") }
            .help("Drag to an FM's prompt port, or click to arm then click the prompt port")
    }

    private var armed: Bool { engine.armedFrom.map { $0.node == group.id && $0.key == "prompt" } ?? false }

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .named(graphBoardSpace))
            .onChanged { v in
                if dragStart == nil {
                    engine.snapshot()
                    var starts = Dictionary(uniqueKeysWithValues:
                        engine.members(of: group.id).map { ($0.id, CGPoint(x: $0.x, y: $0.y)) })
                    starts[group.id] = CGPoint(x: group.x, y: group.y)   // move the empty-fallback origin too
                    dragStart = starts
                    engine.selection = group.id
                }
                let dx = v.translation.width / engine.scale, dy = v.translation.height / engine.scale
                for (id, start) in dragStart ?? [:] {
                    engine.move(id, to: CGPoint(x: start.x + dx, y: start.y + dy))
                }
            }
            .onEnded { _ in
                dragStart = nil
                engine.settleLayout(after: Set(engine.members(of: group.id).map(\.id)))   // members move as one block
            }
    }

    private var connectGesture: some Gesture {
        DragGesture(coordinateSpace: .named(graphBoardSpace))
            .onChanged { v in
                engine.pendingFrom = (group.id, "prompt")
                engine.pendingPoint = engine.toCanvas(v.location)
            }
            .onEnded { v in
                let drop = engine.toCanvas(v.location)
                if let hit = engine.hitInputPort(near: drop) {
                    engine.snapshot()
                    engine.connect(from: group.id, key: "prompt", to: hit.node, port: hit.port)
                }
                engine.pendingFrom = nil
                engine.pendingPoint = nil
            }
    }
}

// MARK: - Scroll-wheel zoom

/// Zoom on mouse-wheel / two-finger scroll, anchored under the cursor. Uses a LOCAL scroll-wheel
/// event monitor rather than an overlay NSView: an AppKit view can't receive `scrollWheel` without
/// also stealing `mouseDown` (both route through `hitTest`), which would break pan / drag-to-connect.
/// The monitor sees scroll events without touching mouse events, so the SwiftUI gestures stay intact.
private struct ScrollZoomMonitor: NSViewRepresentable {
    /// (zoom factor for this tick, board-space point under the cursor).
    let onScroll: (CGFloat, CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = FlippedView()                      // top-left origin → matches SwiftUI board space
        context.coordinator.view = v
        context.coordinator.install()
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.onScroll = onScroll }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }
    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    final class FlippedView: NSView { override var isFlipped: Bool { true } }

    final class Coordinator {
        weak var view: NSView?
        var onScroll: (CGFloat, CGPoint) -> Void
        private var monitor: Any?

        init(onScroll: @escaping (CGFloat, CGPoint) -> Void) { self.onScroll = onScroll }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let view = self.view, let window = view.window, event.window === window
                else { return event }
                let p = view.convert(event.locationInWindow, from: nil)
                guard view.bounds.contains(p), event.scrollingDeltaY != 0 else { return event }
                // Trackpad sends many tiny precise deltas; a mouse wheel sends a few large line deltas.
                let per: CGFloat = event.hasPreciseScrollingDeltas ? 0.0025 : 0.04
                let factor = min(max(1 + event.scrollingDeltaY * per, 0.9), 1.1)   // smooth, clamped per tick
                self.onScroll(factor, CGPoint(x: p.x, y: p.y))
                return nil                          // consume so the canvas itself doesn't also scroll
            }
        }
        func remove() { if let m = monitor { NSEvent.removeMonitor(m); monitor = nil } }
    }
}

// MARK: - Contextual bottom toolbar

/// A floating capsule bar pinned to the bottom-center of the canvas whose actions change with the
/// selection (Figma's contextual toolbar / Photoshop's options bar): quick node creation + auto-link
/// when nothing is selected, and node/edge actions (duplicate, auto-link, add-block, delete) otherwise.
private struct CanvasContextBar: View {
    @Bindable var engine: GraphEngine

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            if let n = engine.selectedNode {
                Image(systemName: n.kind.symbol).foregroundStyle(.secondary)
                Text(n.title.isEmpty ? n.kind.label : n.title).font(.dsCaption.weight(.medium)).lineLimit(1)
                bar
                if n.kind == .promptGroup { addBlockMenu }
                iconButton("plus.square.on.square", "Duplicate (⌘D)") { engine.duplicateSelection() }
                iconButton("link", "Auto-link variables (⌘L)", tint: Theme.accent) { engine.autoWireMatchingVars() }
                iconButton("trash", "Delete (⌫)", role: .destructive) { engine.deleteSelectionOrEdge() }
            } else if engine.selectedEdge != nil {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath").foregroundStyle(.secondary)
                Text("Wire").font(.dsCaption.weight(.medium))
                bar
                iconButton("scissors", "Delete wire (⌫)", role: .destructive) { engine.deleteSelectionOrEdge() }
            } else {
                addNodeMenu
                iconButton("link", "Auto-link variables (⌘L)", tint: Theme.accent) { engine.autoWireMatchingVars() }
                iconButton("arrow.up.left.and.arrow.down.right", "Fit to view (⌘0)") { engine.fitToView() }
            }
        }
        .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
        .glassEffect(.regular, in: Capsule())
        .tint(.primary)
    }

    private var bar: some View { Divider().frame(height: 16).padding(.horizontal, DS.Space.xxs) }

    private func iconButton(_ symbol: String, _ help: String, tint: Color = .primary,
                            role: ButtonRole? = nil, _ action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) { Image(systemName: symbol).frame(width: 22, height: 18) }
            .buttonStyle(.borderless).tint(role == .destructive ? .red : tint).help(help)
    }

    /// The same node palette as the top toolbar's Add menu, blocks nested under Prompt. New nodes land
    /// at the viewport center.
    private var addNodeMenu: some View {
        Menu {
            addItem(.promptGroup)
            Menu { ForEach(blockKinds, id: \.self) { addItem($0) } } label: { Label("Prompt blocks", systemImage: "square.stack.3d.up") }
            Divider()
            addItem(.input); addItem(.nativeAPI); addItem(.hook); addItem(.fm)
        } label: { Image(systemName: "plus").frame(width: 22, height: 18) }
        .menuStyle(.borderlessButton).fixedSize().help("Add node")
    }

    /// When a Prompt group is selected: add a block straight into it (addNode drops it inside the frame).
    private var addBlockMenu: some View {
        Menu {
            ForEach(blockKinds, id: \.self) { addItem($0) }
        } label: { Image(systemName: "plus.rectangle.on.rectangle").frame(width: 22, height: 18) }
        .menuStyle(.borderlessButton).fixedSize().help("Add a block to this Prompt")
    }

    private var blockKinds: [NodeKind] { [.instruction, .fewshot, .history, .current, .guided, .tool] }

    private func addItem(_ kind: NodeKind) -> some View {
        Button { engine.addNode(kind, at: engine.viewportCenterCanvas) } label: {
            Label(kind.label, systemImage: kind.symbol)
        }
    }
}

// MARK: - Floating Run control

/// The graph's primary action as a bold accent pill on the canvas (bottom-left). Always visible so Run is
/// one click or ⌘↩ — disabled (dimmed) while running or when the graph is empty. After the run finishes it
/// calls `onRun` to log the trace to Run History (the work the old top-toolbar Run button did).
private struct CanvasRunControl: View {
    @Bindable var engine: GraphEngine
    let onRun: () -> Void
    var batch: GraphBatchRunner? = nil
    var boundDataset: DatasetModel? = nil
    var onRunDataset: () -> Void = {}

    private var disabled: Bool { engine.isRunning || engine.graph.nodes.isEmpty }

    var body: some View {
        HStack(spacing: DS.Space.sm) {
            runPill
            if let batch { datasetControl(batch) }   // present only when an Input is dataset-bound
        }
    }

    private var runPill: some View {
        Button { Task { await engine.run(); onRun() } } label: {
            HStack(spacing: DS.Space.xs) {
                if engine.isRunning {
                    ProgressView().controlSize(.small).tint(.black)
                } else {
                    Image(systemName: "play.fill").font(.dsMicro.weight(.bold))
                }
                Text(engine.isRunning ? "Running…" : "Run").font(.dsCaption.weight(.bold))
            }
            .foregroundStyle(.black)               // dark ink reads on the neon-green accent fill
            .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
            .background(Theme.accent.opacity(disabled && !engine.isRunning ? 0.35 : 1), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
            .shadow(color: Theme.accent.opacity(0.5), radius: 10, y: 3)   // accent glow → stands out from chrome
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .keyboardShortcut(.return, modifiers: .command)
        .help(engine.graph.nodes.isEmpty ? "Add nodes, then Run (⌘↩)" : "Run the graph (⌘↩)")
    }

    /// The dataset batch lane, unified onto the canvas beside Run (was a separate toolbar button). Shows
    /// row progress + Stop while running; a "Run dataset" pill otherwise.
    @ViewBuilder private func datasetControl(_ batch: GraphBatchRunner) -> some View {
        if batch.isRunning {
            HStack(spacing: DS.Space.xs) {
                ProgressView().controlSize(.small)
                Text("Row \(batch.completed)/\(batch.total)").font(.dsCaption).monospacedDigit()
                Button { batch.cancel() } label: { Image(systemName: "stop.fill") }
                    .buttonStyle(.plain).foregroundStyle(.red).help("Stop the batch run")
            }
            .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
            .glassEffect(.regular, in: Capsule())
        } else {
            Button { onRunDataset() } label: {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "square.stack.3d.down.right.fill").font(.dsMicro.weight(.semibold))
                    Text("Run dataset").font(.dsCaption.weight(.medium))
                }
                .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
                .glassEffect(.regular, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(disabled || boundDataset == nil)
            .help(boundDataset == nil ? "Bind the Input to a dataset first"
                                      : "Run the graph over every dataset row → a Lab experiment")
        }
    }
}

// MARK: - Batch summary card

/// On-board summary of a finished batch run (rows · ok/err · avg latency · decode %), with a deep link to
/// the Lab sweep (switches to the Lab tab). Dismissible. View-only. (Phase 5.)
private struct CanvasBatchSummaryCard: View {
    @Bindable var batch: GraphBatchRunner
    let onOpenLab: () -> Void

    var body: some View {
        ZStack {
            if let s = batch.lastSummary, !batch.isRunning {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    HStack(spacing: DS.Space.xs) {
                        Image(systemName: "square.stack.3d.down.right.fill").font(.dsCaption).foregroundStyle(Theme.accent)
                        Text("Batch complete").font(.dsCaption.weight(.bold))
                        Spacer(minLength: DS.Space.lg)
                        Button { batch.lastSummary = nil } label: { Image(systemName: "xmark").font(.dsMicro) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
                    }
                    HStack(spacing: DS.Space.md) {
                        stat("\(s.rows)", "rows")
                        stat("\(s.ok)", "ok", tint: .dsSuccess)
                        stat("\(s.errors)", "err", tint: s.errors > 0 ? .dsDanger : .secondary)
                        stat("\(s.avgMs)ms", "avg")
                        stat("\(Int((s.decodePct * 100).rounded()))%", "decoded")
                    }
                    Button { onOpenLab() } label: {
                        Label("View in Lab", systemImage: "chart.bar.doc.horizontal").font(.dsCaption)
                    }
                    .buttonStyle(.borderless).tint(Theme.accent)
                }
                .padding(DS.Space.md).frame(width: 340, alignment: .leading)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg).strokeBorder(Theme.accent.opacity(0.35)))
                .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: batch.lastSummary?.experimentID)
    }

    private func stat(_ value: String, _ label: String, tint: Color = .primary) -> some View {
        VStack(spacing: DS.Space.xxs) {
            Text(value).font(.dsCaption.weight(.bold)).foregroundStyle(tint).monospacedDigit()
            Text(label).font(.dsMicro).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Live run feedback (running-node pill + error toast)

/// "Dynamic Island"-style pill, top-center, naming the node currently executing (a sequential run ⇒ one
/// at a time). Derives the running node from `engine.runs` — no extra engine state.
private struct CanvasRunningPill: View {
    @Bindable var engine: GraphEngine

    private var runningNode: GraphNode? {
        engine.runs.first { $0.value.status == .running }.flatMap { engine.graph.node($0.key) }
    }

    var body: some View {
        ZStack {
            if engine.isRunning, let n = runningNode {
                HStack(spacing: DS.Space.sm) {
                    ProgressView().controlSize(.small)
                    Image(systemName: n.kind.symbol).font(.dsCaption).foregroundStyle(Theme.accent)
                    Text("Running \(n.title.isEmpty ? engine.defaultTitle(for: n) : n.title)")
                        .font(.dsCaption.weight(.medium)).lineLimit(1)
                }
                .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
                .glassEffect(.dsActive, in: Capsule())   // accent tint = "active" (§4.5)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: engine.isRunning)
    }
}

/// Run errors surface as a dismissible top-right toast (auto-clears after a few seconds), replacing the
/// old toolbar label so failures show on the canvas where the work happens.
private struct CanvasErrorToast: View {
    @Bindable var engine: GraphEngine

    var body: some View {
        ZStack {
            if let err = engine.runError {
                HStack(alignment: .top, spacing: DS.Space.sm) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.dsDanger).font(.dsCaption)
                    Text(err).font(.dsCaption).foregroundStyle(.primary).lineLimit(4)
                        .frame(maxWidth: 300, alignment: .leading).textSelection(.enabled)
                    Button { engine.runError = nil } label: { Image(systemName: "xmark").font(.dsMicro) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg).strokeBorder(Color.dsDanger.opacity(0.45)))
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: err) {
                    try? await Task.sleep(for: .seconds(6))
                    engine.runError = nil
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: engine.runError)
    }
}

// MARK: - Floating zoom control

/// A compact zoom capsule pinned to the canvas's bottom-right corner (Figma/Adobe convention): − / % / +
/// and Fit. Relocated out of the top toolbar so it stops crowding the chrome at narrow widths. The
/// ⌘± / ⌘0 shortcuts ride on these buttons (they moved here with the controls).
private struct CanvasZoomControl: View {
    @Bindable var engine: GraphEngine

    var body: some View {
        HStack(spacing: DS.Space.xs) {
            iconButton("minus.magnifyingglass", "Zoom out (⌘−)") { engine.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button { engine.resetZoom() } label: {
                Text("\(Int((engine.scale * 100).rounded()))%")
                    .font(.dsMicro).monospacedDigit().foregroundStyle(.secondary).frame(width: 38)
            }
            .buttonStyle(.plain).help("Reset to 100%")
            iconButton("plus.magnifyingglass", "Zoom in (⌘+)") { engine.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Divider().frame(height: 14)
            iconButton("arrow.up.left.and.arrow.down.right", "Fit to view (⌘0)") { engine.fitToView() }
                .keyboardShortcut("0", modifiers: .command)
        }
        .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xs)
        .glassEffect(.regular, in: Capsule())
        .tint(.primary)
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 18) }
            .buttonStyle(.borderless).help(help)
    }
}
