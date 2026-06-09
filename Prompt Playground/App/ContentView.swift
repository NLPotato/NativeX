import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @State private var page: AppPage? = .workspace

    var body: some View {
        NavigationSplitView {
            List(AppPage.allCases, selection: $page) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            switch page ?? .workspace {
            case .workspace: WorkspaceTabs()
            case .history:   RunHistoryView()
            }
        }
        .tint(Color.dsAccent)
        .preferredColorScheme(.dark)
        .task { SeedData.seedIfNeeded(context) }
    }
}

/// The original authoring workspace — the three tabs are unchanged; they just live behind the
/// first sidebar page now (Run History is the second).
private struct WorkspaceTabs: View {
    var body: some View {
        TabView {
            GraphView()
                .tabItem { Label("Graph", systemImage: "point.3.connected.trianglepath.dotted") }
            DatasetsView()
                .tabItem { Label("Datasets", systemImage: "tablecells") }
            PipelineView()   // "Lab" tab; type/file kept as Pipeline* (see CLAUDE.md naming note)
                .tabItem { Label("Lab", systemImage: "chart.bar.doc.horizontal") }
        }
    }
}

enum AppPage: String, CaseIterable, Identifiable {
    case workspace, history
    var id: String { rawValue }
    var title: String { self == .workspace ? "Playground" : "Run History" }
    var symbol: String { self == .workspace ? "square.grid.2x2" : "clock.arrow.circlepath" }
}
