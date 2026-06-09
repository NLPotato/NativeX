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
    @State private var engine = GraphEngine(graph: GraphEngine.exampleGloss())
    @State private var showInspector = true
    @Query(sort: \GraphModel.createdAt) private var saved: [GraphModel]

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                toolbar
                Divider()
                GraphCanvas(engine: engine)
                    .runningRadiance(active: engine.isRunning)
            }
            .frame(minWidth: 480)

            if showInspector {
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
            Button { Task { await engine.run() } } label: {
                Label(engine.isRunning ? "Running…" : "Run", systemImage: "play.fill")
            }
            .disabled(engine.isRunning || engine.graph.nodes.isEmpty)
            .tint(Theme.accent)

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
            } label: { Label("Add", systemImage: "plus") }
            .menuStyle(.borderlessButton).fixedSize()

            Button { engine.autoWireMatchingVars() } label: { Label("Auto-wire", systemImage: "link") }
                .keyboardShortcut("l", modifiers: .command)
                .help("Connect every unwired {{var}} to a same-named output (e.g. an Input’s learning → a block’s {{learning}})")

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

            Divider().frame(height: 16)

            // Zoom: − / % / + (also ⌘± ). Anchored to the viewport center via GraphEngine.zoom.
            Button { engine.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command).help("Zoom out")
            Text("\(Int((engine.scale * 100).rounded()))%")
                .font(.dsMicro).foregroundStyle(.secondary).monospacedDigit().frame(width: 40)
            Button { engine.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("+", modifiers: .command).help("Zoom in")
            Button { engine.fitToView() } label: { Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right") }
                .keyboardShortcut("0", modifiers: .command).help("Fit graph to view (⌘0)")

            Spacer()

            if let err = engine.runError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.dsCaption).foregroundStyle(.dsDanger).lineLimit(1)
            }

            Menu {
                Button("Insert example: gloss") {
                    engine.graph = GraphEngine.exampleGloss(); engine.loadedID = nil; engine.selection = nil; engine.runs = [:]
                }
                Divider()
                if saved.isEmpty {
                    Text("No saved graphs")
                } else {
                    ForEach(saved) { g in
                        Button(g.name) { engine.graph = g.graphDef; engine.loadedID = g.id; engine.selection = nil; engine.runs = [:] }
                    }
                }
            } label: { Label("Load", systemImage: "tray.and.arrow.down") }
            .menuStyle(.borderlessButton).fixedSize()

            Button { save() } label: { Label("Save", systemImage: "tray.and.arrow.up") }

            Divider().frame(height: 16)
            Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(showInspector ? "Hide inspector" : "Show inspector")
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

    private func save() {
        if let id = engine.loadedID, let m = saved.first(where: { $0.id == id }) {
            m.graphJSON = JSONCoder.encode(engine.graph)
            m.version += 1
        } else {
            let m = GraphModel(name: "Graph \(saved.count + 1)", graph: engine.graph)
            context.insert(m)
            engine.loadedID = m.id
        }
        try? context.save()
    }
}
