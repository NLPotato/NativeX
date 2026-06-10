import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var context
    let engine: GraphEngine   // owned by the App so the working graph survives page navigation
    @State private var tab = 0   // selected workspace tab (0 Playground · 1 Datasets · 2 Lab · 3 Run History)
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            GraphListSidebar(engine: engine, tab: $tab)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            WorkspaceTabs(engine: engine, tab: $tab)
        }
        .tint(Color.dsAccent)
        .preferredColorScheme(.dark)
        .task { SeedData.seedIfNeeded(context) }
        // ⌘\ — Figma-style "focus mode": hide BOTH side panels (left sidebar + right inspector) for a
        // clean full-canvas, or restore them. A hidden button carries the shortcut app-wide.
        .background {
            Button(action: togglePanels) { EmptyView() }
                .keyboardShortcut("\\", modifiers: .command).opacity(0).accessibilityHidden(true)
        }
    }

    private func togglePanels() {
        let anyShown = columnVisibility != .detailOnly || engine.showInspector
        withAnimation(.easeInOut(duration: 0.2)) {
            columnVisibility = anyShown ? .detailOnly : .all
            engine.showInspector = !anyShown
        }
    }
}

/// The authoring workspace. Run History moved in here as a fourth tab (was a separate sidebar page);
/// the left sidebar is now a graph list (GraphListSidebar). `tab` is bound up so the sidebar can jump
/// to Playground on select, and batch/compare results can deep-link to Lab.
private struct WorkspaceTabs: View {
    let engine: GraphEngine
    @Binding var tab: Int

    var body: some View {
        TabView(selection: $tab) {
            GraphView(engine: engine, onOpenLab: { tab = 2 })
                .tabItem { Label("Playground", systemImage: "point.3.connected.trianglepath.dotted") }
                .tag(0)
            DatasetsView()
                .tabItem { Label("Datasets", systemImage: "tablecells") }
                .tag(1)
            PipelineView()   // "Lab" tab; type/file kept as Pipeline* (see CLAUDE.md naming note)
                .tabItem { Label("Lab", systemImage: "chart.bar.doc.horizontal") }
                .tag(2)
            RunHistoryView()
                .tabItem { Label("Run History", systemImage: "clock.arrow.circlepath") }
                .tag(3)
        }
    }
}
