//
//  Prompt_PlaygroundApp.swift
//  Prompt Playground
//
//  Created by 이원재 on 6/5/26.
//

import SwiftUI
import SwiftData

@main
struct Prompt_PlaygroundApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Schema(PlaygroundStore.models))
        } catch {
            fatalError("Failed to set up SwiftData container: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowResizability(.contentMinSize)
        .modelContainer(container)
    }
}
