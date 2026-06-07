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
            PipelineView()
                .tabItem { Label("Pipeline", systemImage: "chart.bar.doc.horizontal") }
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

    @Query(filter: #Predicate<PromptTemplateModel> { $0.taskRaw == "gloss" }, sort: \.createdAt)
    private var templates: [PromptTemplateModel]
    @Query(filter: #Predicate<SchemaModel> { $0.taskRaw == "gloss" }, sort: \.createdAt)
    private var savedSchemas: [SchemaModel]

    // Bridge to the pipeline store. Canonicalize the legacy {{source}}/{{target}} placeholders to
    // {{learning}}/{{native}} so new pipeline templates follow the documented convention (the
    // runner resolves both identically, so this is a meaning-preserving rename).
    private var canonicalGlossPrompt: String {
        model.instructions
            .replacingOccurrences(of: "{{source}}", with: "{{learning}}")
            .replacingOccurrences(of: "{{target}}", with: "{{native}}")
    }
    private var glossExampleLabel: String {
        let s = model.sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Gloss example" : String(s.prefix(40))
    }
    private var glossExampleJSON: String {
        // Source field = the sentence's language (learning); Target field = where translations land (native).
        JSONCoder.encode(GlossInput(sentence: model.sentence, learning: model.source, native: model.target))
    }
    private var glossCanSaveExample: Bool {
        ![model.sentence, model.source, model.target].contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
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
                                Button("\(t.name) v\(t.version)") { model.instructions = t.instructions }
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

                    field("Sentence") {
                        TextField("Sentence to analyze", text: $model.sentence, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                    }

                    HStack(alignment: .top, spacing: 10) {
                        field("Source language") {
                            TextField("e.g. German", text: $model.source)
                                .textFieldStyle(.roundedBorder)
                        }
                        field("Target language") {
                            TextField("e.g. English", text: $model.target)
                                .textFieldStyle(.roundedBorder)
                        }
                    }

                    field("Instructions") {
                        TextEditor(text: $model.instructions)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 150)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        Text("Use {{source}} and {{target}} as placeholders.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    DisclosureGroup("Generation config") {
                        GenConfigControls(config: $model.config).padding(.top, 4)
                    }
                    .font(.callout)

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
                                Text("Runs via DynamicGenerationSchema. Save it + export Swift from “Save to pipeline…”.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text("Using the typed @Generable from the selected preset.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)

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
                        Label("Save to pipeline…", systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .disabled(model.isRunning)
                    .sheet(isPresented: $showingSave) {
                        SaveToPipelineSheet(
                            task: .gloss,
                            promptInstructions: canonicalGlossPrompt,
                            defaultTemplateName: "Gloss (playground)",
                            defaultExampleLabel: glossExampleLabel,
                            exampleInputJSON: glossExampleJSON,
                            canSaveExample: glossCanSaveExample,
                            exampleHint: "Captures the sentence + its languages as a gloss test case.",
                            onSaved: { savedMessage = $0 },
                            schemaDef: model.useCustomSchema ? model.customSchema : nil,
                            liveConfig: model.config)
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

            // OUTPUT
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !model.resolvedInstructions.isEmpty || !model.userPrompt.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Final prompt").font(.headline)
                            outputBlock("Instructions (resolved)", model.resolvedInstructions)
                            outputBlock("Prompt", model.userPrompt)
                            Text("The schema is also auto-injected (includeSchemaInPrompt: true).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Structured output").font(.headline)
                            Spacer()
                            if let e = model.elapsed {
                                Text(String(format: "%.2f s", e))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if model.useCustomSchema && (!model.output.isEmpty || model.errorText != nil) {
                            Label(model.errorText == nil ? "Conforms to schema" : "Did not conform",
                                  systemImage: model.errorText == nil ? "checkmark.seal.fill" : "xmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(model.errorText == nil ? .green : .red)
                        }
                        Text(model.useCustomSchema
                             ? "JSON of the GeneratedContent — structure is guaranteed by the schema."
                             : "JSON of the generated @Generable — compare field-by-field against the struct.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let err = model.errorText {
                            Text(err)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text(model.output.isEmpty ? "Run a prompt to see the response." : model.output)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(model.output.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .codeSurface()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 360)
        }
        .playgroundBackground()
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func outputBlock(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(text.isEmpty ? "—" : text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .codeSurface()
        }
    }
}
