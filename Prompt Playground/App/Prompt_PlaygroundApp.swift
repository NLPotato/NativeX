//
//  Prompt_PlaygroundApp.swift
//  Prompt Playground
//
//  Created by 이원재 on 6/5/26.
//

import SwiftUI
import SwiftData
import AppKit

@main
struct Prompt_PlaygroundApp: App {
    let container: ModelContainer
    // The Graph engine lives at app scope (not inside GraphView) so the working graph survives navigating
    // away to Run History and back, and so the quit-warning can read/save it.
    @State private var engine = GraphEngine(graph: GraphEngine.exampleGloss())
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        do {
            container = try ModelContainer(for: Schema(PlaygroundStore.models))
        } catch {
            fatalError("Failed to set up SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(engine: engine)
                .frame(minWidth: 760, minHeight: 480)
                .onAppear {
                    appDelegate.engine = engine
                    appDelegate.context = container.mainContext
                }
        }
        .windowResizability(.contentMinSize)
        .modelContainer(container)
    }
}

/// Warns about unsaved graph changes on quit (⌘Q / menu Quit). Holds the app-scoped engine + main context
/// so it can check `isDirty` and Save through the same path as the toolbar, even if GraphView isn't visible.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var engine: GraphEngine?
    var context: ModelContext?

    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        // NSApplicationDelegate callbacks run on the main thread; the engine is main-actor isolated.
        MainActor.assumeIsolated {
            guard let engine, engine.isDirty else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "Save changes to your graph before quitting?"
            alert.informativeText = "Your graph has unsaved changes. If you don’t save them, they’ll be lost."
            alert.addButton(withTitle: "Save")      // .alertFirstButtonReturn
            alert.addButton(withTitle: "Discard")   // .alertSecondButtonReturn
            alert.addButton(withTitle: "Cancel")    // .alertThirdButtonReturn
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if let context { engine.persist(into: context) }
                return .terminateNow
            case .alertThirdButtonReturn:
                return .terminateCancel
            default:
                return .terminateNow   // Discard
            }
        }
    }
}
