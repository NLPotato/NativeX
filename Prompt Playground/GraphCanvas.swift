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

let graphBoardSpace = "graphboard"

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
                    .onTapGesture { engine.selection = nil }
                    .gesture(pan)
                    .simultaneousGesture(zoom)

                // Scaled content layer (canvas space).
                ZStack(alignment: .topLeading) {
                    EdgeLayer(engine: engine)
                    ForEach(engine.graph.nodes) { node in
                        NodeCardView(engine: engine, node: node)
                            .frame(width: NodeMetrics.width, height: NodeMetrics.height(node), alignment: .topLeading)
                            .offset(x: node.x, y: node.y)
                    }
                }
                .scaleEffect(engine.scale, anchor: .topLeading)
                .offset(engine.offset)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .coordinateSpace(name: graphBoardSpace)
            .onDeleteCommand { engine.deleteSelection() }
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

private struct EdgeLayer: View {
    @Bindable var engine: GraphEngine

    var body: some View {
        Canvas { ctx, _ in
            for edge in engine.graph.edges {
                guard let a = outAnchor(edge), let b = inAnchor(edge) else { continue }
                ctx.stroke(curve(a, b), with: .color(Theme.accent.opacity(0.6)), lineWidth: 2)
            }
            if let pf = engine.pendingFrom, let pt = engine.pendingPoint,
               let n = engine.graph.node(pf.node), let j = n.outputKeys.firstIndex(of: pf.key) {
                ctx.stroke(curve(NodeMetrics.outputAnchor(n, j), pt),
                           with: .color(Theme.accent.opacity(0.5)),
                           style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            }
        }
        .frame(width: 8000, height: 8000, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func outAnchor(_ e: GraphEdge) -> CGPoint? {
        guard let n = engine.graph.node(e.fromNodeID),
              let j = n.outputKeys.firstIndex(of: e.outputKey) else { return nil }
        return NodeMetrics.outputAnchor(n, j)
    }
    private func inAnchor(_ e: GraphEdge) -> CGPoint? {
        guard let n = engine.graph.node(e.toNodeID),
              let i = n.inputPorts.firstIndex(of: e.inputPort) else { return nil }
        return NodeMetrics.inputAnchor(n, i)
    }
    private func curve(_ a: CGPoint, _ b: CGPoint) -> Path {
        var p = Path()
        let c = max(abs(b.x - a.x) * 0.5, 50)
        p.move(to: a)
        p.addCurve(to: b, control1: CGPoint(x: a.x + c, y: a.y), control2: CGPoint(x: b.x - c, y: b.y))
        return p
    }
}

// MARK: - Node card

private struct NodeCardView: View {
    @Bindable var engine: GraphEngine
    let node: GraphNode

    @State private var moveStart: CGPoint? = nil

    private var run: GraphNodeRun? { engine.runs[node.id] }
    private var selected: Bool { engine.selection == node.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.25)
            ForEach(0..<NodeMetrics.rows(node), id: \.self) { row in
                portRow(row).frame(height: NodeMetrics.portSlot)
            }
            Spacer(minLength: 0)
        }
        .frame(width: NodeMetrics.width, height: NodeMetrics.height(node), alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
            .strokeBorder(borderColor, lineWidth: selected ? 2 : 1))
        .overlay { if run?.status == .running { RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(Theme.lime, lineWidth: 2).opacity(0.9) } }
        .overlay(alignment: .topLeading) { portDots }
        .contentShape(Rectangle())
        .onTapGesture { engine.selection = node.id }
        .gesture(moveGesture)
    }

    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: node.kind.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.dsAccent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title.isEmpty ? node.kind.label : node.title)
                    .font(.dsLabel).lineLimit(1)
                Text(faceSummary).font(.dsMicro).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            statusDot
        }
        .padding(.horizontal, DS.Space.md)
        .frame(height: NodeMetrics.header, alignment: .center)
    }

    @ViewBuilder private var statusDot: some View {
        switch run?.status {
        case .ok:      Image(systemName: "checkmark.circle.fill").foregroundStyle(.dsSuccess).font(.dsCaption)
        case .error:   Image(systemName: "xmark.octagon.fill").foregroundStyle(.dsDanger).font(.dsCaption)
        case .running: ProgressView().controlSize(.mini)
        default:       EmptyView()
        }
    }

    private func portRow(_ row: Int) -> some View {
        HStack(spacing: DS.Space.sm) {
            if row < node.inputPorts.count {
                Text(node.inputPorts[row]).font(.dsMicro).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if row < node.outputKeys.count {
                Text(node.outputKeys[row]).font(.dsMicro.weight(.medium)).foregroundStyle(.dsAccent).lineLimit(1)
            }
        }
        .padding(.horizontal, DS.Space.md)
    }

    // Port dots positioned at the analytic anchors (in node-local coordinates).
    private var portDots: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(node.inputPorts.enumerated()), id: \.offset) { i, _ in
                portDot(filled: false)
                    .position(x: 0, y: NodeMetrics.rowCenterY(i))
            }
            ForEach(Array(node.outputKeys.enumerated()), id: \.offset) { j, key in
                portDot(filled: true)
                    .position(x: NodeMetrics.width, y: NodeMetrics.rowCenterY(j))
                    .gesture(connectGesture(key: key))
            }
        }
        .frame(width: NodeMetrics.width, height: NodeMetrics.height(node), alignment: .topLeading)
    }

    private func portDot(filled: Bool) -> some View {
        Circle()
            .fill(filled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.background))
            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 1.5))
            .frame(width: NodeMetrics.portDot, height: NodeMetrics.portDot)
            .contentShape(Circle().inset(by: -6))
    }

    private var borderColor: Color {
        if selected { return Theme.accent }
        switch run?.status {
        case .error: return .red.opacity(0.7)
        case .ok:    return Theme.accent.opacity(0.35)
        default:     return .white.opacity(0.12)
        }
    }

    private var faceSummary: String {
        switch node.kind {
        case .message:   return node.message?.role.label ?? "MESSAGE"
        case .prompt:    return "{{…}} → prompt"
        case .nativeAPI, .hook: return node.hook?.op.displayName ?? node.kind.label
        case .fm:        return (node.fm?.useGuidedGen ?? false) ? "guided · \(node.fm?.config.sampling.label ?? "")" : "free · \(node.fm?.config.sampling.label ?? "")"
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .named(graphBoardSpace))
            .onChanged { v in
                if moveStart == nil { moveStart = CGPoint(x: node.x, y: node.y); engine.selection = node.id }
                let s = moveStart ?? .zero
                engine.move(node.id, to: CGPoint(x: s.x + v.translation.width / engine.scale,
                                                 y: s.y + v.translation.height / engine.scale))
            }
            .onEnded { _ in moveStart = nil }
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
                    engine.connect(from: node.id, key: key, to: hit.node, port: hit.port)
                }
                engine.pendingFrom = nil
                engine.pendingPoint = nil
            }
    }
}
