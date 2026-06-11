//
//  CompareCanvas.swift
//  Prompt Playground
//
//  The Compare experience (Phase 6):
//   • CompareConfigSheet — a clear, guided sheet (what Compare does + lane selection + Run), presented on
//     double-clicking a `.compare` node (replaces the opaque header-only node).
//   • CompareResultCluster — the result rendered as side-by-side lane cards ON the canvas beneath the
//     compare node (view-only overlay, never a graph node). Both funnel through `engine.compareOutcome`.
//

import SwiftUI
import SwiftData

// MARK: - Pre-run config sheet

struct CompareConfigSheet: View {
    @Bindable var engine: GraphEngine
    let nodeID: UUID
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \GraphModel.createdAt) private var saved: [GraphModel]
    @Query(sort: \DatasetModel.createdAt) private var datasets: [DatasetModel]
    @State private var runner = GraphCompareRunner()

    private var node: GraphNode? { engine.graph.node(nodeID) }
    private var groups: [GraphNode] { engine.graph.nodes.filter { $0.kind == .promptGroup } }
    private var selectedIDs: [UUID] { node?.compare?.laneGroupIDs ?? [] }
    /// A lane is runnable only if its group feeds a Foundation Model — otherwise it produces no output.
    private func feedsFM(_ id: UUID) -> Bool { engine.graph.fmID(fedBy: id) != nil }
    private var runnableSelected: [UUID] { selectedIDs.filter(feedsFM) }
    private var graphName: String { saved.first { $0.id == engine.loadedID }?.name ?? "Untitled graph" }
    private var boundDataset: DatasetModel? {
        guard let id = engine.graph.nodes.first(where: {
            $0.kind == .input && $0.input?.source == .dataset
        })?.input?.datasetID else { return nil }
        return datasets.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Label("Compare prompts side-by-side", systemImage: "rectangle.split.3x1").font(.dsTitle)
                Text(boundDataset != nil
                     ? "Each selected Prompt group runs as a lane over every row of “\(boundDataset!.name)”. Outputs appear side-by-side on the canvas, and the run is saved as a Lab sweep."
                     : "Each selected Prompt group runs as a lane on the same input — only the prompt varies. Outputs appear side-by-side on the canvas, and the run is saved as a Lab sweep.")
                    .font(.dsCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Text("Lanes").font(.dsLabel).foregroundStyle(.secondary)
            // Inner content block on an opaque card — the sheet container itself is system glass (§4.5).
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                if groups.isEmpty {
                    Text("No Prompt groups in this graph yet — add a couple, each feeding its own Foundation Model.")
                        .font(.dsCaption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(groups) { g in
                        let runnable = feedsFM(g.id)
                        Toggle(isOn: laneBinding(g.id)) {
                            HStack(spacing: DS.Space.xs) {
                                Text(g.title.isEmpty ? "Prompt" : g.title).font(.dsBody)
                                if !runnable { Text("· no model wired").font(.dsMicro).foregroundStyle(.dsWarning) }
                            }
                        }
                        .toggleStyle(.checkbox).disabled(!runnable)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard()

            if let err = runner.error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.dsCaption).foregroundStyle(.dsDanger).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button { runComparison() } label: {
                    HStack(spacing: DS.Space.sm) {
                        if runner.isRunning { ProgressView().controlSize(.small) }
                        Text(runLabel)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(runner.isRunning || runnableSelected.count < 2)
                .help(runnableSelected.count < 2 ? "Select at least two Prompt groups, each feeding a Foundation Model"
                                                 : "Run the selected lanes side-by-side")
            }
        }
        .padding(DS.Space.xl).frame(minWidth: 440)
    }

    private func laneBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { on in
                guard let i = engine.graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
                var ids = engine.graph.nodes[i].compare?.laneGroupIDs ?? []
                if on { if !ids.contains(id) { ids.append(id) } } else { ids.removeAll { $0 == id } }
                engine.graph.nodes[i].compare = ComparePayload(laneGroupIDs: ids)
            })
    }

    private var runLabel: String {
        if runner.isRunning { return boundDataset != nil ? "Row \(runner.completed)/\(runner.total)…" : "Running…" }
        if let ds = boundDataset { return "Run × \(ds.name) (\(ds.examples.count) rows)" }
        return "Run comparison"
    }

    private func runComparison() {
        let ids = selectedIDs
        let name = graphName
        let dataset = boundDataset
        Task {
            await runner.run(graph: engine.graph, laneGroupIDs: ids, graphName: name, dataset: dataset, context: context)
            if let o = runner.lastOutcome { engine.compareOutcome = o; dismiss() }   // → on-canvas lane cards
        }
    }
}

// MARK: - Visual tether (node → result cluster)

/// A dashed accent connector from the Compare node down to its on-canvas result cluster, so the result
/// reads as belonging to that node (not a detached panel). Drawn in absolute canvas space (8000² frame,
/// mirroring EdgeLayer) so the endpoints are board coordinates.
struct CompareLinkLine: View {
    let from: CGPoint
    let to: CGPoint
    var body: some View {
        Path { p in
            p.move(to: from)
            let midY = (from.y + to.y) / 2
            p.addCurve(to: to, control1: CGPoint(x: from.x, y: midY), control2: CGPoint(x: to.x, y: midY))
        }
        .stroke(Theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
        .frame(width: 8000, height: 8000, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

// MARK: - On-canvas lane result cluster

/// The comparison result as side-by-side lane cards beneath the compare node. A view-only overlay (never a
/// graph node); lives in the scaled canvas layer. Drag the header to move it; "Expand" opens the full modal.
struct CompareResultCluster: View {
    @Bindable var engine: GraphEngine
    let outcome: CompareOutcome
    @State private var dragStart: CGSize? = nil
    @State private var showExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            header
            if outcome.lanes.isEmpty {
                Text("No lanes ran — each lane needs a Prompt group feeding a Foundation Model.")
                    .font(.dsCaption).foregroundStyle(.secondary)
            } else {
                // Capped width + horizontal scroll so the cluster never sprawls across the canvas.
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: DS.Space.md) {
                        ForEach(outcome.lanes) { lane in CompareLaneCard(lane: lane, width: 220, outputHeight: 180) }
                    }
                    .padding(.bottom, DS.Space.xs)
                }
                .frame(maxWidth: 480)
            }
        }
        // Content-heavy floating result → opaque card, not glass (design.md §3.5).
        .dsCard(radius: DS.Radius.lg)
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg).strokeBorder(Theme.accent.opacity(0.3)))
        .sheet(isPresented: $showExpanded) { CompareResultView(outcome: outcome) }
    }

    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "rectangle.split.3x1").foregroundStyle(Theme.accent)
            Text("Comparison").font(.dsCaption.weight(.bold))
            Text(outcome.datasetName != nil ? "\(outcome.lanes.count) lanes × \(outcome.rows) rows"
                                            : "\(outcome.lanes.count) lanes")
                .font(.dsMicro).foregroundStyle(.secondary)
            if !outcome.skipped.isEmpty {
                Text("· skipped \(outcome.skipped.count)").font(.dsMicro).foregroundStyle(.dsWarning)
            }
            Spacer(minLength: DS.Space.lg)
            Button { showExpanded = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Expand")
            Button { engine.compareOutcome = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
        }
        .font(.dsMicro)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(coordinateSpace: .named(graphBoardSpace))
                .onChanged { v in
                    if dragStart == nil { dragStart = engine.compareCardsOffset }
                    let s = dragStart ?? .zero
                    engine.compareCardsOffset = CGSize(width: s.width + v.translation.width / engine.scale,
                                                       height: s.height + v.translation.height / engine.scale)
                }
                .onEnded { _ in dragStart = nil }
        )
    }
}
