//
//  PipelineView.swift
//  Prompt Playground
//
//  Phase-1 LLMOps surface: pick a task + dataset + prompt template + generation config, run the
//  whole dataset as one Experiment, and inspect persisted runs with their metrics, token usage,
//  and golden-readiness checks. Phase 2 layers on the LLM judge, manual ratings, and variant
//  comparison; Phase 3 adds golden export.
//

import SwiftUI
import SwiftData

struct PipelineView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \DatasetModel.createdAt) private var allDatasets: [DatasetModel]
    @Query(sort: \PromptTemplateModel.createdAt) private var allTemplates: [PromptTemplateModel]
    @Query(sort: \ExperimentModel.createdAt, order: .reverse) private var experiments: [ExperimentModel]
    @Query(sort: \SchemaModel.createdAt) private var allSchemas: [SchemaModel]

    @State private var runner = ExperimentRunner()
    @State private var task: TaskKind = .gloss
    @State private var selectedDatasetID: UUID?
    @State private var selectedTemplateID: UUID?
    @State private var selectedExperimentID: UUID?
    @State private var rankByScore = false

    @State private var config = GenConfig()
    @State private var selectedSchemaID: UUID?     // nil = typed/built-in schema

    private var datasets: [DatasetModel] { allDatasets.filter { $0.task == task } }
    private var templates: [PromptTemplateModel] { allTemplates.filter { $0.task == task } }
    private var selectedDataset: DatasetModel? { datasets.first { $0.id == selectedDatasetID } }
    private var selectedTemplate: PromptTemplateModel? { templates.first { $0.id == selectedTemplateID } }
    private var selectedExperiment: ExperimentModel? { experiments.first { $0.id == selectedExperimentID } }

    private func score(of e: ExperimentModel) -> Double {
        VariantStats.aggregate(e.runs.compactMap(\.metrics)).meanComposite
    }
    private var displayedExperiments: [ExperimentModel] {
        rankByScore ? experiments.sorted { score(of: $0) > score(of: $1) } : Array(experiments)
    }

    private var schemas: [SchemaModel] { allSchemas.filter { $0.task == task } }
    private var selectedSchema: SchemaModel? { schemas.first { $0.id == selectedSchemaID } }

    var body: some View {
        HSplitView {
            configPane
                .frame(minWidth: 320, idealWidth: 360)
            detailPane
                .frame(minWidth: 380)
        }
        .playgroundBackground()
        .onAppear(perform: syncSelections)
        .onChange(of: task) { _, _ in selectedSchemaID = nil; syncSelections() }
        .onChange(of: selectedSchemaID) { _, _ in if let s = selectedSchema { config = s.genConfig } }
        .onChange(of: selectedTemplateID) { _, _ in if let t = selectedTemplate { config = t.genConfig } }
    }

    // MARK: Config + experiment list

    private var configPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let msg = ModelAvailability.message {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("Task", selection: $task) {
                    ForEach(TaskKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                labeled("Dataset") {
                    Picker("Dataset", selection: $selectedDatasetID) {
                        ForEach(datasets) { Text("\($0.name) (\($0.examples.count))").tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                }

                labeled("Prompt template") {
                    Picker("Template", selection: $selectedTemplateID) {
                        ForEach(templates) { Text("\($0.name) v\($0.version)").tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                }

                if let t = selectedTemplate {
                    Text(t.instructions)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .padding(8)
                        .codeSurface()
                }

                labeled("Output schema") {
                    Picker("Schema", selection: $selectedSchemaID) {
                        Text("Typed (built-in)").tag(UUID?.none)
                        ForEach(schemas) { Text("\($0.name) v\($0.version)").tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                }

                genConfigControls

                Button(action: run) {
                    HStack(spacing: 6) {
                        if runner.isRunning { ProgressView().controlSize(.small) }
                        Text(runner.isRunning ? "Running \(runner.completed)/\(runner.total)…" : "Run experiment")
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(runner.isRunning || !ModelAvailability.isAvailable || selectedDataset == nil || selectedTemplate == nil)

                if runner.isRunning {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: runner.progress)
                        Text(runner.currentLabel).font(.caption).foregroundStyle(.secondary)
                        Button("Cancel") { runner.cancel() }.controlSize(.small)
                    }
                }

                Divider().padding(.vertical, 4)

                HStack {
                    Text("Experiments").font(.headline)
                    Spacer()
                    if !experiments.isEmpty {
                        Picker("", selection: $rankByScore) {
                            Text("Recent").tag(false)
                            Text("Top score").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                    }
                }
                if experiments.isEmpty {
                    Text("No runs yet. Configure a variant and press Run.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(displayedExperiments) { exp in experimentRow(exp) }
            }
            .padding(16)
        }
    }

    private var genConfigControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Generation config").font(.caption).foregroundStyle(.secondary)
            GenConfigControls(config: $config)
        }
    }

    private func experimentRow(_ exp: ExperimentModel) -> some View {
        let stats = VariantStats.aggregate(exp.runs.compactMap(\.metrics))
        return Button {
            selectedExperimentID = exp.id
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(exp.variantLabel).font(.callout).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    statusTag(exp.status)
                }
                HStack(spacing: 10) {
                    Text(exp.task.label)
                    Text(String(format: "score %.0f", stats.meanComposite))
                    Text(String(format: "decode %.0f%%", stats.decodeRate * 100))
                    Text("n=\(exp.runs.count)")
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .glassCard(highlighted: selectedExperimentID == exp.id)
        }
        .buttonStyle(.plain)
    }

    // MARK: Detail

    private var detailPane: some View {
        ScrollView {
            if let exp = selectedExperiment {
                ExperimentDetail(experiment: exp)
                    .padding(16)
            } else {
                Text("Select an experiment to see its runs, metrics, and golden-readiness.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    // MARK: Actions

    private func run() {
        guard let template = selectedTemplate, let dataset = selectedDataset else { return }
        let cfg = config
        let def = selectedSchema?.def
        let schemaID = selectedSchema.map { "dyn:\($0.id.uuidString)" } ?? builtinSchemaID(for: task)
        Task {
            let exp = await runner.run(task: task, template: template, config: cfg,
                                       schemaID: schemaID, schemaDef: def, dataset: dataset, context: context)
            if let exp { selectedExperimentID = exp.id }
        }
    }

    private func syncSelections() {
        if selectedDataset == nil { selectedDatasetID = datasets.first?.id }
        if selectedTemplate == nil { selectedTemplateID = templates.first?.id }
    }

    /// Label stored when no dynamic schema is chosen (typed lanes name their @Generable; generic = text).
    private func builtinSchemaID(for task: TaskKind) -> String {
        switch task {
        case .gloss:    return "GlossResultGen"
        case .roleplay: return "RoleplayTurnGen"
        case .generic:  return "Text"
        }
    }

    @ViewBuilder
    private func labeled<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.footnote).fontWeight(.medium).foregroundStyle(.primary.opacity(0.6))
            content()
        }
    }

    private func statusTag(_ status: String) -> some View {
        let color: Color = status == "done" ? Theme.accent : status == "cancelled" ? Theme.gold : Theme.cyan
        return Text(status)
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.22), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.5))
    }
}

// MARK: - Experiment detail

private struct ExperimentDetail: View {
    let experiment: ExperimentModel
    @Environment(\.modelContext) private var context
    @State private var isJudging = false
    @State private var judgeDone = 0
    @State private var judgeTotal = 0
    @State private var exportMessage: String?

    private var runs: [RunModel] { experiment.runs.sorted { $0.createdAt < $1.createdAt } }
    private var stats: VariantStats {
        VariantStats.aggregate(runs.compactMap(\.metrics),
                               manualRatings: runs.compactMap(\.manualRating),
                               judgeScores: runs.compactMap { JSONCoder.decode(JudgeScore.self, $0.judgeJSON)?.mean })
    }
    private var agreement: (meanAbsDiff: Double, within1: Double)? {
        let paired = runs.compactMap { r -> (Double, Int)? in
            guard let m = r.manualRating, let j = JSONCoder.decode(JudgeScore.self, r.judgeJSON)?.mean else { return nil }
            return (j, m)
        }
        return Agreement.compute(judge: paired.map(\.0), manual: paired.map(\.1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(experiment.variantLabel).font(.headline)
                Text("\(experiment.task.label) · dataset “\(experiment.datasetName)” · schema \(experiment.schemaID)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button(action: runJudge) {
                    HStack(spacing: 6) {
                        if isJudging { ProgressView().controlSize(.small) }
                        Image(systemName: "gavel")
                        Text(isJudging ? "Judging \(judgeDone)/\(judgeTotal)…" : "Run LLM judge")
                    }
                }
                .disabled(isJudging || !ModelAvailability.isAvailable)

                Button {
                    if let url = GoldenExport.export(experiment) {
                        exportMessage = "Saved \(url.lastPathComponent) — revealed in Finder."
                    } else {
                        exportMessage = "Export failed."
                    }
                } label: {
                    Label("Export golden JSON", systemImage: "square.and.arrow.up")
                }
                .disabled(experiment.runs.allSatisfy { !$0.decoded })
            }
            if let msg = exportMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }

            scorecard
            readiness

            Text("Runs").font(.headline)
            ForEach(runs) { RunRow(run: $0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func runJudge() {
        let targets = runs.filter(\.decoded)
        guard !targets.isEmpty else { return }
        isJudging = true; judgeDone = 0; judgeTotal = targets.count
        Task {
            for r in targets {
                if let score = await Judge.score(task: experiment.task, input: r.inputJSON,
                                                 output: r.turnsJSON ?? r.outputJSON) {
                    r.judgeJSON = JSONCoder.encode(score)
                    try? context.save()
                }
                judgeDone += 1
            }
            isJudging = false
        }
    }

    private var scorecard: some View {
        let cols = [GridItem(.adaptive(minimum: 130), alignment: .leading)]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
            stat("Mean score", String(format: "%.1f", stats.meanComposite))
            stat("Decode rate", String(format: "%.0f%%", stats.decodeRate * 100))
            if let l = stats.meanOnTargetLanguage { stat("On-target lang", String(format: "%.2f", l)) }
            stat("p95 context", "\(stats.p95ContextTokens) tok")
            stat("p95 latency", "\(stats.p95LatencyMs) ms")
            if let c = stats.meanCoverage { stat("Coverage", String(format: "%.2f", c)) }
            if let h = stats.meanHallucination { stat("Hallucination", String(format: "%.2f", h)) }
            if let two = stats.meanSuggestionCountOK { stat("2-suggestions", String(format: "%.2f", two)) }
            if let d = stats.meanDistinct { stat("Distinct", String(format: "%.2f", d)) }
            if let j = stats.meanJudge { stat("Judge (1–5)", String(format: "%.2f", j)) }
            if let m = stats.meanManualRating { stat("Manual (1–5)", String(format: "%.2f", m)) }
            if let a = agreement { stat("Judge≈human", String(format: "±%.2f · %.0f%%", a.meanAbsDiff, a.within1 * 100)) }
        }
    }

    private var readiness: some View {
        let checks = GoldenThresholds.evaluate(stats, task: experiment.task)
        let golden = checks.allSatisfy(\.pass)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: golden ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(golden ? .green : .secondary)
                Text(golden ? "Golden-ready" : "Not yet golden").font(.subheadline).fontWeight(.medium)
            }
            ForEach(checks) { c in
                HStack(spacing: 6) {
                    Image(systemName: c.pass ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(c.pass ? .green : .red).font(.caption)
                    Text(c.name).font(.caption)
                    Spacer()
                    Text(c.detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .glassCard()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }
}

private struct RunRow: View {
    let run: RunModel
    @Environment(\.modelContext) private var context
    @State private var expanded = false

    private var judge: JudgeScore? { JSONCoder.decode(JudgeScore.self, run.judgeJSON) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: run.decoded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(run.decoded ? .green : .red)
                Text(run.exampleLabel).font(.callout).lineLimit(1)
                Spacer()
                Text(String(format: "%.0f", run.composite)).font(.callout.monospacedDigit())
            }
            HStack(spacing: 10) {
                Text("ctx \(run.contextTokensEst) (\(run.contextHeadroom) left)")
                Text("\(run.latencyMs) ms")
                if let l = run.onTargetLanguage { Text(String(format: "lang %.2f", l)) }
                if let j = judge { Text(String(format: "judge %.1f", j.mean)) }
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Text("Your rating").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { run.manualRating ?? 0 },
                    set: { run.manualRating = ($0 == 0 ? nil : $0); try? context.save() }
                )) {
                    Text("–").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }

            if let err = run.errorText {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let j = judge {
                Text("Judge: \(j.rationale)").font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Output", isExpanded: $expanded) {
                Text(run.turnsJSON ?? run.outputJSON)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .codeSurface()
            }
            .font(.caption)
        }
        .padding(12)
        .glassCard()
    }
}
