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
                }
                .padding(DS.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Color.clear
        }
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
            VStack(alignment: .leading, spacing: 1) {
                TextField("Title", text: node.title).dsTextField()
                Text(node.wrappedValue.kind.label).font(.dsMicro).foregroundStyle(.secondary)
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

            DSSectionHeader("Blocks — in order")
            let members = engine.members(of: node.id).sorted { $0.y < $1.y }   // assembly order = top→bottom
            if members.isEmpty {
                Text("No blocks yet. Add an Instruction / Current turn / Guided block and drag it into this frame.")
                    .font(.dsCaption).foregroundStyle(.tertiary)
            } else {
                ForEach(Array(members.enumerated()), id: \.element.id) { idx, m in
                    HStack(spacing: DS.Space.sm) {
                        Text("\(idx + 1)").font(.dsMicro.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 14, alignment: .trailing)
                        Image(systemName: m.kind.symbol).font(.dsCaption).foregroundStyle(.secondary).frame(width: 18)
                        Text(m.kind.label).font(.dsCaption)
                        Spacer(minLength: 0)
                        Text(m.title).font(.dsMicro).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }

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
                DSField(label: "Instruction", help: "System / persona / rules / NOT-TO-DO. {{vars}} are filled by wired Input or process nodes.") {
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
                DSField(label: "Role") {
                    Picker("", selection: h.role) {
                        ForEach(TurnRole.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                DSField(label: "Content", help: "A PAST turn. Order follows top→bottom canvas position.") {
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
                DSField(label: "Template", help: "The live turn sent to the model (respond-to). Wire an Input node into its {{vars}}.") {
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

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            Text("Constrain the model’s output to this schema (Apple Guided Generation). This is where you author the output contract.")
                .font(.dsCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SchemaEditorView(def: schemaBinding)
        }
    }

    private var schemaBinding: Binding<SchemaDef> {
        Binding(get: { node.guided?.schemaDef ?? .blank }, set: { node.guided?.schemaDef = $0 })
    }
}

// MARK: - Tool

private struct ToolEditor: View {
    @Binding var node: GraphNode

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            if let t = $node.tool.defaulted(ToolPayload()) {
                DSField(label: "Name") { TextField("tool name", text: t.name).dsTextField() }
                DSField(label: "Description") { TextEditor(text: t.toolDescription).font(.dsCode).dsEditor(lines: 4) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            if let p = $node.input.defaulted(InputPayload()) {
                DSField(label: "Source", help: "The variable values fed into a Prompt’s {{vars}}. Static + JSON run today; CSV/Excel/Dataset are coming.") {
                    Picker("", selection: p.source) {
                        ForEach(InputSource.allCases, id: \.self) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                switch node.input?.source ?? .staticLiteral {
                case .staticLiteral: staticEditor
                case .json:          jsonEditor(p)
                default:
                    Label("“\(node.input?.source.label ?? "")” input isn’t supported yet — use Static or JSON.", systemImage: "clock")
                        .font(.dsCaption).foregroundStyle(.dsWarning).fixedSize(horizontal: false, vertical: true)
                }
            }
            DSSectionHeader("Produces")
            let vars = node.inputVarNames
            Text(vars.isEmpty ? "No variables yet." : vars.joined(separator: ", "))
                .font(.dsCode).foregroundStyle(vars.isEmpty ? .tertiary : .secondary)
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

    private var staticKeys: [String] { (node.input?.statics.keys).map { $0.sorted() } ?? [] }
    private func staticValue(_ key: String) -> Binding<String> {
        Binding(get: { node.input?.statics[key] ?? "" }, set: { node.input?.statics[key] = $0 })
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
                DSField(label: "Operation") {
                    Picker("", selection: h.opRaw) {
                        ForEach(opChoices, id: \.self) { Text($0.displayName).tag($0.rawValue) }
                    }.labelsHidden()
                }
                if let op = node.hook?.op {
                    Text(op.detail).font(.dsCaption).foregroundStyle(.secondary)
                    if !op.portability.isPortable {
                        Label(op.portability.label, systemImage: "exclamationmark.triangle")
                            .font(.dsMicro).foregroundStyle(.dsWarning)
                    }
                }
                HStack(spacing: DS.Space.md) {
                    DSField(label: "in (input var)") { TextField("input", text: h.inputVar).dsTextField() }
                    DSField(label: "out (output var)") { TextField("output", text: h.outputVar).dsTextField() }
                }
                ForEach(node.hook?.op.paramKeys ?? [], id: \.self) { param in
                    DSField(label: param.label, help: param.placeholder) {
                        TextField(param.placeholder, text: paramBinding(param.rawValue)).dsTextField()
                    }
                }
            }
            PortWiringSection(engine: engine, nodeID: nodeID)
            ResolvedOutputSection(text: hookOutput, status: run?.status, error: run?.error)
        }
    }

    private var opChoices: [HookOp] {
        node.kind == .nativeAPI
            ? [.tokenizeWords, .enrichGloss, .detectLanguage, .sentenceSplit]
            : [.script, .regexExtract, .regexReplace, .jsonExtract, .textTransform]
    }
    private var hookOutput: String? {
        let key = (node.hook?.outputVar.isEmpty ?? true) ? "output" : (node.hook?.outputVar ?? "output")
        return run?.outputs[key]
    }
    private func paramBinding(_ key: String) -> Binding<String> {
        Binding(get: { node.hook?.params[key] ?? "" }, set: { node.hook?.params[key] = $0 })
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
                OutputBlock(title: "Generation (JSON)", text: prettyJSONString(json))
            } else if let out = run.outputs["output"], !out.isEmpty {
                OutputBlock(title: "Generation", text: out)
            }
            if let ms = run.ms {
                Text("\(ms) ms").font(.dsCaption).foregroundStyle(.tertiary).monospacedDigit()
            }
        } else {
            VStack(spacing: DS.Space.sm) {
                Image(systemName: "brain").font(.system(size: 28)).foregroundStyle(.tertiary)
                Text("Run the graph to see the model’s output here.")
                    .font(.dsCaption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, DS.Space.xl)
        }
    }
}

// MARK: - Shared blocks

/// The full composed prompt for a group: the TEMPLATE (raw {{vars}}, in top→bottom order) shown always,
/// plus the RESOLVED transcript/current turn after a run. Answers "show the full prompt template, in order".
private struct PromptCompositionView: View {
    let engine: GraphEngine
    let groupID: UUID
    let run: GraphNodeRun?

    var body: some View {
        let tmpl = GraphExecutor.assembleTemplate(groupID: groupID, graph: engine.graph)
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            DSSectionHeader("Prompt template — in order")
            if !tmpl.transcriptText.isEmpty {
                OutputBlock(title: "Instructions + history", text: tmpl.transcriptText)
            }
            OutputBlock(title: "Current turn", text: tmpl.currentTurn.isEmpty ? "(no current-turn block)" : tmpl.currentTurn)

            let resolvedT = run?.outputs["_transcript"] ?? ""
            let resolvedC = run?.outputs["_currentturn"] ?? ""
            if !resolvedT.isEmpty || !resolvedC.isEmpty {
                DSSectionHeader("Resolved — last run")
                if !resolvedT.isEmpty { OutputBlock(title: "Transcript", text: resolvedT) }
                OutputBlock(title: "Current turn", text: resolvedC)
            }
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
            DSSectionHeader("Inputs — wire each {{var}}")
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                ForEach(ports, id: \.self) { PortWiringRow(engine: engine, nodeID: nodeID, port: $0) }
            }
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
        VStack(alignment: .leading, spacing: 3) {
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
            .padding(.horizontal, DS.Space.sm).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}

private struct ResolvedOutputSection: View {
    let text: String?
    let status: GraphNodeRun.Status?
    let error: String?

    var body: some View {
        if status == .error, let error {
            DSSectionHeader("Output")
            Label(error, systemImage: "xmark.octagon.fill")
                .font(.dsCaption).foregroundStyle(.dsDanger).fixedSize(horizontal: false, vertical: true)
        } else if let text, !text.isEmpty {
            DSSectionHeader("Resolved output")
            OutputBlock(title: "Output", text: text)
        }
    }
}

/// A read-only monospace text panel with a copy button.
private struct OutputBlock: View {
    let title: String
    let text: String

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
                Text(text.isEmpty ? "—" : text)
                    .font(.dsCode).foregroundStyle(.primary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Space.sm)
            }
            .frame(maxHeight: 220)
            .codeSurface()
        }
    }
}
