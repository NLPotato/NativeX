import SwiftUI
import SwiftData

struct RoleplayView: View {
    @Environment(\.modelContext) private var context
    @State private var model = RoleplayModel()
    @State private var showingSave = false
    @State private var savedMessage: String?

    @Query(filter: #Predicate<PromptTemplateModel> { $0.taskRaw == "roleplay" }, sort: \.createdAt)
    private var templates: [PromptTemplateModel]
    @Query(filter: #Predicate<SchemaModel> { $0.taskRaw == "roleplay" }, sort: \.createdAt)
    private var savedSchemas: [SchemaModel]

    // Bridge to the pipeline store. The scene is the 5 fields; the live transcript's user turns
    // become the replay script so a hand-run scene re-runs the same way in batch eval.
    private var roleplayExampleLabel: String {
        let s = model.situation.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Role-play scene" : String(s.prefix(40))
    }
    private var roleplayExampleJSON: String {
        JSONCoder.encode(RoleplayInput(
            learning: model.learning, native: model.native, situation: model.situation,
            youRole: model.youRole, aiRole: model.aiRole,
            scriptedUserTurns: model.turns.compactMap(\.userText),
            maxTurns: max(model.turns.count, 4)))
    }
    private var roleplayHint: String {
        let scripted = model.turns.compactMap(\.userText).count
        if scripted > 0 {
            return "Captures the scene + your \(scripted) typed repl\(scripted == 1 ? "y" : "ies") as the replay script."
        }
        return "Captures the 5 scene fields. Run a few turns first to also capture your replies as a script."
    }

    var body: some View {
        @Bindable var model = model

        HSplitView {
            // SCENE SETUP
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
                        .disabled(model.hasStarted)
                    }

                    HStack(alignment: .top, spacing: 10) {
                        field("Learning language") {
                            TextField("e.g. Korean", text: $model.learning)
                                .textFieldStyle(.roundedBorder)
                                .disabled(model.hasStarted)
                        }
                        field("Native language") {
                            TextField("e.g. English", text: $model.native)
                                .textFieldStyle(.roundedBorder)
                                .disabled(model.hasStarted)
                        }
                    }

                    field("Situation") {
                        TextField("The scene / setting", text: $model.situation, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)
                            .disabled(model.hasStarted)
                    }

                    HStack(alignment: .top, spacing: 10) {
                        field("Your role") {
                            TextField("Who you play", text: $model.youRole)
                                .textFieldStyle(.roundedBorder)
                                .disabled(model.hasStarted)
                        }
                        field("AI's role") {
                            TextField("Who the AI plays", text: $model.aiRole)
                                .textFieldStyle(.roundedBorder)
                                .disabled(model.hasStarted)
                        }
                    }

                    field("Instructions") {
                        TextEditor(text: $model.instructions)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 150)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                            .disabled(model.hasStarted)
                        Text("Placeholders: {{learning}} {{native}} {{situation}} {{you}} {{ai}} — resolved at Start.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    DisclosureGroup("Generation config") {
                        GenConfigControls(config: $model.config).padding(.top, 4).disabled(model.hasStarted)
                    }
                    .font(.callout)

                    DisclosureGroup("Output schema") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Use a custom schema (run dynamically)", isOn: $model.useCustomSchema)
                                .disabled(model.hasStarted)
                            if model.useCustomSchema {
                                if !savedSchemas.isEmpty {
                                    Menu {
                                        ForEach(savedSchemas) { s in
                                            Button("\(s.name) v\(s.version)") { if let d = s.def { model.customSchema = d } }
                                        }
                                    } label: { Label("Load saved schema", systemImage: "tray.and.arrow.up") }
                                    .font(.caption).fixedSize().disabled(model.hasStarted)
                                }
                                SchemaEditorView(def: $model.customSchema).disabled(model.hasStarted)
                                Text("Custom turns show raw JSON (no tappable suggestions). Save + export Swift from “Save to Lab…”.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text("Using the typed RoleplayTurnGen (tappable suggestions + typed metrics).")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 4)
                    }
                    .font(.callout)

                    if model.hasStarted {
                        Button(role: .destructive) {
                            model.reset()
                        } label: {
                            Text("Reset scene").frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .disabled(model.isRunning)
                    } else {
                        Button {
                            Task { await model.start() }
                        } label: {
                            HStack(spacing: 6) {
                                if model.isRunning { ProgressView().controlSize(.small) }
                                Text(model.isRunning ? "Starting…" : "Start")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.isRunning || !model.isModelAvailable || !model.canStart)
                    }

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
                            task: .roleplay,
                            promptInstructions: model.instructions,
                            defaultTemplateName: "Role-play (playground)",
                            defaultExampleLabel: roleplayExampleLabel,
                            exampleInputJSON: roleplayExampleJSON,
                            canSaveExample: model.canStart,
                            exampleHint: roleplayHint,
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

            // CONVERSATION + COMPOSER
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if model.turns.isEmpty {
                                Text(model.hasStarted
                                     ? "Starting the scene…"
                                     : "Fill in the scene and press Start. The character speaks first.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            ForEach(model.turns) { turn in
                                turnView(turn).id(turn.id)
                            }

                            if let err = model.errorText {
                                Text(err)
                                    .font(.callout)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: model.turns.count) { _, _ in
                        if let last = model.turns.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                Divider()

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Your reply…", text: $model.replyText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                        .disabled(!model.hasStarted || model.isRunning)
                    Button {
                        Task { await model.send() }
                    } label: {
                        if model.isRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Send")
                        }
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!model.hasStarted || model.isRunning
                              || model.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(12)
            }
            .frame(minWidth: 360)
        }
        .playgroundBackground()
    }

    /// One dialogue turn: optional user line, the character's reply + translation, the two
    /// tappable suggestions, timing, and the raw JSON (collapsed) for schema verification.
    @ViewBuilder
    private func turnView(_ turn: Turn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let user = turn.userText {
                Text(user)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(10)
                    .glassCard(highlighted: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if let result = turn.result {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.reply.text)
                        .font(.body)
                        .textSelection(.enabled)
                    Text(result.reply.translation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .glassCard()

                ForEach(Array(result.suggestions.enumerated()), id: \.offset) { _, s in
                    Button {
                        Task { await model.send(suggestion: s.text) }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.text).font(.callout).fontWeight(.medium)
                            Text(s.translation).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isRunning)
                }
            } else {
                // Custom-schema turn: no typed reply/suggestions — show the raw JSON.
                Text(turn.raw)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .codeSurface()
            }

            HStack {
                Spacer()
                Text(String(format: "%.2f s", turn.elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if turn.result != nil {
                DisclosureGroup("Raw JSON") {
                    Text(turn.raw)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .codeSurface()
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}
