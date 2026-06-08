//
//  SaveToPipeline.swift
//  Prompt Playground
//
//  Bridge from the single-shot playground tabs into the pipeline store: promote the prompt you
//  just hand-tuned into a versioned PromptTemplateModel, and/or the input you just tried into a
//  dataset ExampleModel. Workflow stays "explore on Gloss/Role-play → capture the good ones as
//  reusable pipeline templates + test cases" without leaving the app.
//

import SwiftUI
import SwiftData
import AppKit

/// Capture sheet shown from a playground tab. The caller supplies the (already canonicalized)
/// prompt text and the encoded example input; the sheet handles naming, versioning, dataset
/// targeting, and the inserts into the same SwiftData store the Pipeline tab reads.
struct SaveToPipelineSheet: View {
    let task: TaskKind
    let promptInstructions: String      // canonical {{vars}} prompt to save as a template version
    let defaultTemplateName: String
    let defaultExampleLabel: String
    let exampleInputJSON: String
    let canSaveExample: Bool
    let exampleHint: String             // what gets captured (shown under the example section)
    var onSaved: (String) -> Void
    /// When non-nil, the tab is in Custom-schema mode: offer to persist the schema + export Swift.
    var schemaDef: SchemaDef? = nil
    var liveConfig: GenConfig = GenConfig()
    /// Pre/post hooks captured with the prompt so the Lab replays them (generic lane).
    var hooks: HookPipelineDef = .empty

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var templates: [PromptTemplateModel] = []
    @State private var datasets: [DatasetModel] = []

    @State private var saveTemplate = true
    @State private var templateName = ""
    @State private var saveExample = false
    @State private var exampleLabel = ""
    @State private var datasetChoice: DatasetChoice = .new
    @State private var newDatasetName = "Playground captures"
    @State private var schemas: [SchemaModel] = []
    @State private var saveSchema = true
    @State private var schemaName = ""
    @State private var exportNote: String?

    private enum DatasetChoice: Hashable { case existing(UUID), new }

    /// Next version number for a template saved under the current name (max existing + 1).
    private var nextVersion: Int {
        let name = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
        return (templates.filter { $0.task == task && $0.name == name }.map(\.version).max() ?? 0) + 1
    }

    private var trimmedTemplateName: String { templateName.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var trimmedSchemaName: String { schemaName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nextSchemaVersion: Int {
        (schemas.filter { $0.task == task && $0.name == trimmedSchemaName }.map(\.version).max() ?? 0) + 1
    }
    private var generatedSwift: String { schemaDef.map(SwiftCodegen.emit) ?? "" }

    private var exampleTargetValid: Bool {
        switch datasetChoice {
        case .existing: return true
        case .new: return !newDatasetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var canSave: Bool {
        let templateOK = saveTemplate && !trimmedTemplateName.isEmpty
        let exampleOK = saveExample && canSaveExample && exampleTargetValid
        let schemaOK = schemaDef != nil && saveSchema && !trimmedSchemaName.isEmpty
        return templateOK || exampleOK || schemaOK
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text("Save to Lab").font(.dsTitle)
                Text("Promote what you just tried into reusable Lab templates and test cases.")
                    .font(.dsCaption).foregroundStyle(.tertiary)
            }
            .padding([.horizontal, .top], DS.Layout.paneInset)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Layout.groupGap) {
                    VStack(alignment: .leading, spacing: DS.Layout.fieldGap) {
                        DSSectionHeader("Prompt template")
                        Toggle("Save prompt as a template version", isOn: $saveTemplate)
                        if saveTemplate {
                            DSField(label: "Template name",
                                    help: trimmedTemplateName.isEmpty
                                        ? "Enter a name."
                                        : "Saves as “\(trimmedTemplateName) v\(nextVersion)” for the \(task.label) task.") {
                                TextField("", text: $templateName).dsTextField()
                            }
                            if !hooks.isEmpty {
                                Text("Includes \(hooks.pre.count) pre + \(hooks.post.count) post hook\(hooks.pre.count + hooks.post.count == 1 ? "" : "s") — replayed in the Lab.")
                                    .font(.dsCaption).foregroundStyle(.secondary)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: DS.Layout.fieldGap) {
                        DSSectionHeader("Dataset example")
                        Toggle("Add input as a dataset example", isOn: $saveExample)
                            .disabled(!canSaveExample)
                        if saveExample && canSaveExample {
                            DSField(label: "Example label") {
                                TextField("", text: $exampleLabel).dsTextField()
                            }
                            DSField(label: "Dataset") {
                                Picker("", selection: $datasetChoice) {
                                    ForEach(datasets) { d in
                                        Text("\(d.name) (\(d.examples.count))").tag(DatasetChoice.existing(d.id))
                                    }
                                    Text("New dataset…").tag(DatasetChoice.new)
                                }
                                .labelsHidden()
                            }
                            if datasetChoice == .new {
                                DSField(label: "New dataset name") {
                                    TextField("", text: $newDatasetName).dsTextField()
                                }
                            }
                        }
                        Text(canSaveExample ? exampleHint : "Fill in the input first to capture it as an example.")
                            .font(.dsCaption).foregroundStyle(.tertiary)
                    }

                    if schemaDef != nil {
                        VStack(alignment: .leading, spacing: DS.Layout.fieldGap) {
                            DSSectionHeader("Output schema")
                            Toggle("Save schema as a version", isOn: $saveSchema)
                            if saveSchema {
                                DSField(label: "Schema name",
                                        help: trimmedSchemaName.isEmpty
                                            ? "Enter a name."
                                            : "Saves as “\(trimmedSchemaName) v\(nextSchemaVersion)” — persists for dynamic batch eval in the Lab tab.") {
                                    TextField("", text: $schemaName).dsTextField()
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: DS.Layout.fieldGap) {
                            DSSectionHeader("Swift @Generable")
                            Text("Paste into the app target to promote this prototype to the typed shipping lane.")
                                .font(.dsCaption).foregroundStyle(.tertiary)
                            ScrollView {
                                Text(generatedSwift)
                                    .font(.dsCode)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: DS.lineHeight * 7)
                            .dsFlat()
                            HStack {
                                Button { copySwift() } label: { Label("Copy Swift", systemImage: "doc.on.doc") }
                                Button { saveSwiftFile() } label: { Label("Save .swift to Documents…", systemImage: "square.and.arrow.down") }
                            }
                            .font(.dsCaption)
                            if let n = exportNote { Text(n).font(.dsMicro).foregroundStyle(.dsSuccess) }
                            Text("Array counts aren’t emitted as hard guides — tune as @Guide after pasting.")
                                .font(.dsMicro).foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(DS.Layout.paneInset)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(DS.Layout.groupGap)
        }
        .frame(minWidth: DS.Size.sheetMinWidth, idealWidth: DS.Size.sheetIdealWidth,
               minHeight: schemaDef != nil ? 660 : 470)
        .onAppear(perform: load)
    }

    private func load() {
        templateName = defaultTemplateName
        exampleLabel = defaultExampleLabel
        saveExample = canSaveExample
        let raw = task.rawValue
        templates = (try? context.fetch(FetchDescriptor<PromptTemplateModel>(
            predicate: #Predicate { $0.taskRaw == raw }))) ?? []
        datasets = (try? context.fetch(FetchDescriptor<DatasetModel>(
            predicate: #Predicate { $0.taskRaw == raw }, sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        if let first = datasets.first { datasetChoice = .existing(first.id) }
        schemas = (try? context.fetch(FetchDescriptor<SchemaModel>(
            predicate: #Predicate { $0.taskRaw == raw }))) ?? []
        if schemaName.isEmpty { schemaName = schemaDef?.typeName ?? "\(task.label) schema" }
    }

    private func save() {
        var parts: [String] = []

        if saveTemplate && !trimmedTemplateName.isEmpty {
            let v = nextVersion
            context.insert(PromptTemplateModel(task: task, name: trimmedTemplateName, version: v,
                                               instructions: promptInstructions,
                                               notes: "Captured from the playground.",
                                               genConfig: liveConfig, hooks: hooks))
            parts.append("template “\(trimmedTemplateName) v\(v)”")
        }

        if saveExample && canSaveExample {
            let dataset: DatasetModel
            switch datasetChoice {
            case .existing(let id): dataset = datasets.first { $0.id == id } ?? newDataset()
            case .new:              dataset = newDataset()
            }
            let label = exampleLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let ex = ExampleModel(task: task, label: label.isEmpty ? defaultExampleLabel : label,
                                  inputJSON: exampleInputJSON)
            ex.dataset = dataset                 // inverse populates dataset.examples (see Pipeline.swift)
            context.insert(ex)
            parts.append("example in “\(dataset.name)”")
        }

        if saveSchema, let def = schemaDef, !trimmedSchemaName.isEmpty {
            let v = nextSchemaVersion
            context.insert(SchemaModel(task: task, name: trimmedSchemaName, version: v, def: def,
                                       genConfig: liveConfig, notes: "Captured from the playground."))
            parts.append("schema “\(trimmedSchemaName) v\(v)”")
        }

        try? context.save()
        onSaved("Saved " + parts.joined(separator: " + ") + ".")
        dismiss()
    }

    private func newDataset() -> DatasetModel {
        let d = DatasetModel(task: task, name: newDatasetName.trimmingCharacters(in: .whitespacesAndNewlines))
        context.insert(d)
        return d
    }

    private func copySwift() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(generatedSwift, forType: .string)
        exportNote = "Copied to clipboard."
    }

    /// Write the generated Swift to Documents/schemas and reveal it (same pattern as GoldenExport).
    private func saveSwiftFile() {
        let base = (schemaDef?.typeName ?? "Schema").replacingOccurrences(of: " ", with: "")
        let dir = URL.documentsDirectory.appending(path: "schemas", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "\(base.isEmpty ? "Schema" : base).swift")
        do {
            try Data(generatedSwift.utf8).write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            exportNote = "Saved \(url.lastPathComponent) to Documents/schemas."
        } catch {
            exportNote = "Couldn’t write the .swift file."
        }
    }
}
