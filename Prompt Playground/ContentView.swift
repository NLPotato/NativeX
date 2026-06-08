import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var context

    var body: some View {
        TabView {
            GlossView()
                .tabItem { Label("Single-shot", systemImage: "bolt") }
            ChatView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
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

struct GlossView: View {
    @Environment(\.modelContext) private var context
    @State private var model = PlaygroundModel()
    @State private var showingSave = false
    @State private var savedMessage: String?
    @State private var showingSchemaSheet = false
    @State private var showingHooksSheet = false

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
                VStack(alignment: .leading, spacing: DS.Space.xl) {
                    if let msg = model.availabilityMessage {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .font(.dsBody)
                            .foregroundStyle(.dsWarning)
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

                    sectionHeader("Prompt")

                    field("Prompt", help: "Sent to the model — also the {{prompt}} variable.") {
                        TextField("Type the prompt…", text: $model.input, axis: .vertical)
                            .font(.dsBody)
                            .lineLimit(2...6)
                            .dsEditor(lines: 2)
                    }

                    field("Instructions", help: "The system prompt. Reference variables with {{name}}.") {
                        TextEditor(text: $model.instructions)
                            .font(.dsCode)
                            .dsEditor(lines: 10)
                    }

                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        Text("Variables").font(.dsLabel).foregroundStyle(.secondary)
                        VStack(spacing: DS.Space.md) {
                            if model.variableKeys.isEmpty && model.hookOutputs.isEmpty && model.malformedTokens.isEmpty {
                                Text("No variables. Add a {{name}} token in Instructions or Prompt.")
                                    .font(.dsCaption).foregroundStyle(.secondary)
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
                                    .font(.dsCaption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if model.usesPromptToken {
                                Label("Provided by the Prompt field: {{prompt}}", systemImage: "text.cursor")
                                    .font(.dsCaption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !model.malformedTokens.isEmpty {
                                Label("Unrecognized: \(model.malformedTokens.joined(separator: ", ")). Use letters, digits, or _ inside {{ }}.",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.dsCaption).foregroundStyle(.dsWarning)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if !model.unusedHookOutputs.isEmpty {
                                Label("Hook output unused: \(model.unusedHookOutputs.map { "{{\($0)}}" }.joined(separator: ", ")). Nothing reads it — check the hook's “out” name matches a {{token}} in your prompt.",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.dsCaption).foregroundStyle(.dsWarning)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .dsCard()
                    }

                    sectionHeader("Pipeline · optional")

                    DisclosureGroup("Generation config") {
                        GenConfigControls(config: $model.config).padding(.top, DS.Space.xs)
                    }
                    .font(.dsHeading)

                    DisclosureGroup("Guided Generation") {
                        VStack(alignment: .leading, spacing: DS.Space.sm) {
                            Text("Guided Generation constrains the model to a fixed output schema (structured output) via constrained decoding.")
                                .font(.dsCaption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Toggle("Use a custom output schema", isOn: $model.useCustomSchema)
                            if model.useCustomSchema {
                                schemaSummary
                                HStack(spacing: DS.Space.sm) {
                                    Button { showingSchemaSheet = true } label: {
                                        Label("Edit schema…", systemImage: "curlybraces.square")
                                    }
                                    Button("New") { model.customSchema = .blank }
                                    if !savedSchemas.isEmpty {
                                        Menu("Load") {
                                            ForEach(savedSchemas) { s in
                                                Button("\(s.name) v\(s.version)") { if let d = s.def { model.customSchema = d } }
                                            }
                                        }
                                        .fixedSize()
                                    }
                                }
                                .font(.dsBody)
                                Text("Runs via DynamicGenerationSchema. Save it + export Swift from “Save to Lab…”.")
                                    .font(.dsCaption).foregroundStyle(.secondary)
                            } else {
                                Text("No schema — the model returns free-form text.")
                                    .font(.dsCaption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, DS.Space.xs)
                    }
                    .font(.dsHeading)
                    .sheet(isPresented: $showingSchemaSheet) {
                        SchemaEditorSheet(def: $model.customSchema, isPresented: $showingSchemaSheet)
                    }

                    DisclosureGroup("Hooks") {
                        VStack(alignment: .leading, spacing: DS.Space.sm) {
                            Text("Deterministic native ops or shell scripts run before/after the model. A pre-hook’s output becomes a {{variable}} you can use in the prompt.")
                                .font(.dsCaption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            hooksSummary
                            Button { showingHooksSheet = true } label: {
                                Label("Edit hooks…", systemImage: "slider.horizontal.3")
                            }
                            .font(.dsBody)
                        }
                        .padding(.top, DS.Space.xs)
                    }
                    .font(.dsHeading)
                    .sheet(isPresented: $showingHooksSheet) {
                        HooksEditorSheet(hooks: $model.hooks,
                                         unusedOutputs: Set(model.unusedHookOutputs),
                                         isPresented: $showingHooksSheet)
                    }

                    Button {
                        Task { await model.run() }
                    } label: {
                        HStack(spacing: DS.Space.sm) {
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
                            exampleHint: "Captures the prompt + variables as a generic test case.",
                            onSaved: { savedMessage = $0 },
                            schemaDef: model.useCustomSchema ? model.customSchema : nil,
                            liveConfig: model.config,
                            hooks: model.hooks)
                    }

                    if let msg = savedMessage {
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .font(.dsCaption).foregroundStyle(.dsSuccess)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(DS.Space.xl)
            }
            .frame(minWidth: DS.Size.panelMinWidth, idealWidth: DS.Size.panelIdealWidth)

            // OUTPUT — the run as live pipeline stages.
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    HStack {
                        Text("Pipeline").font(.dsTitle)
                        Spacer()
                        if let e = model.elapsed {
                            Text(String(format: "%.2f s", e))
                                .font(.dsCaption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    if model.stages.isEmpty {
                        VStack(alignment: .leading, spacing: DS.Space.sm) {
                            Text("A single-shot Foundation Models runner: author a prompt with optional hooks and Guided Generation, run it, and trace the whole pipeline here. The selected example demonstrates both — pick “Blank (start here)” for your own.")
                            Text("Run a prompt to trace the pipeline: variables → pre-hooks → final prompt → model output → post-hooks → final output.")
                                .foregroundStyle(.tertiary)
                        }
                        .font(.dsBody).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(model.stages) { StageCard(stage: $0) }
                }
                .padding(DS.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: DS.Size.panelMinWidth)
        }
        .playgroundBackground()
        .runningRadiance(active: model.isRunning)   // neon-green edge glow while a run is in flight
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, help: String? = nil,
                                      @ViewBuilder _ content: @escaping () -> Content) -> some View {
        DSField(label: label, help: help, control: content)
    }

    /// A left-panel group divider so the required prompt block reads apart from optional pipeline steps.
    private func sectionHeader(_ title: String) -> some View { DSSectionHeader(title) }

    /// Compact read-only stand-in for the schema editor (now a sheet) — type name + field count.
    private var schemaSummary: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "curlybraces").foregroundStyle(.dsAccent)
            Text(model.customSchema.typeName.isEmpty ? "Output" : model.customSchema.typeName)
                .font(.dsLabel)
            let n = model.customSchema.fields.count
            Text("· \(n) field\(n == 1 ? "" : "s")").foregroundStyle(.secondary)
        }
        .font(.dsBody)
        .padding(.vertical, DS.Space.sm).padding(.horizontal, DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
    }

    /// Compact read-only stand-in for the hooks editor (now a sheet) — counts + the unused-output ⚠︎
    /// so the mis-wiring signal stays visible even while the editor is collapsed into the sheet.
    private var hooksSummary: some View {
        let pre = model.hooks.pre.count
        let post = model.hooks.post.count
        return HStack(spacing: DS.Space.sm) {
            Image(systemName: "wand.and.stars").foregroundStyle(.dsAccent)
            Text(pre + post == 0 ? "No hooks yet" : "\(pre) pre · \(post) post")
                .font(.dsLabel)
            if !model.unusedHookOutputs.isEmpty {
                Spacer()
                Label("unused output", systemImage: "exclamationmark.triangle.fill")
                    .font(.dsCaption).foregroundStyle(.dsWarning)
            }
        }
        .font(.dsBody)
        .padding(.vertical, DS.Space.sm).padding(.horizontal, DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
    }

    private func variableRow(key: String, value: Binding<String>) -> some View {
        HStack(spacing: DS.Space.sm) {
            Text("{{\(key)}}")
                .font(.dsCode)
                .foregroundStyle(.dsAccent)
                .padding(.horizontal, DS.Space.xs).padding(.vertical, DS.Space.xxs)
                .background(Color.dsAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            Image(systemName: "arrow.right").font(.dsMicro).foregroundStyle(.tertiary)
            TextField("value", text: value).dsTextField()
        }
    }
}

// MARK: - Hooks editor (left panel)

/// Two add/remove lists (pre + post) over a HookPipelineDef, mirroring SchemaEditorView's pattern.
struct HooksEditorView: View {
    @Binding var hooks: HookPipelineDef
    var unusedOutputs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            hookList(title: "Pre-hooks · before the model", phase: .pre, list: $hooks.pre, defaultInput: "prompt")
            hookList(title: "Post-hooks · after the model", phase: .post, list: $hooks.post, defaultInput: "output")
        }
    }

    @ViewBuilder
    private func hookList(title: String, phase: HookPhase, list: Binding<[HookDef]>, defaultInput: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(title).font(.dsLabel).foregroundStyle(.secondary)
            ForEach(list) { $hook in
                HookRow(hook: $hook, phase: phase, unusedOutputs: unusedOutputs) { list.wrappedValue.removeAll { $0.id == hook.id } }
            }
            Menu {
                ForEach(HookOp.choices(for: phase), id: \.self) { op in
                    Button(op.displayName + op.phaseTag) { list.wrappedValue.append(HookDef(op: op, inputVar: defaultInput)) }
                }
            } label: { Label("Add \(phase == .pre ? "pre" : "post")-hook", systemImage: "plus.circle") }
                .font(.dsCaption).menuStyle(.borderlessButton).fixedSize()
        }
    }
}

/// Hosts the hooks editor in a focused sheet — same rationale as SchemaEditorSheet: keep the heavy
/// pre/post editor out of the left column so it reads as a compact summary there.
struct HooksEditorSheet: View {
    @Binding var hooks: HookPipelineDef
    var unusedOutputs: Set<String> = []
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Hooks").font(.dsTitle)
                Spacer()
                Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction)
            }
            .padding(DS.Space.lg)
            Divider()
            ScrollView {
                HooksEditorView(hooks: $hooks, unusedOutputs: unusedOutputs).padding(DS.Space.xl)
            }
        }
        .frame(minWidth: DS.Size.sheetMinWidth, idealWidth: DS.Size.sheetIdealWidth, minHeight: 480, idealHeight: 640)
        .playgroundBackground()
    }
}

private struct HookRow: View {
    @Binding var hook: HookDef
    let phase: HookPhase
    var unusedOutputs: Set<String> = []
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

    /// A pre-hook's output var is consumed by no {{token}} — the in-row signal of the typo that the
    /// Variables-card "unused" warning also reports. Post-hook outputs are terminal, so no signal.
    private var outVarUnused: Bool {
        phase == .pre && !hook.outputVar.isEmpty && unusedOutputs.contains(hook.outputVar)
    }
    /// Accent when the out var is consumed, gold when nothing reads it; nil for post / empty.
    private var outVarColor: Color? {
        guard phase == .pre, !hook.outputVar.isEmpty else { return nil }
        return outVarUnused ? Color.dsWarning : Color.dsAccent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.sm) {
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
            Text(hook.op.detail).font(.dsCaption).foregroundStyle(.secondary)

            HStack(alignment: .bottom, spacing: DS.Space.sm) {
                DSField(label: "in") {
                    TextField("var", text: $hook.inputVar)
                        .dsTextField().frame(width: DS.Size.fieldMiniWidth)
                }
                Image(systemName: "arrow.right").font(.dsCaption).foregroundStyle(.tertiary)
                    .padding(.bottom, DS.Space.sm)
                DSField(label: "out") {
                    TextField("var", text: $hook.outputVar)
                        .dsTextField().frame(width: DS.Size.fieldMiniWidth)
                        .overlay {
                            if let c = outVarColor {
                                RoundedRectangle(cornerRadius: DS.Radius.sm).stroke(c, lineWidth: 1)
                            }
                        }
                }
                if outVarUnused {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.dsMicro).foregroundStyle(.dsWarning)
                        .padding(.bottom, DS.Space.sm)
                }
            }

            ForEach(hook.op.paramKeys, id: \.self) { p in
                if p == .command {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        TextEditor(text: param(p))
                            .font(.dsCode)
                            .dsEditor(lines: 3)
                        Text(p.placeholder).font(.dsCaption).foregroundStyle(.tertiary)
                    }
                } else {
                    DSField(label: p.label) {
                        TextField(p.placeholder, text: param(p)).dsTextField()
                    }
                }
            }
        }
        .opacity(hook.enabled ? 1 : 0.5)
        .dsCard()
    }

    private func portabilityBadge(_ p: Portability) -> some View {
        Text(p.label)
            .font(.dsMicro)
            .padding(.horizontal, DS.Space.xs).padding(.vertical, DS.Space.xxs)
            .background((p.isPortable ? Color.dsAccent : Color.dsWarning).opacity(0.18), in: Capsule())
            .foregroundStyle(p.isPortable ? Color.dsAccent : Color.dsWarning)
    }
}

// MARK: - Pipeline stage card (right panel)

struct StageCard: View {
    let stage: PlaygroundModel.PipelineStage

    var body: some View {
        StageCardView(title: stage.title, status: status, text: stage.body,
                      ms: stage.ms, note: stage.note, raised: stage.kind == .finalOutput)
    }

    private var status: StageCardView.Status {
        switch stage.status {
        case .running: return .running
        case .ok:      return .ok
        case .error:   return .error
        }
    }
}
