//
//  ChatView.swift
//  Prompt Playground
//
//  The Chat tab — a LangSmith-style chat playground over Apple Foundation Models. Two columns:
//  LEFT authors the conversation as editable, role-labeled message blocks (SYSTEM / HUMAN / AI)
//  plus the pipeline controls; RIGHT shows the detected Inputs (top) and the latest turn's staged
//  trace as Output (bottom). "Start" generates the next AI turn. Drives `ChatModel`.
//

import SwiftUI
import SwiftData

struct ChatView: View {
    @Environment(\.modelContext) private var context
    @State private var model = ChatModel()
    @State private var showingSave = false
    @State private var savedMessage: String?
    @State private var showingSchemaSheet = false
    @State private var showingHooksSheet = false

    @Query(filter: #Predicate<PromptTemplateModel> { $0.taskRaw == "generic" || $0.taskRaw == "roleplay" }, sort: \.createdAt)
    private var templates: [PromptTemplateModel]
    @Query(filter: #Predicate<SchemaModel> { $0.taskRaw == "generic" || $0.taskRaw == "roleplay" }, sort: \.createdAt)
    private var savedSchemas: [SchemaModel]

    // MARK: Save-to-Lab bridging (role-play preset → RoleplayInput; generic → GenericInput)

    private var isRoleplay: Bool { model.preset.useTypedRoleplay }
    private var saveTask: TaskKind { isRoleplay ? .roleplay : .generic }
    private var sceneFields: [String] { ["learning", "native", "situation", "you", "ai"].map { model.inputs[$0] ?? "" } }

    private var exampleJSON: String {
        if isRoleplay {
            return JSONCoder.encode(RoleplayInput(
                learning: model.inputs["learning"] ?? "", native: model.inputs["native"] ?? "",
                situation: model.inputs["situation"] ?? "", youRole: model.inputs["you"] ?? "",
                aiRole: model.inputs["ai"] ?? "",
                scriptedUserTurns: model.userTurns,
                maxTurns: max(model.messages.filter { $0.role == .ai }.count, 4)))
        }
        return JSONCoder.encode(GenericInput(input: model.userTurns.last ?? "", variables: model.inputs))
    }
    private var canSaveExample: Bool {
        isRoleplay ? !sceneFields.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                   : !(model.userTurns.last ?? "").isEmpty
    }
    private var exampleLabel: String {
        let basis = isRoleplay ? (model.inputs["situation"] ?? "") : (model.userTurns.last ?? "")
        let s = basis.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "Chat scene" : String(s.prefix(40))
    }
    private var exampleHint: String {
        if isRoleplay {
            let n = model.userTurns.count
            return n > 0 ? "Captures the scene + your \(n) authored turn\(n == 1 ? "" : "s") as the replay script."
                         : "Captures the 5 scene fields. Author a few user turns to also capture them as a script."
        }
        return "Captures the system prompt + your \(model.userTurns.count) authored user turn(s). Generic multi-turn Lab replay is in progress."
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            topBar
            Divider()
            HSplitView {
                messagesPane(model: model)
                    .frame(minWidth: DS.Size.panelMinWidth, idealWidth: DS.Size.panelIdealWidth)
                rightPane
                    .frame(minWidth: DS.Size.panelMinWidth)
            }
        }
        .playgroundBackground()
        .runningRadiance(active: model.isRunning)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: DS.Space.md) {
            Text("Chat").font(.dsTitle)
            Spacer()
            Button(role: .destructive) { model.reset() } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .disabled(model.isRunning)

            Button {
                savedMessage = nil
                showingSave = true
            } label: { Label("Save to Lab…", systemImage: "tray.and.arrow.down") }
            .disabled(model.isRunning)
            .sheet(isPresented: $showingSave) {
                SaveToPipelineSheet(
                    task: saveTask,
                    promptInstructions: model.systemInstructions,
                    defaultTemplateName: isRoleplay ? "Role-play (chat)" : "Chat prompt",
                    defaultExampleLabel: exampleLabel,
                    exampleInputJSON: exampleJSON,
                    canSaveExample: canSaveExample,
                    exampleHint: exampleHint,
                    onSaved: { savedMessage = $0 },
                    schemaDef: model.useCustomSchema ? model.customSchema : nil,
                    liveConfig: model.config,
                    hooks: model.hooks)
            }

            Button {
                Task { await model.start() }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    if model.isRunning { ProgressView().controlSize(.small) }
                    else { Image(systemName: "play.fill") }
                    Text(model.isRunning ? "Running…" : "Start")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canStart)
        }
        .padding(DS.Space.lg)
    }

    // MARK: Left — Messages

    private func messagesPane(model: ChatModel) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Layout.groupGap) {
                    if let msg = model.availabilityMessage {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .font(.dsBody).foregroundStyle(.dsWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: DS.Space.md) {
                        Picker("Preset", selection: Binding(get: { model.presetID }, set: { model.loadPreset($0) })) {
                            ForEach(chatPresets) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().fixedSize()
                        .disabled(model.isRunning)

                        if !templates.isEmpty {
                            Menu {
                                ForEach(templates) { t in
                                    Button("\(t.name) v\(t.version)") {
                                        model.setSystemInstructions(t.instructions)
                                        model.hooks = t.hooks
                                        model.config = t.genConfig
                                    }
                                }
                            } label: { Label("Load prompt", systemImage: "square.and.arrow.down.on.square") }
                            .menuStyle(.borderlessButton).fixedSize().disabled(model.isRunning)
                        }
                    }

                    DSSectionHeader("Messages")

                    ForEach($model.messages) { $message in
                        MessageBlockView(message: $message, model: model).id(message.id)
                    }

                    HStack(spacing: DS.Space.sm) {
                        Button { model.addMessage() } label: { Label("Message", systemImage: "plus.circle") }
                            .disabled(model.isRunning)
                    }
                    .font(.dsBody)

                    schemaDisclosure(model: model)
                    hooksDisclosure(model: model)

                    DisclosureGroup("Generation config") {
                        GenConfigControls(config: $model.config).padding(.top, DS.Space.xs)
                    }
                    .font(.dsHeading)

                    if let msg = savedMessage {
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .font(.dsCaption).foregroundStyle(.dsSuccess)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(DS.Layout.paneInset)
            }
            .onChange(of: model.messages.count) { _, _ in
                if let last = model.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder
    private func schemaDisclosure(model: ChatModel) -> some View {
        DisclosureGroup("Output schema") {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Toggle("Use a custom output schema (Guided Generation)", isOn: $model.useCustomSchema)
                    .disabled(model.isRunning)
                if model.useCustomSchema {
                    HStack(spacing: DS.Space.sm) {
                        Button { showingSchemaSheet = true } label: { Label("Edit schema…", systemImage: "curlybraces.square") }
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
                    .font(.dsBody).disabled(model.isRunning)
                    Text("Replies are raw JSON (no tappable suggestions). Save + export Swift from “Save to Lab…”.")
                        .font(.dsCaption).foregroundStyle(.secondary)
                } else if model.preset.useTypedRoleplay {
                    Text("Using the typed RoleplayTurnGen (tappable suggestions + translations).")
                        .font(.dsCaption).foregroundStyle(.secondary)
                } else {
                    Text("No schema — plain-text replies.")
                        .font(.dsCaption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, DS.Space.xs)
        }
        .font(.dsHeading)
        .sheet(isPresented: $showingSchemaSheet) {
            SchemaEditorSheet(def: $model.customSchema, isPresented: $showingSchemaSheet)
        }
    }

    @ViewBuilder
    private func hooksDisclosure(model: ChatModel) -> some View {
        DisclosureGroup("Hooks") {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text("Deterministic native ops or shell scripts run before/after each turn. A pre-hook’s output becomes a {{variable}} you can use in any message.")
                    .font(.dsCaption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "wand.and.stars").foregroundStyle(.dsAccent)
                    let pre = model.hooks.pre.count, post = model.hooks.post.count
                    Text(pre + post == 0 ? "No hooks yet" : "\(pre) pre · \(post) post").font(.dsLabel)
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
                Button { showingHooksSheet = true } label: { Label("Edit hooks…", systemImage: "slider.horizontal.3") }
                    .font(.dsBody)
            }
            .padding(.top, DS.Space.xs)
        }
        .font(.dsHeading)
        .sheet(isPresented: $showingHooksSheet) {
            HooksEditorSheet(hooks: $model.hooks, unusedOutputs: Set(model.unusedHookOutputs), isPresented: $showingHooksSheet)
        }
    }

    // MARK: Right — Inputs (top) + Output (bottom)

    private var rightPane: some View {
        VSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    DSSectionHeader("Inputs")
                    inputsCard
                }
                .padding(DS.Layout.paneInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    HStack {
                        DSSectionHeader("Output")
                        Spacer()
                        if let e = latestAI?.elapsed {
                            Text(String(format: "%.2f s", e)).font(.dsCaption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    if let ai = latestAI, !ai.trace.isEmpty {
                        ForEach(ai.trace) { StageCard(stage: $0) }
                        if let err = ai.errorText {
                            Text(err).font(.dsBody).foregroundStyle(.dsDanger).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("⌘↩ or click Start to generate the next assistant turn. The pipeline trace (variables → hooks → final prompt → model → post-hooks) shows here.")
                            .font(.dsBody).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(DS.Layout.paneInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var latestAI: ChatMessage? { model.messages.last { $0.role == .ai } }

    private var inputsCard: some View {
        VStack(spacing: DS.Space.md) {
            if model.inputKeys.isEmpty && model.hookOutputs.isEmpty && model.malformedTokens.isEmpty {
                Text("No variables. Add a {{name}} token in any message.")
                    .font(.dsCaption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(model.inputKeys, id: \.self) { key in
                HStack(spacing: DS.Space.sm) {
                    Text("{{\(key)}}")
                        .font(.dsCode).foregroundStyle(.dsAccent)
                        .padding(.horizontal, DS.Space.xs).padding(.vertical, DS.Space.xxs)
                        .background(Color.dsAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                    Image(systemName: "arrow.right").font(.dsMicro).foregroundStyle(.tertiary)
                    TextField("value", text: Binding(get: { model.inputs[key] ?? "" }, set: { model.inputs[key] = $0 }))
                        .dsTextField()
                }
            }
            if !model.hookOutputs.isEmpty {
                Label("Provided by hooks: \(model.hookOutputs.sorted().map { "{{\($0)}}" }.joined(separator: ", "))",
                      systemImage: "wand.and.stars")
                    .font(.dsCaption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            if !model.malformedTokens.isEmpty {
                Label("Unrecognized: \(model.malformedTokens.joined(separator: ", ")). Use letters, digits, or _ inside {{ }}.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.dsCaption).foregroundStyle(.dsWarning)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
            if !model.unusedHookOutputs.isEmpty {
                Label("Hook output unused: \(model.unusedHookOutputs.map { "{{\($0)}}" }.joined(separator: ", ")). Nothing reads it — check the hook's “out” name matches a {{token}}.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.dsCaption).foregroundStyle(.dsWarning)
                    .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }
        }
        .dsCard()
    }
}

// MARK: - One editable, role-labeled message block

private struct MessageBlockView: View {
    @Binding var message: ChatMessage
    let model: ChatModel

    private var roleColor: Color {
        switch message.role {
        case .system: return Color.secondary
        case .human:  return Color.dsAccent
        case .ai:     return Color.dsInfo
        }
    }
    private var editorLines: Int { message.role == .system ? 5 : 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            header
            if !message.collapsed { content }
            if let e = message.elapsed {
                HStack {
                    Spacer()
                    Text(String(format: "%.2f s", e)).font(.dsMicro.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let err = message.errorText {
                Text(err).font(.dsCaption).foregroundStyle(.dsDanger).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dsCard()
    }

    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            Menu {
                ForEach(ChatMessage.Role.allCases, id: \.self) { r in
                    Button(r.label) { message.role = r }
                }
            } label: {
                Text(message.role.label).font(.dsMicro.weight(.semibold)).kerning(0.6).foregroundStyle(roleColor)
            }
            .menuStyle(.borderlessButton).fixedSize().disabled(model.isRunning)

            if message.isStreaming { ProgressView().controlSize(.small) }
            Spacer()

            Button { model.move(message.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(model.isRunning)
            Button { model.move(message.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(model.isRunning)
            Button { message.collapsed.toggle() } label: {
                Image(systemName: message.collapsed ? "chevron.right" : "chevron.down").imageScale(.small)
            }
            .buttonStyle(.borderless)
            if message.role == .ai && !message.isStreaming {
                Button { Task { await model.regenerate(from: message.id) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(model.isRunning)
            }
            Button(role: .destructive) { model.delete(message.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).disabled(model.isRunning)
        }
        .font(.dsCaption)
    }

    @ViewBuilder
    private var content: some View {
        if message.role == .ai, let result = message.result {
            // Typed role-play render: reply + translation + two tappable suggestions.
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(result.reply.text).font(.dsBody).textSelection(.enabled)
                Text(result.reply.translation).font(.dsBody).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(result.suggestions.enumerated()), id: \.offset) { _, s in
                Button { Task { await model.sendSuggestion(s.text) } } label: {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(s.text).font(.dsBody).fontWeight(.medium)
                        Text(s.translation).font(.dsCaption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered).disabled(model.isRunning)
            }
            if !message.raw.isEmpty {
                DisclosureGroup("Raw JSON") {
                    Text(message.raw).font(.dsCode).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).dsFlat()
                }
                .font(.dsCaption)
            }
        } else {
            // Editable raw template (system / human / plain-or-dynamic AI).
            TextEditor(text: $message.content)
                .font(.dsCode)
                .dsEditor(lines: editorLines)
                .disabled(model.isRunning)
        }

        if message.role == .ai && !message.trace.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: DS.Space.sm) {
                    ForEach(message.trace) { StageCard(stage: $0) }
                }
                .padding(.top, DS.Space.xs)
            } label: { Text("Pipeline").font(.dsCaption) }
        }
    }
}
