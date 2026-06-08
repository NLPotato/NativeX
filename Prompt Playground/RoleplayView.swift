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
                VStack(alignment: .leading, spacing: DS.Layout.groupGap) {
                    if let msg = model.availabilityMessage {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .font(.dsBody)
                            .foregroundStyle(.dsWarning)
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

                    DSSectionHeader("Scene")

                    VStack(alignment: .leading, spacing: DS.Layout.fieldGap) {
                        HStack(alignment: .top, spacing: DS.Space.md) {
                            DSField(label: "Learning language") {
                                TextField("e.g. Korean", text: $model.learning)
                                    .dsTextField()
                                    .disabled(model.hasStarted)
                            }
                            DSField(label: "Native language") {
                                TextField("e.g. English", text: $model.native)
                                    .dsTextField()
                                    .disabled(model.hasStarted)
                            }
                        }

                        DSField(label: "Situation") {
                            TextField("The scene / setting", text: $model.situation, axis: .vertical)
                                .dsTextField()
                                .lineLimit(1...4)
                                .disabled(model.hasStarted)
                        }

                        HStack(alignment: .top, spacing: DS.Space.md) {
                            DSField(label: "Your role") {
                                TextField("Who you play", text: $model.youRole)
                                    .dsTextField()
                                    .disabled(model.hasStarted)
                            }
                            DSField(label: "AI's role") {
                                TextField("Who the AI plays", text: $model.aiRole)
                                    .dsTextField()
                                    .disabled(model.hasStarted)
                            }
                        }

                        DSField(label: "Instructions",
                                help: "Placeholders: {{learning}} {{native}} {{situation}} {{you}} {{ai}} — resolved at Start.") {
                            TextEditor(text: $model.instructions)
                                .font(.dsCode)
                                .dsEditor(lines: 7)
                                .disabled(model.hasStarted)
                        }
                    }

                    DisclosureGroup("Generation config") {
                        GenConfigControls(config: $model.config).padding(.top, DS.Space.xs).disabled(model.hasStarted)
                    }
                    .font(.dsBody)

                    DisclosureGroup("Output schema") {
                        VStack(alignment: .leading, spacing: DS.Space.sm) {
                            Toggle("Use a custom schema (run dynamically)", isOn: $model.useCustomSchema)
                                .disabled(model.hasStarted)
                            if model.useCustomSchema {
                                if !savedSchemas.isEmpty {
                                    Menu {
                                        ForEach(savedSchemas) { s in
                                            Button("\(s.name) v\(s.version)") { if let d = s.def { model.customSchema = d } }
                                        }
                                    } label: { Label("Load saved schema", systemImage: "tray.and.arrow.up") }
                                    .font(.dsCaption).fixedSize().disabled(model.hasStarted)
                                }
                                SchemaEditorView(def: $model.customSchema).disabled(model.hasStarted)
                                Text("Custom turns show raw JSON (no tappable suggestions). Save + export Swift from “Save to Lab…”.")
                                    .font(.dsMicro).foregroundStyle(.secondary)
                            } else {
                                Text("Using the typed RoleplayTurnGen (tappable suggestions + typed metrics).")
                                    .font(.dsCaption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, DS.Space.xs)
                    }
                    .font(.dsBody)

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
                            HStack(spacing: DS.Space.sm) {
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
                            .font(.dsCaption).foregroundStyle(.dsSuccess)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(DS.Layout.paneInset)
            }
            .frame(minWidth: DS.Size.panelMinWidth, idealWidth: DS.Size.panelIdealWidth)

            // CONVERSATION + COMPOSER
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Layout.groupGap) {
                            DSSectionHeader("Output")

                            if model.turns.isEmpty {
                                Text(model.hasStarted
                                     ? "Starting the scene…"
                                     : "Fill in the scene and press Start. The character speaks first.")
                                    .font(.dsBody)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            ForEach(model.turns) { turn in
                                turnView(turn).id(turn.id)
                            }

                            if let err = model.errorText {
                                Text(err)
                                    .font(.dsBody)
                                    .foregroundStyle(.dsDanger)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(DS.Layout.paneInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: model.turns.count) { _, _ in
                        if let last = model.turns.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                Divider()

                HStack(alignment: .bottom, spacing: DS.Space.sm) {
                    TextField("Your reply…", text: $model.replyText, axis: .vertical)
                        .dsTextField()
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
                .padding(DS.Layout.fieldGap)
            }
            .frame(minWidth: DS.Size.panelMinWidth)
        }
        .playgroundBackground()
    }

    /// One dialogue turn: optional user line, the character's reply + translation, the two
    /// tappable suggestions, timing, and the raw JSON (collapsed) for schema verification.
    @ViewBuilder
    private func turnView(_ turn: Turn) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            if let user = turn.userText {
                Text(user)
                    .font(.dsBody)
                    .textSelection(.enabled)
                    .dsCard(raised: true)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if let result = turn.result {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(result.reply.text)
                        .font(.dsBody)
                        .textSelection(.enabled)
                    Text(result.reply.translation)
                        .font(.dsBody)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsCard()

                ForEach(Array(result.suggestions.enumerated()), id: \.offset) { _, s in
                    Button {
                        Task { await model.send(suggestion: s.text) }
                    } label: {
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            Text(s.text).font(.dsBody).fontWeight(.medium)
                            Text(s.translation).font(.dsCaption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isRunning)
                }
            } else {
                // Custom-schema turn: no typed reply/suggestions — show the raw JSON.
                Text(turn.raw)
                    .font(.dsCode)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsFlat()
            }

            HStack {
                Spacer()
                Text(String(format: "%.2f s", turn.elapsed))
                    .font(.dsMicro.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if turn.result != nil {
                DisclosureGroup("Raw JSON") {
                    Text(turn.raw)
                        .font(.dsCode)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dsFlat()
                }
                .font(.dsCaption)
            }
        }
    }
}
