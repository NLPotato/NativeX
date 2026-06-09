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
import AppKit

let graphBoardSpace = "graphboard"

/// Per-kind accent so the board reads as a typed pipeline at a glance rather than a wall of grey. Calm,
/// distinct hues (not neon) — used on the node icon, a faint header wash, and the selected border/glow.
func kindTint(_ kind: NodeKind) -> Color {
    switch kind {
    case .promptGroup: return Theme.accent
    case .instruction: return .blue
    case .fewshot:     return .indigo
    case .history:     return .purple
    case .current:     return .teal
    case .guided:      return Theme.cyan
    case .tool:        return .orange
    case .input:       return .green
    case .nativeAPI:   return .mint
    case .hook:        return .brown
    case .fm:          return .pink
    case .compare:     return .yellow
    }
}

struct GraphCanvas: View {
    @Bindable var engine: GraphEngine

    @State private var panStart: CGSize? = nil
    @State private var zoomStart: CGFloat? = nil

    var body: some View {
        // GeometryReader + explicit frame so the huge edge Canvas (below) can't drive the pane's
        // intrinsic size; the oversized scaled layer simply overflows and is clipped.
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Background — captures pan / zoom / deselect.
                Color(nsColor: .underPageBackgroundColor)
                    .contentShape(Rectangle())
                    .onTapGesture { engine.selection = nil; engine.selectedEdge = nil; engine.cancelArm() }
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
                            .frame(width: NodeMetrics.width, height: NodeMetrics.height(node), alignment: .topLeading)
                            .offset(x: node.x, y: node.y)
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
            // Figma/Photoshop-style floating bar — actions for the current selection, pinned bottom-center.
            .overlay(alignment: .bottom) { CanvasContextBar(engine: engine).padding(.bottom, DS.Space.lg) }
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

    @State private var moveStart: CGPoint? = nil
    @State private var resizeStartH: CGFloat? = nil

    private var run: GraphNodeRun? { engine.runs[node.id] }
    private var selected: Bool { engine.selection == node.id }
    private var issues: [GraphIssue] { engine.issues(for: node.id) }   // pre-run structural problems

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.25)
            ForEach(0..<NodeMetrics.rows(node), id: \.self) { row in
                portRow(row).frame(height: NodeMetrics.portSlot)
            }
            if let preview = NodeMetrics.previewText(node) {
                Text(preview)
                    .font(.dsMicro).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, DS.Space.md).padding(.top, 2).padding(.bottom, DS.Space.sm)
                    .clipped()
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(width: NodeMetrics.width, height: NodeMetrics.height(node), alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(tint.opacity(selected ? 0.16 : 0.05)))   // kind identity; brighter when active
        )
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
            .strokeBorder(borderColor, lineWidth: selected ? 2.5 : 1))
        .overlay { if run?.status == .running { RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(Theme.lime, lineWidth: 2).opacity(0.9) } }
        .shadow(color: selected ? tint.opacity(0.55) : .black.opacity(0.28),
                radius: selected ? 12 : 4, y: selected ? 0 : 2)   // selected node lifts off the board
        .overlay(alignment: .topLeading) { portDots }
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        .contentShape(Rectangle())
        .onTapGesture { engine.selection = node.id }
        .gesture(moveGesture)
    }

    /// A corner grip on text blocks: drag down to give a lengthy prompt more room on the card.
    @ViewBuilder private var resizeGrip: some View {
        if NodeMetrics.previewText(node) != nil {
            Image(systemName: "arrow.down.right")
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(coordinateSpace: .named(graphBoardSpace))
                        .onChanged { v in
                            if resizeStartH == nil { engine.snapshot(); resizeStartH = NodeMetrics.height(node) }
                            engine.resizeNode(node.id, to: (resizeStartH ?? 0) + v.translation.height / engine.scale)
                        }
                        .onEnded { _ in resizeStartH = nil }
                )
                .help("Drag to resize")
        }
    }

    private var tint: Color { kindTint(node.kind) }

    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: node.kind.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)                  // each kind's hue rides on its icon
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title.isEmpty ? node.kind.label : node.title)
                    .font(.dsLabel).lineLimit(1).foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.primary.opacity(0.9)))
                if let preview = runPreview {
                    Text(preview).font(.dsMicro).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text(faceSummary).font(.dsMicro).foregroundStyle(faceTint).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            statusDot
        }
        .padding(.horizontal, DS.Space.md)
        .frame(height: NodeMetrics.header, alignment: .center)
        .background(tint.opacity(selected ? 0.18 : 0.10), in: UnevenRoundedRectangle(
            topLeadingRadius: DS.Radius.md, topTrailingRadius: DS.Radius.md))   // colored header strip
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
                Text(node.inputPorts[row]).font(.dsMicro).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if row < node.outputKeys.count {
                Text(node.outputKeys[row]).font(.dsMicro.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, DS.Space.md)
    }

    // Port dots positioned at the analytic anchors (in node-local coordinates). Each dot is wireable two
    // ways: DRAG it to the opposite port, or CLICK an output to arm then click a target input.
    private var portDots: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(node.inputPorts.enumerated()), id: \.offset) { i, port in
                // Neon fill = wired. While a wire is armed (or this port is mid input-drag), every input
                // lights up as a candidate target.
                let wired = engine.isConnected(node.id, port: port)
                let candidate = engine.armedFrom != nil
                    || (engine.pendingFromInput?.node == node.id && engine.pendingFromInput?.port == port)
                PortDotView(filled: wired, tint: wired ? Theme.accent : .secondary, active: candidate)
                    .position(x: 0, y: NodeMetrics.rowCenterY(i))
                    .gesture(inputConnectGesture(port: port))
                    .onTapGesture(count: 2) { engine.snapshot(); engine.disconnect(to: node.id, port: port) }
                    .onTapGesture { if !engine.completeArm(to: node.id, port: port) { engine.selection = node.id } }
                    .help(engine.armedFrom != nil
                          ? "Click to connect the armed wire here"
                          : "Drag to an output, or double-click to disconnect")
            }
            ForEach(Array(node.outputKeys.enumerated()), id: \.offset) { j, key in
                let armed = engine.armedFrom.map { $0.node == node.id && $0.key == key } ?? false
                PortDotView(filled: armed, tint: armed ? Theme.accent : .secondary, active: armed)
                    .position(x: NodeMetrics.width, y: NodeMetrics.rowCenterY(j))
                    .gesture(connectGesture(key: key))
                    .onTapGesture { engine.armOutput(node: node.id, key: key) }
                    .help("Drag to an input, or click to arm then click a target input")
            }
        }
        .frame(width: NodeMetrics.width, height: NodeMetrics.height(node), alignment: .topLeading)
    }

    private var borderColor: Color {
        if selected { return tint }                      // selected border carries the node's own hue
        switch run?.status {
        case .error: return .red.opacity(0.7)
        case .none:  return issues.isEmpty ? .white.opacity(0.12) : Theme.gold.opacity(0.65)  // amber = not ready
        default:     return .white.opacity(0.12)         // success is shown by the status dot, not green chrome
        }
    }

    private var faceSummary: String {
        switch node.kind {
        case .instruction: return "system"
        case .fewshot:     return "\(node.fewshot?.shots.count ?? 0) example(s)"
        case .history:     return node.history?.role.label ?? "turn"
        case .current:     return "live turn"
        case .guided:      return node.guided?.schemaDef?.typeName ?? "no schema"
        case .tool:        return node.tool?.name.isEmpty ?? true ? "tool" : (node.tool?.name ?? "tool")
        case .input:       return node.input?.source.label ?? "static"
        case .nativeAPI, .hook: return node.hook?.op.displayName ?? node.kind.label
        case .fm:          return node.fm?.config.sampling.label ?? "default"
        case .promptGroup: return "prompt"
        case .compare:     return "\(node.compare?.laneGroupIDs.count ?? 0) lane(s)"
        }
    }

    /// Cyan flags a schema-bearing guided block at a glance; everything else is quiet secondary.
    private var faceTint: Color {
        (node.kind == .guided && node.guided?.schemaDef != nil) ? Theme.cyan : .secondary
    }

    /// After a successful run, the card subtitle peeks at the node's primary output (one line).
    private var runPreview: String? {
        guard run?.status == .ok, let outputs = run?.outputs, let key = primaryOutputKey else { return nil }
        let raw = (outputs[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let flat = raw.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 44 ? String(flat.prefix(44)) + "…" : flat
    }

    /// The output key whose value best represents the node after a run.
    private var primaryOutputKey: String? {
        switch node.kind {
        case .fm:               return "output"
        case .input:            return node.inputVarNames.first
        case .nativeAPI, .hook: return node.hook.map { $0.outputVar.isEmpty ? "output" : $0.outputVar }
        default:                return node.blockOutputKey
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .named(graphBoardSpace))
            .onChanged { v in
                if moveStart == nil { engine.snapshot(); moveStart = CGPoint(x: node.x, y: node.y); engine.selection = node.id }
                let s = moveStart ?? .zero
                engine.move(node.id, to: CGPoint(x: s.x + v.translation.width / engine.scale,
                                                 y: s.y + v.translation.height / engine.scale))
                if node.kind.isBlock { engine.updateGroupDrag(node.id) }   // live join/leave + "+" highlight
            }
            .onEnded { _ in moveStart = nil; engine.endGroupDrag() }
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

/// A wireable port dot that grows on hover (or while it's an armed/candidate target). Gestures + taps
/// are attached by the caller; this view owns only the visual + the (generous) hit shape.
private struct PortDotView: View {
    let filled: Bool
    let tint: Color
    let active: Bool
    @State private var hover = false

    var body: some View {
        Circle()
            .fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(.background))
            .overlay(Circle().strokeBorder(active ? Theme.accent : tint, lineWidth: active ? 2 : 1.5))
            .frame(width: NodeMetrics.portDot, height: NodeMetrics.portDot)
            .scaleEffect((hover || active) ? 1.4 : 1)
            .contentShape(Circle().inset(by: -10))   // generous hit target (was -6)
            .onHover { hover = $0 }
            .animation(.easeOut(duration: 0.12), value: hover)
            .animation(.easeOut(duration: 0.12), value: active)
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

    private var selected: Bool { engine.selection == group.id }
    private var dropping: Bool { engine.dropTargetGroup == group.id }
    private var issues: [GraphIssue] { engine.issues(inGroup: group.id) }   // group + members, once it feeds an FM

    /// Amber dashed frame when the Prompt is incomplete (no current turn / unbound var) — the at-a-glance
    /// "this won't run" signal, so the failure is visible at authoring time, not only on Run.
    private var frameStroke: Color {
        if dropping || selected { return Theme.accent.opacity(0.85) }
        return issues.isEmpty ? Theme.accent.opacity(0.30) : Theme.gold.opacity(0.6)
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
            .onEnded { _ in dragStart = nil }
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
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
        .tint(.primary)
    }

    private var bar: some View { Divider().frame(height: 16).padding(.horizontal, 2) }

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
