import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var context

    var body: some View {
        TabView {
            GraphView()
                .tabItem { Label("Graph", systemImage: "point.3.connected.trianglepath.dotted") }
            DatasetsView()
                .tabItem { Label("Datasets", systemImage: "tablecells") }
            PipelineView()   // "Lab" tab; type/file kept as Pipeline* (see CLAUDE.md naming note)
                .tabItem { Label("Lab", systemImage: "chart.bar.doc.horizontal") }
        }
        .tint(Color.dsAccent)
        .preferredColorScheme(.dark)
        .task { SeedData.seedIfNeeded(context) }
    }
}
