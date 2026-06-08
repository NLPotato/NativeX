//
//  DatasetsView.swift
//  Prompt Playground
//
//  Dataset manager tab: the curate-your-test-set surface the Lab tab lacked. Lists every dataset
//  (both tasks), shows the examples inside the selected one, and supports full CRUD on examples +
//  datasets over the same SwiftData store the Lab reads. Writes mirror SaveToPipeline's pattern
//  (ExampleModel(task:label:inputJSON:) + ex.dataset = … + context.insert). Reference-free for now
//  — examples carry inputs only; expected/"gold" outputs are a roadmap item.
//

import SwiftUI
import SwiftData

struct DatasetsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \DatasetModel.createdAt) private var datasets: [DatasetModel]

    @State private var selectedDatasetID: UUID?
    @State private var showingNewDataset = false
    @State private var editorTarget: ExampleEditorSheet.Target?

    @State private var renamingDataset: DatasetModel?
    @State private var renameText = ""
    @State private var datasetPendingDelete: DatasetModel?

    private var selectedDataset: DatasetModel? { datasets.first { $0.id == selectedDatasetID } }

    var body: some View {
        HSplitView {
            masterPane
                .frame(minWidth: 260, idealWidth: 300)
            detailPane
                .frame(minWidth: 380)
        }
        .playgroundBackground()
        .onAppear { if selectedDatasetID == nil { selectedDatasetID = datasets.first?.id } }
        .sheet(isPresented: $showingNewDataset) {
            NewDatasetSheet { selectedDatasetID = $0 }
        }
        .sheet(item: $editorTarget) { ExampleEditorSheet(target: $0) }
        .alert("Rename dataset", isPresented: Binding(
            get: { renamingDataset != nil },
            set: { if !$0 { renamingDataset = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingDataset = nil }
            Button("Save") {
                if let d = renamingDataset {
                    let n = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !n.isEmpty { d.name = n; try? context.save() }
                }
                renamingDataset = nil
            }
        }
        .confirmationDialog("Delete this dataset and all its examples?", isPresented: Binding(
            get: { datasetPendingDelete != nil },
            set: { if !$0 { datasetPendingDelete = nil } }),
            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let d = datasetPendingDelete { deleteDataset(d) }
                datasetPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { datasetPendingDelete = nil }
        }
    }

    // MARK: Master — dataset list

    private var masterPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Datasets").font(.headline)
                    Spacer()
                    Button { showingNewDataset = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New dataset")
                }
                if datasets.isEmpty {
                    Text("No datasets yet. Create one with +.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(datasets) { datasetRow($0) }
            }
            .padding(16)
        }
    }

    private func datasetRow(_ d: DatasetModel) -> some View {
        Button { selectedDatasetID = d.id } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(d.name).font(.callout).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    taskBadge(d.task)
                }
                Text("\(d.examples.count) example\(d.examples.count == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .glassCard(highlighted: selectedDatasetID == d.id)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") { renameText = d.name; renamingDataset = d }
            Button("Duplicate") { duplicateDataset(d) }
            Divider()
            Button("Delete…", role: .destructive) { datasetPendingDelete = d }
        }
    }

    // MARK: Detail — examples in the selected dataset

    private var detailPane: some View {
        ScrollView {
            if let d = selectedDataset {
                examplesList(d).padding(16)
            } else {
                Text("Select a dataset to see and edit its examples, or create one with +.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    private func examplesList(_ d: DatasetModel) -> some View {
        let examples = d.examples.sorted { $0.createdAt < $1.createdAt }
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(d.name).font(.headline)
                    taskBadge(d.task)
                    Spacer()
                    Button { editorTarget = .new(d) } label: { Label("Add example", systemImage: "plus") }
                }
                Text("\(examples.count) example\(examples.count == 1 ? "" : "s") · the test set when you run this dataset in the Lab tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if examples.isEmpty {
                Text("No examples yet. Add one with “Add example”.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(examples) { exampleRow($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func exampleRow(_ ex: ExampleModel) -> some View {
        Button { editorTarget = .edit(ex) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(ex.label).font(.callout).fontWeight(.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(previewText(ex))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .glassCard()
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit…") { editorTarget = .edit(ex) }
            Button("Delete", role: .destructive) { context.delete(ex); try? context.save() }
        }
    }

    private func previewText(_ ex: ExampleModel) -> String {
        switch ex.task {
        case .gloss:
            guard let g = ex.glossInput else { return "—" }
            return "\(g.sentence)  ·  \(g.learning) → \(g.native)"
        case .roleplay:
            guard let r = ex.roleplayInput else { return "—" }
            return "\(r.situation)  ·  you: \(r.youRole) / ai: \(r.aiRole)  ·  \(r.learning)"
        case .generic:
            guard let g = ex.genericInput else { return "—" }
            let vars = g.variables.isEmpty ? "" :
                "  ·  " + g.variables.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            return g.input + vars
        }
    }

    // MARK: CRUD

    private func deleteDataset(_ d: DatasetModel) {
        let deletedID = d.id
        let fallback = datasets.first { $0.id != deletedID }?.id
        context.delete(d)                       // cascade removes its examples (Storage.swift)
        try? context.save()
        if selectedDatasetID == deletedID { selectedDatasetID = fallback }
    }

    private func duplicateDataset(_ d: DatasetModel) {
        let copy = DatasetModel(task: d.task, name: "\(d.name) copy")
        context.insert(copy)
        for ex in d.examples {
            let c = ExampleModel(task: ex.task, label: ex.label, inputJSON: ex.inputJSON)
            c.dataset = copy
            context.insert(c)
        }
        try? context.save()
        selectedDatasetID = copy.id
    }

    // MARK: Bits

    private func taskBadge(_ task: TaskKind) -> some View {
        let color: Color
        switch task {
        case .gloss:    color = Theme.accent
        case .roleplay: color = Theme.cyan
        case .generic:  color = Theme.gold
        }
        return Text(task.label)
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.22), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.5))
    }
}

// MARK: - New dataset

private struct NewDatasetSheet: View {
    var onCreated: (UUID) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var task: TaskKind = .gloss
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("New dataset").font(.title3).fontWeight(.semibold)
                Text("A named set of test cases for one task. Run it in the Lab tab.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)

            Form {
                Picker("Task", selection: $task) {
                    ForEach(TaskKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                TextField("Dataset name", text: $name)
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 460, height: 240)
    }

    private func create() {
        let d = DatasetModel(task: task, name: trimmed)
        context.insert(d)
        try? context.save()
        onCreated(d.id)
        dismiss()
    }
}

// MARK: - Example editor

struct ExampleEditorSheet: View {
    enum Target: Identifiable {
        case new(DatasetModel)
        case edit(ExampleModel)
        var id: String {
            switch self {
            case .new(let d): return "new-\(d.id.uuidString)"
            case .edit(let e): return "edit-\(e.id.uuidString)"
            }
        }
    }

    let target: Target

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    // gloss
    @State private var sentence = ""
    @State private var learning = ""
    @State private var native = "English"
    // role-play
    @State private var situation = ""
    @State private var youRole = ""
    @State private var aiRole = ""
    @State private var turns: [TurnDraft] = []
    @State private var maxTurns = 4
    // generic
    @State private var genInput = ""
    @State private var genVars: [VarDraft] = []

    private struct TurnDraft: Identifiable { let id = UUID(); var text: String }
    private struct VarDraft: Identifiable { let id = UUID(); var key: String; var value: String }

    private var task: TaskKind {
        switch target {
        case .new(let d): return d.task
        case .edit(let e): return e.task
        }
    }
    private var isEditing: Bool { if case .edit = target { return true }; return false }

    private var canSave: Bool {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch task {
        case .gloss:
            return ![sentence, learning, native].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case .roleplay:
            return ![learning, native, situation, youRole, aiRole].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        case .generic:
            return !genInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "Edit example" : "New example").font(.title3).fontWeight(.semibold)
                Text("\(task.label) test case — the input a Lab experiment runs against.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)

            Form {
                Section("Label") {
                    TextField("Short name for this case", text: $label)
                }
                switch task {
                case .gloss: glossFields
                case .roleplay: roleplayFields
                case .generic: genericFields
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 520, height: task == .gloss ? 440 : 640)
        .onAppear(perform: load)
    }

    @ViewBuilder private var glossFields: some View {
        Section("Gloss input") {
            TextField("Sentence to analyze", text: $sentence, axis: .vertical).lineLimit(1...4)
            TextField("Learning language (e.g. German)", text: $learning)
            TextField("Native language (e.g. English)", text: $native)
        }
    }

    @ViewBuilder private var roleplayFields: some View {
        Section("Languages") {
            TextField("Learning language", text: $learning)
            TextField("Native language", text: $native)
        }
        Section("Scene") {
            TextField("Situation", text: $situation, axis: .vertical).lineLimit(1...3)
            TextField("Your role", text: $youRole)
            TextField("AI role", text: $aiRole)
            Stepper("Max AI turns: \(maxTurns)", value: $maxTurns, in: 1...12)
        }
        Section("Scripted user turns") {
            if turns.isEmpty {
                Text("No scripted turns — the runner auto-advances on the first suggestion.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($turns) { $t in
                HStack {
                    TextField("User turn", text: $t.text)
                    Button(role: .destructive) { turns.removeAll { $0.id == t.id } } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button { turns.append(TurnDraft(text: "")) } label: { Label("Add turn", systemImage: "plus") }
        }
    }

    @ViewBuilder private var genericFields: some View {
        Section("Prompt") {
            TextField("Prompt sent to the model", text: $genInput, axis: .vertical).lineLimit(1...5)
        }
        Section("Variables") {
            if genVars.isEmpty {
                Text("No variables. Add the {{name}} values this prompt's instructions or pre-hooks expect.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach($genVars) { $v in
                HStack(spacing: 6) {
                    TextField("name", text: $v.key).frame(width: 120)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                    TextField("value", text: $v.value)
                    Button(role: .destructive) { genVars.removeAll { $0.id == v.id } } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button { genVars.append(VarDraft(key: "", value: "")) } label: { Label("Add variable", systemImage: "plus") }
        }
    }

    private func load() {
        guard case .edit(let e) = target else { return }
        label = e.label
        switch e.task {
        case .gloss:
            if let g = e.glossInput { sentence = g.sentence; learning = g.learning; native = g.native }
        case .roleplay:
            if let r = e.roleplayInput {
                learning = r.learning; native = r.native; situation = r.situation
                youRole = r.youRole; aiRole = r.aiRole; maxTurns = r.maxTurns
                turns = r.scriptedUserTurns.map { TurnDraft(text: $0) }
            }
        case .generic:
            if let g = e.genericInput {
                genInput = g.input
                genVars = g.variables.map { VarDraft(key: $0.key, value: $0.value) }.sorted { $0.key < $1.key }
            }
        }
    }

    private func save() {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        switch task {
        case .gloss:
            json = JSONCoder.encode(GlossInput(sentence: sentence, learning: learning, native: native))
        case .roleplay:
            let scripted = turns.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
            json = JSONCoder.encode(RoleplayInput(learning: learning, native: native, situation: situation,
                                                  youRole: youRole, aiRole: aiRole,
                                                  scriptedUserTurns: scripted, maxTurns: maxTurns))
        case .generic:
            let vars = Dictionary(genVars.map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) }
                                        .filter { !$0.0.isEmpty }, uniquingKeysWith: { _, b in b })
            json = JSONCoder.encode(GenericInput(input: genInput, variables: vars))
        }
        switch target {
        case .new(let d):
            let ex = ExampleModel(task: task, label: trimmedLabel, inputJSON: json)
            ex.dataset = d                       // inverse populates dataset.examples
            context.insert(ex)
        case .edit(let e):
            e.label = trimmedLabel
            e.inputJSON = json
        }
        try? context.save()
        dismiss()
    }
}
