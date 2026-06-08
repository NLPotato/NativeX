import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var context

    var body: some View {
        TabView {
            GlossView()
                .tabItem { Label("Gloss", systemImage: "text.book.closed") }
            RoleplayView()
                .tabItem { Label("Role-play", systemImage: "bubble.left.and.bubble.right") }
            DatasetsView()
                .tabItem { Label("Datasets", systemImage: "tablecells") }
            PipelineView()   // "Lab" tab; type/file kept as Pipeline* (see CLAUDE.md naming note)
                .tabItem { Label("Lab", systemImage: "chart.bar.doc.horizontal") }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .task { SeedData.seedIfNeeded(context) }
    }
}

struct GlossView: View {
    @Environment(\.modelContext) private var context
    @State private var model = PlaygroundModel()
    @State private var showingSave = false
    @State private var savedMessage: String?

    // The genericized tab saves/loads under the `.generic` task lane.
    @Query(filter: #Predicate<PromptTemplateModel> { $0.taskRaw == "generic" }, sort: \.createdAt)
    private var templates: [PromptTemplateModel]
    @Query(filter: #Predicate<SchemaModel> { $0.taskRaw == "generic" }, sort: \.createdAt)
    private var savedSchemas: [SchemaModel]

    private var exampleLabel: String {
        let s = model.input.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Run example" : String(s.prefix(40))
    }
    private var exampleJSON: String {
        JSONCoder.encode(GenericInput(input: model.input, variables: model.variableValues))
    }
    private var canSaveExample: Bool {
        !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        @Bindable var model = model

        HSplitView {
            // INPUT
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let msg = model.availabilityMessage {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !templates.isEmpty {
                        Menu {
                            ForEach(templates) { t in
                                Button("\(t.name) v\(t.version)") {
                                    model.instructions = t.instructions
                                    model.hooks = t.hooks          // restore the saved hook pipeline
                                    model.config = t.genConfig     // …and the config it was tuned with
                                }
                            }
                        } label: { Label("Load prompt", systemImage: "square.and.arrow.down.on.square") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    Picker("Preset", selection: $model.selectedPresetID) {
                        ForEach(presets) { Text($0.name).tag($0.id) }
                    }
                    .onChange(of: model.selectedPresetID) { _, newID in
                        model.loadPresetDefaults(for: newID)
                    }

                    field("Input") {
                        TextField("User message sent to the model (also the {{input}} variable)",
                                  text: $model.input, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                            .frame(minHeight: 56)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Variables").font(.footnote).fontWeight(.medium).foregroundStyle(.primary.opacity(0.6))
                        VStack(spacing: 6) {
                            if model.variableKeys.isEmpty && model.hookOutputs.isEmpty && model.malformedTokens.isEmpty {
                                Text("No variables. Add a {{name}} token in Instructions or Input.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            ForEach(model.variableKeys, id: \.self) { key in
                                variableRow(key: key, value: Binding(
                                    get: { model.variableValues[key] ?? "" },
                                    set: { model.variableValues[key] = $0 }))
                            }
                            if !model.hookOutputs.isEmpty {
                                Label("Provided by hooks: \(model.hookOutputs.sorted().map { "{{\($0)}}" }.joined(separator: ", "))",
                                      systemImage: "wand.and.stars")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !model.malformedTokens.isEmpty {
                                Label("Unrecognized: \(model.malformedTokens.joined(separator: ", ")). Use letters, digits, or _ inside {{ }}.",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !model.unusedHookOutputs.isEmpty {
                                Label("Hook output unused: \(model.unusedHookOutputs.map { "{{\($0)}}" }.joined(separator: ", ")). Nothing reads it — check the hook's “out” name matches a {{token}} in your prompt.",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(10)
                        .glassCard(radius: 8)
                    }

                    field("Instructions") {
                        TextEditor(text: $model.instructions)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 240)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    }

                    DisclosureGroup("Generation config") {
                        GenConfigControls(config: $model.config).padding(.top, 4)
                    }
                    .font(.callout)
                    .fontWeight(.semibold)

                    DisclosureGroup("Output schema") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Use a custom schema (run dynamically)", isOn: $model.useCustomSchema)
                            if model.useCustomSchema {
                                if !savedSchemas.isEmpty {
                                    Menu {
                                        ForEach(savedSchemas) { s in
                                            Button("\(s.name) v\(s.version)") { if let d = s.def { model.customSchema = d } }
                                        }
                                    } label: { Label("Load saved schema", systemImage: "tray.and.arrow.up") }
                                    .font(.caption).fixedSize()
                                }
                                SchemaEditorView(def: $model.customSchema)
                                Text("Runs via DynamicGenerationSchema. Save it + export Swift from “Save to Lab…”.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text("No schema — the model returns free-form text.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)
                    .fontWeight(.semibold)

                    DisclosureGroup("Hooks") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Deterministic native-API steps run before/after the model. A pre-hook’s output becomes a {{variable}} you can use in the prompt.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HooksEditorView(hooks: $model.hooks)
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)
                    .fontWeight(.semibold)

                    Button {
                        Task { await model.run() }
                    } label: {
                        HStack(spacing: 6) {
                            if model.isRunning { ProgressView().controlSize(.small) }
                            Text(model.isRunning ? "Running…" : "Run")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isRunning || !model.isModelAvailable)

                    Button {
                        savedMessage = nil
                        showingSave = true
                    } label: {
                        Label("Save to Lab…", systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(model.isRunning)
                    .sheet(isPresented: $showingSave) {
                        SaveToPipelineSheet(
                            task: .generic,
                            promptInstructions: model.instructions,
                            defaultTemplateName: "Playground prompt",
                            defaultExampleLabel: exampleLabel,
                            exampleInputJSON: exampleJSON,
                            canSaveExample: canSaveExample,
                            exampleHint: "Captures the input + variables as a generic test case.",
                            onSaved: { savedMessage = $0 },
                            schemaDef: model.useCustomSchema ? model.customSchema : nil,
                            liveConfig: model.config,
                            hooks: model.hooks)
                    }

                    if let msg = savedMessage {
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(16)
            }
            .frame(minWidth: 340, idealWidth: 380)

            // OUTPUT — the run as live pipeline stages.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Pipeline").font(.headline)
                        Spacer()
                        if let e = model.elapsed {
                            Text(String(format: "%.2f s", e))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    if model.stages.isEmpty {
                        Text("Run a prompt to trace the pipeline: variables → pre-hooks → final prompt → model output → post-hooks → final output.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(model.stages) { StageCard(stage: $0) }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 380)
        }
        .playgroundBackground()
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.footnote).fontWeight(.medium).foregroundStyle(.primary.opacity(0.6))
            content()
        }
    }

    private func variableRow(key: String, value: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text("{{\(key)}}")
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
            TextField("value", text: value).textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Hooks editor (left panel)

/// Two add/remove lists (pre + post) over a HookPipelineDef, mirroring SchemaEditorView's pattern.
struct HooksEditorView: View {
    @Binding var hooks: HookPipelineDef

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            hookList(title: "Pre-hooks · before the model", phase: .pre, list: $hooks.pre, defaultInput: "input")
            hookList(title: "Post-hooks · after the model", phase: .post, list: $hooks.post, defaultInput: "output")
        }
    }

    @ViewBuilder
    private func hookList(title: String, phase: HookPhase, list: Binding<[HookDef]>, defaultInput: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).fontWeight(.medium).foregroundStyle(.primary.opacity(0.6))
            ForEach(list) { $hook in
                HookRow(hook: $hook, phase: phase) { list.wrappedValue.removeAll { $0.id == hook.id } }
            }
            Menu {
                ForEach(HookOp.choices(for: phase), id: \.self) { op in
                    Button(op.displayName) { list.wrappedValue.append(HookDef(op: op, inputVar: defaultInput)) }
                }
            } label: { Label("Add \(phase == .pre ? "pre" : "post")-hook", systemImage: "plus.circle") }
                .font(.caption).menuStyle(.borderlessButton).fixedSize()
        }
    }
}

private struct HookRow: View {
    @Binding var hook: HookDef
    let phase: HookPhase
    let onDelete: () -> Void

    private var op: Binding<HookOp> {
        Binding(get: { hook.op }, set: { newOp in
            hook.opRaw = newOp.rawValue
            if hook.outputVar.isEmpty { hook.outputVar = newOp.defaultOutputVar }
        })
    }
    private func param(_ p: HookParam) -> Binding<String> {
        Binding(get: { hook.params[p.rawValue] ?? "" }, set: { hook.params[p.rawValue] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Toggle("", isOn: $hook.enabled).toggleStyle(.checkbox).labelsHidden()
                Picker("", selection: op) {
                    ForEach(HookOp.choices(for: phase), id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                portabilityBadge(hook.op.portability)
                Spacer()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            Text(hook.op.detail).font(.caption2).foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Text("in").font(.caption2).foregroundStyle(.tertiary)
                TextField("var", text: $hook.inputVar).textFieldStyle(.roundedBorder).frame(width: 84)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                Text("out").font(.caption2).foregroundStyle(.tertiary)
                TextField("var", text: $hook.outputVar).textFieldStyle(.roundedBorder).frame(width: 84)
            }
            .font(.system(.caption, design: .monospaced))

            ForEach(hook.op.paramKeys, id: \.self) { p in
                if p == .command {
                    VStack(alignment: .leading, spacing: 2) {
                        TextEditor(text: param(p))
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 56)
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .glassCard(radius: 6)
                        Text(p.placeholder).font(.caption2).foregroundStyle(.tertiary)
                    }
                } else {
                    HStack(spacing: 4) {
                        Text(p.label).font(.caption2).foregroundStyle(.tertiary).frame(width: 60, alignment: .leading)
                        TextField(p.placeholder, text: param(p)).textFieldStyle(.roundedBorder).font(.caption)
                    }
                }
            }
        }
        .opacity(hook.enabled ? 1 : 0.5)
        .padding(8)
        .glassCard(radius: 8)
    }

    private func portabilityBadge(_ p: Portability) -> some View {
        Text(p.label)
            .font(.caption2)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background((p.isPortable ? Theme.accent : Theme.gold).opacity(0.18), in: Capsule())
            .foregroundStyle(p.isPortable ? Theme.accent : Theme.gold)
    }
}

// MARK: - Pipeline stage card (right panel)

private struct StageCard: View {
    let stage: PlaygroundModel.PipelineStage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                statusGlyph
                Text(stage.title).font(.subheadline).fontWeight(.medium)
                Spacer()
                if let ms = stage.ms {
                    Text("\(ms) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let note = stage.note, !note.isEmpty {
                Text(note).font(.caption)
                    .foregroundStyle(stage.status == .error ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !stage.body.isEmpty {
                Text(stage.body)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .codeSurface()
            }
        }
        .padding(10)
        .glassCard(radius: 8, highlighted: stage.kind == .finalOutput)
    }

    @ViewBuilder private var statusGlyph: some View {
        switch stage.status {
        case .running: ProgressView().controlSize(.small)
        case .ok:      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .error:   Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
        }
    }
}
