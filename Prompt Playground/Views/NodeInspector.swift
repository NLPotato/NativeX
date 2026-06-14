//
//  NodeInspector.swift
//  Prompt Playground
//
//  Right-hand inspector for the selected graph node (v2). Takes the engine + a node id (not a raw
//  binding) so it can read run results, resolve incoming edges, and inspect a Prompt group's members.
//
//  Each node kind gets a focused editor:
//    • Prompt group   — what it assembles + the request that gets sent.
//    • Instruction / History / Current — template text + wired inputs + resolved output.
//    • Few-shot       — demonstration user/assistant pairs.
//    • Guided output  — the SchemaEditor (where the output contract is authored).
//    • Tool           — name + description (v1: described, not callable).
//    • Input          — Static / JSON values (the ONLY place a {{var}} gets a value).
//    • Native API / Hook — the op editor + wired inputs + resolved output.
//    • Foundation Model — paged Prompt · Sampling · Generation (consumes the wired Prompt group).
//  Reuses GenConfigControls, SchemaEditorView, Vars, and the DS tokens verbatim.
//

import SwiftUI
import SwiftData
import AppKit

extension Binding {
    /// A non-force-unwrapping projection of an optional payload binding, substituting `fallback` when nil.
    /// Drop-in for the failable `Binding(_:)` init at the editor `if let` sites — same call shape, but the
    /// returned binding's getter NEVER force-unwraps. That matters on teardown: when the selected node is
    /// deleted, SwiftUI runs one final update on the outgoing editor while the payload is already nil, and a
    /// Picker/TextEditor re-reading a force-unwrapping `Binding($node.payload)` traps (EXC_BREAKPOINT). The
    /// returned optional is always `.some`, so the `if let` structure is preserved.
    func defaulted<T>(_ fallback: T) -> Binding<T>? where Value == T? {
        Binding<T>(get: { wrappedValue ?? fallback }, set: { wrappedValue = $0 })
    }
}

struct NodeInspector: View {
    @Bindable var engine: GraphEngine
    let nodeID: UUID

    var body: some View {
        if let node = nodeBinding {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    header(node)
                    Divider()
                    editor(node)
                    APIMappingSection(engine: engine, nodeID: nodeID)
                }
                .padding(DS.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Color.clear
        }
    }

    /// A Prompt group's badge reflects its whole subgraph (most restrictive tier, §6.2);
    /// every other node reports its own reach.
    private var inspectorPortability: Portability {
        guard let n = engine.graph.node(nodeID) else { return .universal }
        return n.kind == .promptGroup ? engine.graph.subgraphPortability(of: nodeID) : n.portability
    }

    private var nodeBinding: Binding<GraphNode>? {
        guard engine.graph.nodes.contains(where: { $0.id == nodeID }) else { return nil }
        return Binding(
            get: { engine.graph.nodes.first { $0.id == nodeID } ?? GraphNode(kind: .instruction) },
            set: { v in if let i = engine.graph.nodes.firstIndex(where: { $0.id == nodeID }) { engine.graph.nodes[i] = v } }
        )
    }

    private func header(_ node: Binding<GraphNode>) -> some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: node.wrappedValue.kind.symbol).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                TextField("Title", text: node.title).dsTextField()
                HStack(spacing: DS.Space.sm) {
                    Text(node.wrappedValue.kind.label).font(.dsMicro).foregroundStyle(.secondary)
                    PortabilityBadge(portability: inspectorPortability, showLabel: true, chip: true)   // §6.2
                }
                .lineLimit(1)
                if let api = node.wrappedValue.apiName {   // official API name, full width — never truncated (§6.1)
                    Text(api).font(.dsCode).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            // Walk to a connected node (prev = upstream feeders, next = downstream consumers) and center it.
            Button { engine.selectAdjacent(downstream: false) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut("[", modifiers: .command).disabled(!engine.hasAdjacent(downstream: false))
                .help("Previous connected node (⌘[)")
            Button { engine.selectAdjacent(downstream: true) } label: { Image(systemName: "chevron.right") }
                .keyboardShortcut("]", modifiers: .command).disabled(!engine.hasAdjacent(downstream: true))
                .help("Next connected node (⌘])")
        }
    }

    @ViewBuilder private func editor(_ node: Binding<GraphNode>) -> some View {
        let run = engine.runs[nodeID]
        switch node.wrappedValue.kind {
        case .promptGroup:      PromptGroupEditor(node: node, engine: engine, run: run)
        case .instruction:      InstructionEditor(node: node, engine: engine, nodeID: nodeID, run: run)
        case .fewshot:          FewshotEditor(node: node)
        case .history:          HistoryEditor(node: node, engine: engine, nodeID: nodeID, run: run)
        case .current:          CurrentEditor(node: node, engine: engine, nodeID: nodeID, run: run)
        case .guided:           GuidedEditor(node: node)
        case .tool:             ToolEditor(node: node)
        case .input:            InputEditor(node: node, run: run)
        case .nativeAPI, .hook: HookEditor(node: node, engine: engine, nodeID: nodeID, run: run)
        case .fm:               FMEditor(node: node, engine: engine, run: run)
        case .compare:          CompareEditor(engine: engine, node: node)
        }
    }
}

// MARK: - Prompt group

private struct PromptGroupEditor: View {
    @Binding var node: GraphNode
    let engine: GraphEngine
    let run: GraphNodeRun?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("A Prompt assembles its member blocks into one request. Blocks concatenate top→bottom — drag a block up or down to reorder it. Wire the frame’s output into a Foundation Model.")
                .font(.dsCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: DS.Space.sm) {
                DSSectionHeader("Blocks — in order")
                let members = engine.members(of: node.id).sorted { $0.y < $1.y }   // assembly order = top→bottom
                if members.isEmpty {
                    Text("No blocks yet. Add an Instruction / Current turn / Guided block and drag it into this frame.")
                        .font(.dsCaption).foregroundStyle(.tertiary)
                } else {
                    ForEach(Array(members.enumerated()), id: \.element.id) { idx, m in
                        HStack(spacing: DS.Space.sm) {
                            Text("\(idx + 1)").font(.dsMicro.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 14, alignment: .trailing)
                            Image(systemName: m.kind.symbol).font(.dsCaption).foregroundStyle(kindTint(m.kind)).frame(width: 18)
                            Text(m.kind.label).font(.dsCaption)
                            Spacer(minLength: 0)
                            Text(m.title).font(.dsMicro).foregroundStyle(.tertiary).lineLimit(1)
                            // Reorder = swap assembly order; the canvas stack re-snaps to match.
                            Button { engine.moveMember(m.id, up: true) } label: { Image(systemName: "chevron.up") }
                                .buttonStyle(.plain).font(.dsMicro).foregroundStyle(idx == 0 ? .quaternary : .secondary)
                                .disabled(idx == 0).help("Move earlier in the prompt")
                            Button { engine.moveMember(m.id, up: false) } label: { Image(systemName: "chevron.down") }
                                .buttonStyle(.plain).font(.dsMicro).foregroundStyle(idx == members.count - 1 ? .quaternary : .secondary)
                                .disabled(idx == members.count - 1).help("Move later in the prompt")
                        }
                    }
                }
            }
            .dsGroup()

            PromptCompositionView(engine: engine, groupID: node.id, run: run)
        }
    }
}

// MARK: - Instruction / History / Current (template blocks)

private struct InstructionEditor: View {
    @Binding var node: GraphNode
    let engine: GraphEngine
    let nodeID: UUID
    let run: GraphNodeRun?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            if let i = $node.instruction.defaulted(InstructionPayload()) {
                DSField(label: "Instruction",
                        api: "Transcript.Instructions(segments:)",
                        help: "System / persona / rules / NOT-TO-DO. {{vars}} are filled by wired Input or process nodes.") {
                    TextEditor(text: i.text).font(.dsCode).dsEditor(lines: 8)
                }
            }
            PortWiringSection(engine: engine, nodeID: nodeID)
            ResolvedOutputSection(text: run?.outputs["text"], status: run?.status, error: run?.error)
        }
    }
}

private struct HistoryEditor: View {
    @Binding var node: GraphNode
    let engine: GraphEngine
    let nodeID: UUID
    let run: GraphNodeRun?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            if let h = $node.history.defaulted(HistoryPayload()) {
                DSField(label: "Role",
                        api: "Human → Transcript.Prompt · AI → Transcript.Response") {
                    Picker("", selection: h.role) {
                        ForEach(TurnRole.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                DSField(label: "Content",
                        api: "segments : [Transcript.Segment]",
                        help: "A PAST turn. Order follows top→bottom canvas position.") {
                    TextEditor(text: h.content).font(.dsCode).dsEditor(lines: 5)
                }
            }
            PortWiringSection(engine: engine, nodeID: nodeID)
            ResolvedOutputSection(text: run?.outputs["turn"], status: run?.status, error: run?.error)
        }
    }
}

private struct CurrentEditor: View {
    @Binding var node: GraphNode
    let engine: GraphEngine
    let nodeID: UUID
    let run: GraphNodeRun?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            if let c = $node.current.defaulted(CurrentTurnPayload()) {
                DSField(label: "Template",
                        api: "session.respond(to:) — the live turn",
                        help: "The live turn sent to the model (respond-to). Wire an Input node into its {{vars}}.") {
                    TextEditor(text: c.template).font(.dsCode).dsEditor(lines: 5)
                }
            }
            PortWiringSection(engine: engine, nodeID: nodeID)
            ResolvedOutputSection(text: run?.outputs["currentturn"], status: run?.status, error: run?.error)
        }
    }
}

// MARK: - Few-shot

private struct FewshotEditor: View {
    @Binding var node: GraphNode

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Demonstration pairs. Appended to the instructions as labeled User/Assistant examples — not real conversation history.")
                .font(.dsCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let f = $node.fewshot.defaulted(FewShotPayload()) {
                ForEach(f.shots) { $shot in
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        TextField("user", text: $shot.user).dsTextField()
                        TextField("assistant", text: $shot.assistant).dsTextField()
                    }.dsFlat()
                }
                HStack {
                    Button { node.fewshot?.shots.append(FewShot()) } label: { Label("Add example", systemImage: "plus") }
                    if !(node.fewshot?.shots.isEmpty ?? true) {
                        Button(role: .destructive) { node.fewshot?.shots.removeLast() } label: { Label("Remove last", systemImage: "minus") }
                    }
                }.font(.dsCaption)
            }
        }
    }
}

// MARK: - Guided output

private struct GuidedEditor: View {
    @Binding var node: GraphNode
    @Environment(\.modelContext) private var context
    @Query(sort: \SchemaModel.createdAt, order: .reverse) private var library: [SchemaModel]
    @State private var savedNote: String? = nil
    @State private var query = ""
    @State private var showLibrary = false
    @State private var newSheet = false

    private var matches: [SchemaModel] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? library : library.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Constrain the model’s output to ONE @Generable (Apple Guided Generation). In the graph it runs as runtime DynamicGenerationSchema; the “@Generable Swift” pane below is the same contract as the compile-time macro that ships.")
                .font(.dsCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            // Reuse-or-create, one section: search the saved @Generable library (versioned, shared
            // with other graphs + the Lab's dynamic lane), or start a fresh one in a focused sheet.
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                DisclosureGroup(isExpanded: $showLibrary) {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        HStack(spacing: DS.Space.sm) {
                            Image(systemName: "magnifyingglass").font(.dsCaption).foregroundStyle(.tertiary)
                            TextField("Search saved @Generable schemas…", text: $query)
                                .textFieldStyle(.plain).font(.dsCaption)
                        }
                        .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(.dsHairline, lineWidth: 1))

                        ScrollView {
                            VStack(spacing: DS.Space.xs) {
                                ForEach(matches) { m in SchemaLibraryRow(model: m, node: $node) }
                                if matches.isEmpty {
                                    Text(library.isEmpty ? "No saved schemas yet — “Save to library” adds this one."
                                                         : "No schema matches “\(query)”.")
                                        .font(.dsCaption).foregroundStyle(.tertiary)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(DS.Space.sm)
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                    }
                    .padding(.top, DS.Space.sm)
                } label: {
                    HStack(spacing: DS.Space.sm) {
                        Text("@Generable library").font(.dsLabel)
                        Text("\(library.count) saved").font(.dsMicro).foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                        Button {
                            node.guided?.schemaDef = .blank
                            newSheet = true
                        } label: { Label("New…", systemImage: "plus") }
                        .buttonStyle(.borderless).font(.dsCaption)
                        .help("Start a fresh @Generable in a focused editor")
                    }
                }

                HStack(spacing: DS.Space.sm) {
                    Button { saveToLibrary() } label: { Label("Save to library", systemImage: "tray.and.arrow.down") }
                        .buttonStyle(.borderless)
                    Spacer(minLength: 0)
                    if let savedNote { Text(savedNote).font(.dsMicro).foregroundStyle(.dsSuccess) }
                }
                .font(.dsCaption)
            }
            .dsGroup()

            SchemaEditorView(def: schemaBinding)

            // The promotion path to the typed shipping lane: compile-safe @Generable Swift for this
            // schema (SwiftCodegen), ready to paste into the iOS client app.
            DisclosureGroup {
                OutputBlock(title: "Copy into the client app target",
                            text: SwiftCodegen.emit(schemaBinding.wrappedValue))
                    .padding(.top, DS.Space.sm)
            } label: {
                HStack(spacing: DS.Space.sm) {
                    Text("@Generable Swift").font(.dsLabel)
                    Text("the typed shipping lane").font(.dsCodeMicro).foregroundStyle(.tertiary)
                }
            }
        }
        .sheet(isPresented: $newSheet) {
            SchemaEditorSheet(def: schemaBinding, isPresented: $newSheet)
        }
    }

    private var schemaBinding: Binding<SchemaDef> {
        Binding(get: { node.guided?.schemaDef ?? .blank }, set: { node.guided?.schemaDef = $0 })
    }

    /// Insert a new SchemaModel version (same name ⇒ next version number — the template convention).
    private func saveToLibrary() {
        guard let def = node.guided?.schemaDef else { return }
        let version = (library.filter { $0.name == def.typeName }.map(\.version).max() ?? 0) + 1
        context.insert(SchemaModel(task: .custom, name: def.typeName, version: version, def: def))
        try? context.save()
        savedNote = "Saved \(def.typeName) v\(version)"
    }
}

/// One saved @Generable in the library list: name + version + shape summary; tap loads it into the
/// node (replacing the current schema — save first to keep edits).
private struct SchemaLibraryRow: View {
    let model: SchemaModel
    @Binding var node: GraphNode

    private var isCurrent: Bool { node.guided?.schemaDef?.typeName == model.name }

    var body: some View {
        Button {
            if let def = model.def { node.guided?.schemaDef = def }
        } label: {
            HStack(spacing: DS.Space.sm) {
                Text(model.name).font(.dsLabel)
                Text("v\(model.version)").dsBadge(.secondary)
                if let def = model.def {
                    Text("\(def.fields.count) field\(def.fields.count == 1 ? "" : "s")")
                        .font(.dsMicro).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                Text("@Generable").font(.dsCodeMicro).foregroundStyle(.tertiary)
            }
            .padding(DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isCurrent ? Theme.accent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        }
        .buttonStyle(.plain)
        .help("Load “\(model.name)” v\(model.version) into this node")
    }
}

// MARK: - Tool

private struct ToolEditor: View {
    @Binding var node: GraphNode

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            if let t = $node.tool.defaulted(ToolPayload()) {
                DSField(label: "Name", api: "ToolDefinition(name:)") {
                    TextField("tool name", text: t.name).dsTextField()
                }
                DSField(label: "Description", api: "ToolDefinition(description:)") {
                    TextEditor(text: t.toolDescription).font(.dsCode).dsEditor(lines: 4)
                }
            }
            Label("Described, not callable (v1). The model is told this tool exists (folded into the instructions), but can’t invoke it yet — real tools need compile-time Swift.",
                  systemImage: "info.circle")
                .font(.dsMicro).foregroundStyle(.dsWarning).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Input

private struct InputEditor: View {
    @Binding var node: GraphNode
    let run: GraphNodeRun?
    @State private var newVar = ""
    @Query(sort: \DatasetModel.createdAt) private var datasets: [DatasetModel]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            if let p = $node.input.defaulted(InputPayload()) {
                DSField(label: "Source", help: "The variable values fed into a Prompt’s {{vars}}. Static + JSON + Dataset run today; CSV/Excel are coming.") {
                    Picker("", selection: p.source) {
                        ForEach(InputSource.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                switch node.input?.source ?? .staticLiteral {
                case .staticLiteral: staticEditor
                case .json:          jsonEditor(p)
                case .dataset:       datasetEditor
                default:
                    Label("“\(node.input?.source.label ?? "")” input isn’t supported yet — use Static or JSON.", systemImage: "clock")
                        .font(.dsCaption).foregroundStyle(.dsWarning).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                DSSectionHeader("Produces")
                let vars = node.inputVarNames
                Text(vars.isEmpty ? "No variables yet." : vars.joined(separator: ", "))
                    .font(.dsCode).foregroundStyle(vars.isEmpty ? .tertiary : .secondary)
            }
            .dsGroup()
            ResolvedOutputSection(text: run?.outputs[node.inputVarNames.first ?? ""], status: run?.status, error: run?.error)
        }
    }

    private var staticEditor: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            ForEach(staticKeys, id: \.self) { key in
                HStack(spacing: DS.Space.sm) {
                    Text(key).font(.dsCode).frame(width: 90, alignment: .leading).lineLimit(1)
                    TextField("value", text: staticValue(key)).dsTextField()
                    Button(role: .destructive) { node.input?.statics[key] = nil } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: DS.Space.sm) {
                TextField("new variable", text: $newVar).dsTextField()
                Button {
                    let name = newVar.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { node.input?.statics[name] = node.input?.statics[name] ?? ""; newVar = "" }
                } label: { Label("Add", systemImage: "plus") }
                .disabled(newVar.trimmingCharacters(in: .whitespaces).isEmpty)
            }.font(.dsCaption)
        }
    }

    private func jsonEditor(_ p: Binding<InputPayload>) -> some View {
        DSField(label: "JSON object", help: "Top-level scalar fields become {{vars}}.") {
            TextEditor(text: p.jsonLiteral).font(.dsCode).dsEditor(lines: 8)
        }
    }

    private var datasetEditor: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            DSField(label: "Dataset", help: "Each row’s values feed the wired {{vars}}. Run the whole dataset from the toolbar’s “Run dataset”.") {
                Picker("", selection: datasetBinding) {
                    Text("Choose…").tag(UUID?.none)
                    ForEach(datasets) { d in Text("\(d.name) · \(d.examples.count) rows").tag(Optional(d.id)) }
                }.labelsHidden()
            }
            if datasets.isEmpty {
                Text("No datasets yet — create one in the Datasets tab.").font(.dsCaption).foregroundStyle(.tertiary)
            }
        }
    }

    /// On dataset selection, also denormalizes the dataset’s columns onto the node so its output ports
    /// become wireable (and auto-wire can match them to a block’s {{var}} by name).
    private var datasetBinding: Binding<UUID?> {
        Binding(
            get: { node.input?.datasetID },
            set: { id in
                node.input?.datasetID = id
                let cols = id.flatMap { did in datasets.first { $0.id == did } }
                    .map { Set($0.examples.flatMap { $0.rowValues.keys }).sorted() }
                node.input?.datasetColumns = cols
            })
    }

    private var staticKeys: [String] { (node.input?.statics.keys).map { $0.sorted() } ?? [] }
    private func staticValue(_ key: String) -> Binding<String> {
        Binding(get: { node.input?.statics[key] ?? "" }, set: { node.input?.statics[key] = $0 })
    }
}

// MARK: - Compare (A/B lanes)

private struct CompareEditor: View {
    let engine: GraphEngine
    @Binding var node: GraphNode
    @Environment(\.modelContext) private var context
    @Query(sort: \GraphModel.createdAt) private var saved: [GraphModel]
    @Query(sort: \DatasetModel.createdAt) private var datasets: [DatasetModel]
    @State private var runner = GraphCompareRunner()
    @State private var showResult = false

    private var groups: [GraphNode] { engine.graph.nodes.filter { $0.kind == .promptGroup } }
    private var selectedIDs: [UUID] { node.compare?.laneGroupIDs ?? [] }
    /// A lane is runnable only if its group feeds a Foundation Model — otherwise it produces no output.
    private func feedsFM(_ id: UUID) -> Bool { engine.graph.fmID(fedBy: id) != nil }
    private var runnableSelected: [UUID] { selectedIDs.filter(feedsFM) }
    /// The saved graph's name (matches the batch lane's label) — falls back when the graph is unsaved.
    private var graphName: String { saved.first { $0.id == engine.loadedID }?.name ?? "Untitled graph" }
    /// The dataset bound to this graph's Input, if any — when present, "Run comparison" fans each lane
    /// over every row (Phase 3) instead of the single static input.
    private var boundDataset: DatasetModel? {
        guard let id = engine.graph.nodes.first(where: {
            $0.kind == .input && $0.input?.source == .dataset
        })?.input?.datasetID else { return nil }
        return datasets.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            DSSectionHeader("Lanes")
            Text(boundDataset != nil
                 ? "Pick the Prompt groups to compare. Each lane runs over every row of the bound dataset → a Lab sweep."
                 : "Pick the Prompt groups to compare. Each runs on the same input — only the prompt varies.")
                .font(.dsCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if groups.isEmpty {
                Text("No Prompt groups in this graph yet — add a couple, each feeding its own Foundation Model.")
                    .font(.dsCaption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(groups) { g in
                    let runnable = feedsFM(g.id)
                    Toggle(isOn: laneBinding(g.id)) {
                        HStack(spacing: DS.Space.xs) {
                            Text(g.title.isEmpty ? "Prompt" : g.title).font(.dsBody)
                            if !runnable {
                                Text("· no model wired").font(.dsMicro).foregroundStyle(.dsWarning)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!runnable)   // an FM-less group can't run — can't be picked as a lane
                }
            }

            Button { runComparison() } label: {
                HStack(spacing: DS.Space.sm) {
                    if runner.isRunning { ProgressView().controlSize(.small) }
                    Text(runComparisonLabel).frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(runner.isRunning || runnableSelected.count < 2)
            .help(runnableSelected.count < 2 ? "Select at least two Prompt groups, each feeding a Foundation Model" : "Run the selected lanes side-by-side")

            if let err = runner.error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.dsCaption).foregroundStyle(.dsDanger).fixedSize(horizontal: false, vertical: true)
            }
            if let outcome = runner.lastOutcome, !runner.isRunning {
                Button { showResult = true } label: {
                    Label("View result · \(outcome.lanes.count) lanes", systemImage: "rectangle.split.3x1")
                }.buttonStyle(.link)
            }
        }
        .sheet(isPresented: $showResult) {
            if let outcome = runner.lastOutcome { CompareResultView(outcome: outcome) }
        }
    }

    private func laneBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { on in
                var ids = node.compare?.laneGroupIDs ?? []
                if on { if !ids.contains(id) { ids.append(id) } } else { ids.removeAll { $0 == id } }
                node.compare = ComparePayload(laneGroupIDs: ids)
            })
    }

    private var runComparisonLabel: String {
        if runner.isRunning {
            return boundDataset != nil ? "Row \(runner.completed)/\(runner.total)…" : "Running…"
        }
        if let ds = boundDataset { return "Run comparison × \(ds.name) (\(ds.examples.count) rows)" }
        return "Run comparison"
    }

    private func runComparison() {
        let ids = selectedIDs
        let name = graphName
        let dataset = boundDataset
        Task {
            await runner.run(graph: engine.graph, laneGroupIDs: ids, graphName: name,
                             dataset: dataset, context: context)
            if let o = runner.lastOutcome { engine.compareOutcome = o }   // → on-canvas lane cards
        }
    }
}

// MARK: - Hook / Native API

private struct HookEditor: View {
    @Binding var node: GraphNode
    let engine: GraphEngine
    let nodeID: UUID
    let run: GraphNodeRun?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            if let h = $node.hook.defaulted(HookDef(op: .textTransform)) {
                OpCatalogPicker(node: $node)
                // The whole editor below is GENERATED from the op's declaration: paramKeys says
                // which arguments exist (and how each renders), returnShape says whether the one
                // shared "Output as" projection applies. No per-op UI code (UX-First §4.2).
                let op = node.hook?.op ?? .textTransform
                DSField(label: "Input",
                        api: APICatalog.inputAnnotation(op: op),
                        help: "The {{var}} whose value feeds the call.") {
                    TextField("input", text: h.inputVar).dsTextField()
                }
                ForEach(op.paramKeys, id: \.self) { param in
                    if param == .command {
                        ScriptCommandEditor(node: $node)
                    } else {
                        DSField(label: param.label,
                                api: APICatalog.argAnnotation(op: op, param: param)) {
                            paramControl(param)
                        }
                    }
                }
                outputSection(h, op: op)
            }
            PortWiringSection(engine: engine, nodeID: nodeID)
            ResolvedOutputSection(text: hookOutput, status: run?.status, error: run?.error)
        }
    }

    /// Renders a param from its declared control: a closed set gets a picker (no magic strings),
    /// free text gets a field ({{vars}} allowed).
    @ViewBuilder private func paramControl(_ param: HookParam) -> some View {
        switch param.control {
        case .choice(let options):
            Picker("", selection: paramBinding(param.rawValue, default: options.first ?? "")) {
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
        case .text:
            TextField(param.placeholder, text: paramBinding(param.rawValue)).dsTextField()
        }
    }

    /// The serialization boundary, shared by every op: where the return value lands ({{out var}}),
    /// the one projection control for list-shaped returns, and a CONCRETE example of the output —
    /// the result is never a black box (UX-First §4.2).
    @ViewBuilder private func outputSection(_ h: Binding<HookDef>, op: HookOp) -> some View {
        let projection = node.hook?.projection ?? .numbered
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            DSField(label: "Output",
                    api: "→ {{\(currentOutputVar(op))}}") {
                TextField("output", text: h.outputVar).dsTextField()
            }
            if case .list = op.returnShape {
                DSField(label: "Output as") {
                    Picker("", selection: projectionBinding) {
                        ForEach(OutputProjection.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
            }
            if let preview = op.outputPreview(projection: projection) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Example output").font(.dsMicro.weight(.semibold)).foregroundStyle(.secondary)
                    Text(preview)
                        .font(.dsCodeMicro).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.sm)
                        .codeSurface()
                }
            }
            if case .object = op.returnShape {
                Label("Canonical JSON — chain a JSON extract node to pull one field.",
                      systemImage: "curlybraces")
                    .font(.dsMicro).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dsGroup()
    }

    private func currentOutputVar(_ op: HookOp) -> String {
        (node.hook?.outputVar.isEmpty == false ? node.hook?.outputVar : nil) ?? op.defaultOutputVar
    }
    private var projectionBinding: Binding<OutputProjection> {
        Binding(get: { node.hook?.projection ?? .numbered }, set: { node.hook?.projection = $0 })
    }
    private var hookOutput: String? {
        let key = (node.hook?.outputVar.isEmpty ?? true) ? "output" : (node.hook?.outputVar ?? "output")
        return run?.outputs[key]
    }
    private func paramBinding(_ key: String, default def: String = "") -> Binding<String> {
        Binding(get: { node.hook?.params[key] ?? def }, set: { node.hook?.params[key] = $0 })
    }
}

/// Catalog picker for the Native API / Hook operation (PRD §4.2, §8.3-lite). COLLAPSED at rest —
/// one combo-box row showing the selected op (name · symbol · framework) — and expands on click
/// into a searchable list grouped by framework, with PRD-planned ops folded into their own
/// disclosure so unselectable rows never occupy resting space. Scales past a flat list.
private struct OpCatalogPicker: View {
    @Binding var node: GraphNode
    @State private var query = ""
    @State private var expanded = false
    @State private var showPlanned = false

    /// Ops offered for this node kind (mirrors the original split: NL/FM ops on a Native API node;
    /// glue/script ops on a Hook node). Planned entries surface on the Native API side only.
    private var candidates: [APICatalogEntry] {
        let ops: [HookOp] = node.kind == .nativeAPI
            ? [.tokenizeWords, .enrichGloss, .detectLanguage, .sentenceSplit, .namedEntities, .sentiment, .textStats, .countTokens]
            : [.script, .regexExtract, .regexReplace, .jsonExtract, .textTransform, .chunkText]
        return ops.compactMap(APICatalog.entry(for:))
    }
    private var planned: [APICatalogEntry] {
        node.kind == .nativeAPI ? APICatalog.entries.filter { $0.status == .planned } : []
    }
    private var matches: [APICatalogEntry] { APICatalog.search(query, in: candidates) }
    private var plannedMatches: [APICatalogEntry] { APICatalog.search(query, in: planned) }
    /// Available matches grouped by framework, preserving catalog order — sticky scan headers.
    private var grouped: [(framework: String, entries: [APICatalogEntry])] {
        var order: [String] = [], byFw: [String: [APICatalogEntry]] = [:]
        for e in matches {
            if byFw[e.framework] == nil { order.append(e.framework) }
            byFw[e.framework, default: []].append(e)
        }
        return order.map { ($0, byFw[$0]!) }
    }
    private var selected: APICatalogEntry? { node.hook.flatMap { APICatalog.entry(for: $0.op) } }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            DSSectionHeader("Operation")

            // Closed state: the selected op as one row (title line + symbol·framework line — the
            // narrow pane never wraps mid-word); click to browse.
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(alignment: .top, spacing: DS.Space.sm) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(selected?.name ?? "Choose an operation…").font(.dsLabel)
                        HStack(spacing: DS.Space.sm) {
                            Text(selected?.calls.first?.symbol ?? "").font(.dsCodeMicro).foregroundStyle(.tertiary)
                            if let fw = selected?.framework {
                                Text(fw).font(.dsMicro).foregroundStyle(.dsInfo)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.dsMicro).foregroundStyle(.secondary)
                }
                .padding(DS.Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(.dsHairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(selected?.summary ?? "Browse the API catalog")

            if expanded {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "magnifyingglass").font(.dsCaption).foregroundStyle(.tertiary)
                    TextField("Search APIs — name, symbol, framework…", text: $query)
                        .textFieldStyle(.plain).font(.dsCaption)
                }
                .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(.dsHairline, lineWidth: 1))

                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        ForEach(grouped, id: \.framework) { group in
                            Text(group.framework.uppercased())
                                .font(.dsMicro.weight(.semibold)).kerning(0.6).foregroundStyle(.tertiary)
                                .padding(.top, DS.Space.xs)
                            ForEach(group.entries) { entry in
                                OpRow(entry: entry, node: $node) {
                                    withAnimation(.easeInOut(duration: 0.15)) { expanded = false }
                                }
                            }
                        }
                        if matches.isEmpty && plannedMatches.isEmpty {
                            Text("No API matches “\(query)”.")
                                .font(.dsCaption).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(DS.Space.sm)
                        }
                        if !plannedMatches.isEmpty {
                            DisclosureGroup(isExpanded: $showPlanned) {
                                VStack(spacing: DS.Space.xs) {
                                    ForEach(plannedMatches) { OpRow(entry: $0, node: $node) }
                                }
                                .padding(.top, DS.Space.xs)
                            } label: {
                                HStack(spacing: DS.Space.sm) {
                                    Text("Planned").font(.dsMicro.weight(.semibold)).kerning(0.6)
                                    Text("PRD §5.4.1 — not yet executable")
                                        .font(.dsMicro).foregroundStyle(.tertiary)
                                }
                                .foregroundStyle(.secondary)
                            }
                            .padding(.top, DS.Space.xs)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .dsGroup()
    }
}

/// Multi-line authoring surface for the script op's command + the persistent script library
/// (HookScriptModel) — the "add a new script" interface. The I/O contract is the documented
/// boundary (ADR-20260608-script-hooks): input → stdin · trimmed stdout → out var · every context
/// var exported as $PP_NAME · non-zero exit or timeout ⇒ node error carrying stderr.
private struct ScriptCommandEditor: View {
    @Binding var node: GraphNode
    @Environment(\.modelContext) private var context
    @Query(sort: \HookScriptModel.createdAt, order: .reverse) private var scripts: [HookScriptModel]
    @State private var savedNote: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            DSField(label: "command — /bin/zsh",
                    api: "Process.arguments = [\"-c\", command]",
                    help: "stdin ← in var · stdout → out var · context vars as $PP_NAME · non-zero exit or timeout ⇒ node error") {
                TextEditor(text: commandBinding).font(.dsCode).dsEditor(lines: 6)
            }
            HStack(spacing: DS.Space.sm) {
                Menu {
                    if scripts.isEmpty { Text("No saved scripts yet") }
                    ForEach(scripts) { s in
                        Button(s.name) { node.hook?.params[HookParam.command.rawValue] = s.command }
                    }
                    if !scripts.isEmpty {
                        Divider()
                        Menu("Delete…") {
                            ForEach(scripts) { s in
                                Button(s.name, role: .destructive) { context.delete(s); try? context.save() }
                            }
                        }
                    }
                } label: { Label("Scripts", systemImage: "tray.full") }
                .menuStyle(.borderlessButton).fixedSize()

                Button { saveScript() } label: { Label("Save script", systemImage: "tray.and.arrow.down") }
                    .buttonStyle(.borderless)
                    .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer(minLength: 0)
                if let savedNote { Text(savedNote).font(.dsMicro).foregroundStyle(.dsSuccess) }
            }
            .font(.dsCaption)
        }
    }

    private var command: String { node.hook?.params[HookParam.command.rawValue] ?? "" }
    private var commandBinding: Binding<String> {
        Binding(get: { command }, set: { node.hook?.params[HookParam.command.rawValue] = $0 })
    }

    /// Save under the node's title, else the command's first line — enough identity to re-find it.
    private func saveScript() {
        let firstLine = String((command.split(separator: "\n").first.map(String.init) ?? "script").prefix(40))
        let name = node.title.isEmpty ? firstLine : node.title
        context.insert(HookScriptModel(name: name, command: command))
        try? context.save()
        savedNote = "Saved “\(name)”"
    }
}

private struct OpRow: View {
    let entry: APICatalogEntry
    @Binding var node: GraphNode
    var onSelect: (() -> Void)? = nil

    private var isSelected: Bool { entry.op != nil && node.hook?.op == entry.op }
    private var selectable: Bool { entry.status == .available && entry.op != nil }

    var body: some View {
        Button {
            guard let op = entry.op else { return }
            // Refresh the output var only when it's still the previous op's default (don't clobber
            // a custom name); params persist — matching keys carry across ops.
            let oldDefault = node.hook?.op.defaultOutputVar
            node.hook?.opRaw = op.rawValue
            if (node.hook?.outputVar.isEmpty ?? true) || node.hook?.outputVar == oldDefault {
                node.hook?.outputVar = op.defaultOutputVar
            }
            onSelect?()
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.sm) {
                    Text(entry.name).font(.dsLabel)
                        .foregroundStyle(selectable ? Color.primary : Color.secondary)
                    Spacer(minLength: 0)
                    if entry.status == .planned {
                        Text("planned").dsBadge(.secondary)
                    } else if !entry.portability.isPortable {
                        Text(entry.portability.label).dsBadge(.dsWarning)
                    } else if let note = entry.availabilityNote {
                        Text(note).dsBadge(.dsInfo)   // version-gated native path; runs `fallback` below `since`
                    }
                }
                HStack(spacing: DS.Space.sm) {
                    Text(entry.calls.first?.symbol ?? "").font(.dsCodeMicro).foregroundStyle(.tertiary)
                    Text(entry.framework).font(.dsMicro).foregroundStyle(.dsInfo)
                }
                Text(entry.summary).font(.dsMicro).foregroundStyle(.tertiary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.accent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm)
                .strokeBorder(isSelected ? Theme.accent.opacity(0.5) : .clear))
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .help(entry.status == .planned ? "Planned (PRD §5.4.1) — not yet executable in this build" : entry.summary)
    }
}

// MARK: - FM (paged: Prompt · Sampling · Generation)

private struct FMEditor: View {
    @Binding var node: GraphNode
    let engine: GraphEngine
    let run: GraphNodeRun?

    enum Tab: String, CaseIterable, Hashable { case prompt = "Prompt", sampling = "Sampling", generation = "Generation" }
    @State private var tab: Tab

    init(node: Binding<GraphNode>, engine: GraphEngine, run: GraphNodeRun?) {
        self._node = node
        self.engine = engine
        self.run = run
        _tab = State(initialValue: run?.status == .ok ? .generation : .prompt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            switch tab {
            case .prompt:     promptTab
            case .sampling:   samplingTab
            case .generation: generationTab
            }
        }
        .onChange(of: run?.status) { _, status in if status == .ok { tab = .generation } }
    }

    @ViewBuilder private var promptTab: some View {
        if let gid = engine.graph.promptGroupID(feeding: node.id), let g = engine.graph.node(gid) {
            let problems = engine.fmIssues(node.id)
            if !problems.isEmpty { readinessBanner(problems) }
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "rectangle.3.group").font(.dsMicro).foregroundStyle(.secondary)
                Text("Fed by \(g.title.isEmpty ? "Prompt" : g.title)").font(.dsCaption).foregroundStyle(.secondary)
            }
            PromptCompositionView(engine: engine, groupID: gid, run: run)
        } else {
            Label("Not fed by a Prompt yet — drag a Prompt group’s output into this node’s prompt port.", systemImage: "exclamationmark.triangle")
                .font(.dsCaption).foregroundStyle(.dsWarning).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What's stopping this model from running, listed BEFORE you press Run (Run also aborts up front on
    /// these — see GraphExecutor.run). Mirrors the amber canvas badges on the offending nodes.
    private func readinessBanner(_ problems: [GraphIssue]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Label("This Prompt isn’t ready to run", systemImage: "exclamationmark.triangle.fill")
                .font(.dsCaption.weight(.semibold)).foregroundStyle(.dsWarning)
            ForEach(problems) { p in
                Text("• \(p.message)").font(.dsCaption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.gold.opacity(0.10), in: RoundedRectangle(cornerRadius: DS.Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(Theme.gold.opacity(0.35)))
    }

    @ViewBuilder private var samplingTab: some View {
        if let fm = $node.fm.defaulted(FMPayload()) {
            GenConfigControls(config: fm.config)
        }
        if let msg = ModelAvailability.message {
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.dsCaption).foregroundStyle(.dsWarning).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var generationTab: some View {
        if let run, run.status == .ok || run.status == .error {
            if run.status == .error, let err = run.error {
                Label(err, systemImage: "xmark.octagon.fill")
                    .font(.dsCaption).foregroundStyle(.dsDanger).fixedSize(horizontal: false, vertical: true)
            }
            if let json = run.outputs["json"], !json.isEmpty {
                OutputBlock(title: "Generation (JSON)", text: prettyJSONString(json), structured: true)
            } else if let out = run.outputs["output"], !out.isEmpty {
                OutputBlock(title: "Generation", text: out)
            }
            if let ms = run.ms {
                Text("\(ms) ms").font(.dsCaption).foregroundStyle(.tertiary).monospacedDigit()
            }
            // The conversation as the framework recorded it (session.transcript readback) — the
            // node's `transcript` output port carries its text projection downstream.
            if let def = run.transcript, !def.isEmpty {
                DisclosureGroup {
                    TranscriptEntryList(def: def).padding(.top, DS.Space.sm)
                } label: {
                    HStack(spacing: DS.Space.sm) {
                        Text("Conversation").font(.dsLabel)
                        Text("session.transcript · \(def.entries.count) entries")
                            .font(.dsCodeMicro).foregroundStyle(.tertiary)
                    }
                }
            }
        } else {
            VStack(spacing: DS.Space.sm) {
                Image(systemName: "brain").font(.dsDisplay).foregroundStyle(.tertiary)
                Text("Run the graph to see the model’s output here.")
                    .font(.dsCaption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, DS.Space.xl)
        }
    }
}

// MARK: - API mapping (every node: which Apple API, which argument, fed by which control)

/// The "what does this GUI actually call" section (UX-First §4.2): every Apple API call the
/// selected node performs, each argument mapped to the control / wire that feeds it — with live
/// current values — plus a link into Apple Developer Documentation (§8.3-lite). Data lives in
/// APICatalog so the node-header chip, the op picker, and this section can never drift.
private struct APIMappingSection: View {
    let engine: GraphEngine
    let nodeID: UUID
    @State private var expanded = false

    var body: some View {
        if let node = engine.graph.node(nodeID) {
            let calls = APICatalog.calls(for: node, graph: engine.graph)
            if !calls.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: DS.Space.md) {
                        ForEach(calls) { APICallView(call: $0) }
                    }
                    .padding(.top, DS.Space.sm)
                } label: {
                    HStack(spacing: DS.Space.sm) {
                        Image(systemName: "function").font(.dsCaption).foregroundStyle(.secondary)
                        Text("API mapping").font(.dsLabel)
                        Text("\(calls.count) call\(calls.count == 1 ? "" : "s")")
                            .font(.dsMicro).foregroundStyle(.tertiary)
                    }
                }
                .dsGroup()
            }
        }
    }
}

private struct APICallView: View {
    let call: APICall

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.sm) {
                Text(call.symbol).font(.dsCode.weight(.semibold)).textSelection(.enabled)
                Spacer(minLength: 0)
                if let url = call.docURL {
                    Link(destination: url) {
                        Label("Docs", systemImage: "arrow.up.right.square").font(.dsMicro)
                    }
                    .help("Open in Apple Developer Documentation")
                }
            }
            Text(call.signature).font(.dsCodeMicro).foregroundStyle(.secondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            ForEach(call.args) { arg in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                    Text(arg.name).font(.dsCodeMicro)
                        .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xxs)
                        .background(.quaternary, in: Capsule())
                    Text(arg.type).font(.dsCodeMicro).foregroundStyle(.tertiary)
                    Image(systemName: "arrow.left").font(.dsMicro).foregroundStyle(.tertiary)
                    Text(arg.source).font(.dsMicro).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let returns = call.returns {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                    Image(systemName: "arrow.turn.down.right").font(.dsMicro).foregroundStyle(.tertiary)
                    Text(returns).font(.dsMicro).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let note = call.note {
                Label(note, systemImage: "info.circle").font(.dsMicro).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: DS.Radius.sm))
    }
}

// MARK: - Shared blocks

/// The full composed prompt for a group: the TEMPLATE (raw {{vars}}, in top→bottom order) shown always,
/// plus the RESOLVED request after a run — entry by entry, as the Transcript protocol value the group
/// emitted (TranscriptDef). Answers "show the full prompt template, in order".
private struct PromptCompositionView: View {
    let engine: GraphEngine
    let groupID: UUID
    let run: GraphNodeRun?

    var body: some View {
        let tmpl = GraphExecutor.assembleTemplate(groupID: groupID, graph: engine.graph)
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                DSSectionHeader("Prompt template — in order")
                if !tmpl.transcriptText.isEmpty {
                    OutputBlock(title: "Instructions + history", text: tmpl.transcriptText)
                }
                OutputBlock(title: "Current turn", text: tmpl.currentTurn.isEmpty ? "(no current-turn block)" : tmpl.currentTurn)
            }
            .dsGroup()

            if let def = run?.transcript, !def.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    DSSectionHeader("Resolved request — last run · Transcript")
                    TranscriptEntryList(def: def)
                }
                .dsGroup()
            } else {
                let resolvedT = run?.outputs["_transcript"] ?? ""
                let resolvedC = run?.outputs["_currentturn"] ?? ""
                if !resolvedT.isEmpty || !resolvedC.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        DSSectionHeader("Resolved — last run")
                        if !resolvedT.isEmpty { OutputBlock(title: "Transcript", text: resolvedT) }
                        OutputBlock(title: "Current turn", text: resolvedC)
                    }
                    .dsGroup()
                }
            }
        }
    }
}

/// The conversation lane, entry by entry: role + the official `Transcript.*` symbol per entry
/// (UX-First §4.2), with the guided schema + sampling chips on prompt entries. Shared by the
/// Prompt-group inspector (the emitted request) and the FM inspector (the session readback).
struct TranscriptEntryList: View {
    let def: TranscriptDef

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            ForEach(def.entries) { entry in
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack(spacing: DS.Space.sm) {
                        Text(entry.roleLabel).dsBadge(entry.kind == .response ? .dsAccent : .secondary)
                        Text(entry.apiName).font(.dsCodeMicro).foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                        if let schema = entry.responseFormatName {
                            Text(schema).dsBadge(.dsInfo)
                        }
                    }
                    if let options = entry.optionsLabel, !options.isEmpty {
                        Text(options).font(.dsMicro).foregroundStyle(.tertiary)
                    }
                    Text(entry.text.isEmpty ? "—" : entry.text)
                        .font(.dsCode).foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.sm)
                        .codeSurface()
                }
            }
            Text("~\(def.estimatedTokens) estimated tokens · \(def.entries.count) entries")
                .font(.dsMicro).foregroundStyle(.tertiary).monospacedDigit()
        }
    }
}

/// Per-input-port source picker: one row for each {{var}} the node consumes, with a dropdown to choose
/// (or clear) which node feeds it — the inspector counterpart to dragging a wire on the canvas. Shows the
/// carried value after a run. Only nodes that OUTPUT a value of the port's name are offered (the dataflow
/// matches by name), so the list is always meaningful.
private struct PortWiringSection: View {
    let engine: GraphEngine
    let nodeID: UUID

    var body: some View {
        let ports = engine.graph.node(nodeID)?.inputPorts ?? []
        if !ports.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                DSSectionHeader("Inputs — wire each {{var}}")
                ForEach(ports, id: \.self) { PortWiringRow(engine: engine, nodeID: nodeID, port: $0) }
            }
            .dsGroup()
        }
    }
}

private struct PortWiringRow: View {
    let engine: GraphEngine
    let nodeID: UUID
    let port: String

    var body: some View {
        let producers = engine.producers(of: port, excluding: nodeID)
        let current = engine.graph.incoming(nodeID).first { $0.inputPort == port }
        let value = current.flatMap { engine.runs[$0.fromNodeID]?.outputs[$0.outputKey] }
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.xs) {
                tag(port)
                Image(systemName: "arrow.left").font(.dsMicro).foregroundStyle(.tertiary)
                Menu {
                    if current != nil {
                        Button(role: .destructive) { engine.unwire(to: nodeID, port: port) } label: {
                            Label("Disconnect", systemImage: "xmark")
                        }
                        Divider()
                    }
                    if producers.isEmpty {
                        Text("No node outputs “\(port)”")
                    } else {
                        ForEach(producers) { p in
                            Button { engine.wire(from: p.id, key: port, to: nodeID, port: port) } label: {
                                Label(engine.displayTitle(p.id), systemImage: p.kind.symbol)
                            }
                        }
                    }
                } label: {
                    if let c = current {
                        Text(engine.displayTitle(c.fromNodeID)).font(.dsCaption.weight(.medium)).lineLimit(1)
                    } else {
                        Text("Choose source…").font(.dsCaption).foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                if current == nil && producers.isEmpty {
                    Text("nothing outputs it yet").font(.dsMicro).foregroundStyle(.tertiary)
                }
            }
            if let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                Text(v).font(.dsMicro).foregroundStyle(.secondary).lineLimit(2).padding(.leading, DS.Space.xs)
            }
        }
    }

    private func tag(_ p: String) -> some View {
        Text(p).font(.dsCode).foregroundStyle(.primary)
            .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xxs)
            .background(.quaternary, in: Capsule())
    }
}

private struct ResolvedOutputSection: View {
    let text: String?
    let status: GraphNodeRun.Status?
    let error: String?

    var body: some View {
        if status == .error, let error {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                DSSectionHeader("Output")
                Label(error, systemImage: "xmark.octagon.fill")
                    .font(.dsCaption).foregroundStyle(.dsDanger).fixedSize(horizontal: false, vertical: true)
            }
            .dsGroup()
        } else if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                DSSectionHeader("Resolved output")
                OutputBlock(title: "Output", text: text)
            }
            .dsGroup()
        }
    }
}

/// A read-only output panel with a copy button. `structured` renders parseable JSON as a key-value
/// outline (JSONOutlineView) — copy still copies the raw text; non-JSON falls back to monospace.
private struct OutputBlock: View {
    let title: String
    let text: String
    var structured: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack {
                Text(title).font(.dsMicro.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Copy").disabled(text.isEmpty)
            }
            ScrollView {
                Group {
                    if structured, let node = JSONOutline.parse(text), node.isContainer {
                        JSONOutlineView(node: node)
                    } else {
                        Text(text.isEmpty ? "—" : text).font(.dsCode).foregroundStyle(.primary)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Space.sm)
            }
            .frame(maxHeight: 220)
            .codeSurface()
        }
    }
}
