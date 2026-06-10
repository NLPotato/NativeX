//
//  GraphView.swift
//  Prompt Playground
//
//  The "Graph" tab — a node-graph editor that unifies Single-shot + Chat. HSplitView of the canvas
//  (GraphCanvas) and a per-node inspector (NodeInspector). Toolbar drives run / add / delete / view /
//  save / load over the shared SwiftData store (GraphModel). Follows the existing tab convention:
//  @State engine + @Environment(\.modelContext) + @Query.
//

import SwiftUI
import SwiftData

struct GraphView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.undoManager) private var undoManager
    let engine: GraphEngine   // owned by the App so the working graph survives navigation
    @Query(sort: \GraphModel.createdAt) private var saved: [GraphModel]
    @Query(sort: \DatasetModel.createdAt) private var datasets: [DatasetModel]
    @State private var batch = GraphBatchRunner()

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                toolbar
                Divider()
                GraphCanvas(engine: engine)
                    .runningRadiance(active: engine.isRunning)
            }
            .frame(minWidth: 480)

            if engine.showInspector {
                inspectorPane
                    .frame(minWidth: DS.Size.panelMinWidth, idealWidth: DS.Size.panelIdealWidth, maxWidth: 540)
            }
        }
        // The window's UndoManager drives ⌘Z/⌘⇧Z via the standard Edit menu; hand it to the engine so
        // structural edits register snapshots against it (and text-field undo still wins while editing).
        .onAppear { engine.undoManager = undoManager }
        .onChange(of: undoManager) { _, um in engine.undoManager = um }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: DS.Space.md) {
            // Run is the ONE accent action at rest — everything else is neutral chrome.
            Button { Task { await engine.run(); persistRun() } } label: {
                Label(engine.isRunning ? "Running…" : "Run", systemImage: "play.fill")
            }
            .disabled(engine.isRunning || engine.graph.nodes.isEmpty)
            .tint(Theme.accent)

            // Batch lane: visible only when an Input is bound to a dataset. Runs the graph per row →
            // one Lab experiment (see GraphBatchRunner). Cancellable; the on-device model runs one at a time.
            if datasetInput != nil {
                Button { runOverDataset() } label: {
                    Label(batch.isRunning ? "Row \(batch.completed)/\(batch.total)…" : "Run dataset",
                          systemImage: "square.stack.3d.down.right.fill")
                }
                .disabled(batch.isRunning || engine.isRunning || boundDataset == nil)
                .help("Run this graph over every row of the bound dataset → saved as a Lab experiment")
                if batch.isRunning {
                    Button { batch.cancel() } label: { Image(systemName: "stop.fill") }.tint(.red)
                }
            }

            Menu {
                addItem(.promptGroup, "p")
                Menu {                                    // blocks nested UNDER Prompt — they belong to it
                    addItem(.instruction, "i")
                    addItem(.fewshot, nil)
                    addItem(.history, nil)
                    addItem(.current, "t")
                    addItem(.guided, "g")
                    addItem(.tool, nil)
                } label: { Label("Prompt blocks", systemImage: "square.stack.3d.up") }
                Divider()
                addItem(.input, "n")
                addItem(.nativeAPI, nil)
                addItem(.hook, nil)
                addItem(.fm, "m")
                Divider()
                addItem(.compare, nil)
            } label: { Label("Add", systemImage: "plus") }
            .menuStyle(.borderlessButton).fixedSize()

            Button { engine.autoWireMatchingVars() } label: { Label("Auto-wire", systemImage: "link") }
                .keyboardShortcut("l", modifiers: .command)
                .help("Connect every unwired {{var}} to a same-named output (e.g. an Input’s learning → a block’s {{learning}})")

            Button { engine.duplicateSelection() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .disabled(engine.selection == nil)
                .keyboardShortcut("d", modifiers: .command)

            Button(role: .destructive) { engine.deleteSelectionOrEdge() } label: { Label("Delete", systemImage: "trash") }
                .disabled(engine.selection == nil && engine.selectedEdge == nil)
                .tint(.red)
                .keyboardShortcut(.delete, modifiers: [])   // ⌫ deletes the selected node or wire

            Divider().frame(height: 16)

            // Undo / redo. ⌘Z / ⌘⇧Z arrive via the standard Edit menu (so text-field undo wins while
            // editing); these buttons are the visible affordance and route to the same UndoManager.
            Button { undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!(undoManager?.canUndo ?? false)).help("Undo (⌘Z)")
            Button { undoManager?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!(undoManager?.canRedo ?? false)).help("Redo (⌘⇧Z)")

            Spacer()

            if let err = engine.runError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.dsCaption).foregroundStyle(.dsDanger).lineLimit(1)
            }

            Menu {
                Button("Insert example: gloss") { engine.loadGraph(GraphEngine.exampleGloss(), id: nil) }
                Button("Insert example: compare (A/B)") { engine.loadGraph(GraphEngine.exampleCompare(), id: nil) }
                Button("Insert example: compare × dataset") { engine.loadGraph(GraphEngine.exampleCompareDataset(), id: nil) }
                Divider()
                if saved.isEmpty {
                    Text("No saved graphs")
                } else {
                    ForEach(saved) { g in
                        Button(g.name) { engine.loadGraph(g.graphDef, id: g.id) }
                    }
                }
            } label: { Label("Load", systemImage: "tray.and.arrow.down") }
            .menuStyle(.borderlessButton).fixedSize()

            if engine.isDirty {
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(Theme.gold)
                    .help("Unsaved changes")
            }
            Button { save() } label: { Label("Save", systemImage: "tray.and.arrow.up") }

            Divider().frame(height: 16)
            Button { engine.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(engine.showInspector ? "Hide inspector" : "Show inspector")
        }
        .padding(.horizontal, DS.Space.lg).padding(.vertical, DS.Space.sm)
        .font(.dsCaption)
        .tint(.primary)   // neutral chrome by default; Run/Delete override above
    }

    /// One Add-menu item: adds the node at the viewport center, with an optional Figma-style single-key
    /// shortcut (fires when no text field is focused — same as the menu button).
    @ViewBuilder private func addItem(_ kind: NodeKind, _ key: Character?) -> some View {
        let button = Button { engine.addNode(kind, at: engine.viewportCenterCanvas) } label: {
            Label(kind.label, systemImage: kind.symbol)
        }
        if let key { button.keyboardShortcut(KeyEquivalent(key), modifiers: []) } else { button }
    }

    // MARK: Inspector

    @ViewBuilder private var inspectorPane: some View {
        if let sel = engine.selection, engine.graph.nodes.contains(where: { $0.id == sel }) {
            NodeInspector(engine: engine, nodeID: sel).id(sel)
        } else {
            VStack(spacing: DS.Space.md) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 30)).foregroundStyle(.tertiary)
                Text("Select a node to edit it").font(.dsBody).foregroundStyle(.secondary)
                Text("Drag from an output port (right) to an input port (left) to wire nodes. An FM node needs a prompt wired into its prompt port.")
                    .font(.dsCaption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
            .padding(DS.Space.xl).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The dataset-bound Input node, if any — its presence enables the "Run dataset" batch action.
    private var datasetInput: GraphNode? {
        engine.graph.nodes.first { $0.kind == .input && $0.input?.source == .dataset && $0.input?.datasetID != nil }
    }
    private var boundDataset: DatasetModel? {
        datasetInput?.input?.datasetID.flatMap { id in datasets.first { $0.id == id } }
    }

    /// Fan the current graph over every row of the bound dataset → one Lab experiment (see Lab tab).
    private func runOverDataset() {
        guard let ds = boundDataset else { return }
        let name = saved.first { $0.id == engine.loadedID }?.name ?? "Untitled graph"
        // Discard the returned ExperimentModel (non-Sendable) so the Task result stays Void — it's persisted; nothing here needs it.
        Task { _ = await batch.run(graph: engine.graph, dataset: ds, graphName: name, context: context) }
    }

    /// Log the just-finished execution to Run History (one TraceModel per run). Skipped when nothing
    /// ran — a pre-run validation failure throws before any step, leaving no trace to persist.
    private func persistRun() {
        guard let trace = engine.lastTrace, !trace.steps.isEmpty else { return }
        let name = saved.first { $0.id == engine.loadedID }?.name ?? "Untitled graph"
        context.insert(TraceModel(trace, sourceName: name))
        try? context.save()
    }

    private func save() { engine.persist(into: context) }
}
