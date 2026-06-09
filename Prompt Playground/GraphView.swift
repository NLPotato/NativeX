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
                ForEach(NodeKind.allCases) { kind in
                    Button { engine.addNode(kind, at: engine.toCanvas(CGPoint(x: 240, y: 170))) } label: {
                        Label(kind.label, systemImage: kind.symbol)
                    }
                }
            } label: { Label("Add", systemImage: "plus") }
            .menuStyle(.borderlessButton).fixedSize()

            Button(role: .destructive) { engine.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                .disabled(engine.selection == nil)
                .tint(.red)

            Divider().frame(height: 16)

            // Zoom: − / % / + (also ⌘± ). Anchored to the viewport center via GraphEngine.zoom.
            Button { engine.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command).help("Zoom out")
            Text("\(Int((engine.scale * 100).rounded()))%")
                .font(.dsMicro).foregroundStyle(.secondary).monospacedDigit().frame(width: 40)
            Button { engine.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("+", modifiers: .command).help("Zoom in")
            Button { engine.scale = 1; engine.offset = .zero } label: { Label("Reset view", systemImage: "scope") }

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
