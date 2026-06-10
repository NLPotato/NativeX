//
//  GraphListSidebar.swift
//  Prompt Playground
//
//  The left sidebar — a Claude-Desktop-style list of saved graphs (replaces the old two-page AppPage nav;
//  Run History is now a workspace tab). New Graph up top; rows sort pinned-first then by most-recent-run;
//  inline rename, pin, delete. Selecting a graph loads it into the shared engine and jumps to Playground.
//
//  Persistence model (three tiers): the working graph autosaves to MEMORY (the app-scoped engine, survives
//  navigation); explicit Save commits it to local storage (a GraphModel — minted on first Save, named by
//  timestamp); the quit-warning (AppDelegate) + this sidebar's switch-guard cover unsaved work. So an
//  unsaved buffer appears here as a synthetic "Unsaved draft" row until you Save it.
//

import SwiftUI
import SwiftData
import AppKit

struct GraphListSidebar: View {
    @Bindable var engine: GraphEngine
    @Binding var tab: Int
    @Environment(\.modelContext) private var context
    @Query private var graphs: [GraphModel]
    @State private var renamingID: UUID? = nil
    @State private var hoveredID: UUID? = nil
    @FocusState private var renameFocused: Bool

    /// Pinned first, then most-recently-run (falling back to creation time for graphs that never ran).
    private var sorted: [GraphModel] {
        graphs.sorted { a, b in
            if a.isPinned != b.isPinned { return a.isPinned }
            return (a.lastRunAt ?? a.createdAt) > (b.lastRunAt ?? b.createdAt)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: newGraph) {
                Label("New Graph", systemImage: "plus")
                    .font(.dsLabel).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
            .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: DS.Radius.md))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(Theme.accent.opacity(0.35)))
            .foregroundStyle(Theme.accent)
            .padding(DS.Space.sm)

            Divider()

            List {
                // The in-memory working buffer that hasn't been committed to storage yet.
                if engine.loadedID == nil { unsavedDraftRow }
                ForEach(sorted) { g in row(g) }
            }
            .listStyle(.sidebar)
        }
        .navigationTitle("Graphs")
    }

    // MARK: Rows

    private var unsavedDraftRow: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "circle.dashed").font(.dsCaption).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("Unsaved draft").font(.dsLabel).lineLimit(1)
                Text("Not saved to storage").font(.dsMicro).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Circle().fill(Theme.gold).frame(width: 6, height: 6)   // dirty dot — the open, unsaved buffer
        }
        .padding(.vertical, 2)
        .listRowBackground(RoundedRectangle(cornerRadius: DS.Radius.sm).fill(Theme.accent.opacity(0.16)))
        .contextMenu { Button("Save to storage") { engine.persist(into: context) } }
    }

    @ViewBuilder private func row(_ g: GraphModel) -> some View {
        let isOpen = g.id == engine.loadedID
        HStack(spacing: DS.Space.sm) {
            Image(systemName: g.isPinned ? "pin.fill" : "point.3.connected.trianglepath.dotted")
                .font(.dsCaption).foregroundStyle(g.isPinned ? Theme.gold : .secondary).frame(width: 18)

            if renamingID == g.id {
                TextField("Name", text: nameBinding(g))
                    .textFieldStyle(.plain).font(.dsLabel).focused($renameFocused)
                    .onSubmit { renamingID = nil }
                    .onChange(of: renameFocused) { _, focused in if !focused { renamingID = nil } }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(g.name).font(.dsLabel).lineLimit(1)
                    Text(subtitle(g)).font(.dsMicro).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isOpen && engine.isDirty {
                Circle().fill(Theme.gold).frame(width: 6, height: 6).help("Unsaved changes")
            }
            if hoveredID == g.id && renamingID != g.id {
                Button { startRename(g) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).font(.dsCaption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hoveredID = $0 ? g.id : (hoveredID == g.id ? nil : hoveredID) }
        .onTapGesture { select(g) }
        .listRowBackground(RoundedRectangle(cornerRadius: DS.Radius.sm)
            .fill(isOpen ? Theme.accent.opacity(0.16) : Color.clear))
        .contextMenu {
            Button("Rename") { startRename(g) }
            Button(g.isPinned ? "Unpin" : "Pin") { g.isPinned.toggle(); try? context.save() }
            Divider()
            Button("Delete", role: .destructive) { delete(g) }
        }
    }

    private func subtitle(_ g: GraphModel) -> String {
        if let last = g.lastRunAt { return "ran \(last.formatted(.relative(presentation: .named)))" }
        return "created \(g.createdAt.formatted(.relative(presentation: .named)))"
    }

    // MARK: Actions

    private func nameBinding(_ g: GraphModel) -> Binding<String> {
        Binding(get: { g.name }, set: { g.name = $0; try? context.save() })
    }

    private func startRename(_ g: GraphModel) {
        renamingID = g.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func newGraph() { guardUnsaved { engine.newGraph(); tab = 0 } }

    private func select(_ g: GraphModel) {
        guard g.id != engine.loadedID else { tab = 0; return }   // already open → just focus Playground
        guardUnsaved { engine.loadGraph(g.graphDef, id: g.id); tab = 0 }
    }

    private func delete(_ g: GraphModel) {
        let wasOpen = g.id == engine.loadedID
        context.delete(g); try? context.save()
        if wasOpen { engine.newGraph() }
    }

    /// Switching/closing the working buffer with unsaved changes prompts the same Save/Discard/Cancel as
    /// the quit-warning (AppDelegate). Cancel aborts the navigation; Save commits through `engine.persist`.
    private func guardUnsaved(_ proceed: () -> Void) {
        guard engine.isDirty else { proceed(); return }
        let alert = NSAlert()
        alert.messageText = "Save changes to the current graph?"
        alert.informativeText = "You have unsaved changes. If you don’t save them, they’ll be lost."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: engine.persist(into: context); proceed()
        case .alertThirdButtonReturn: return                                   // Cancel
        default: proceed()                                                     // Discard
        }
    }
}
