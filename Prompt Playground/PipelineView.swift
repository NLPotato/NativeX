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
    @State private var prewarm = false
    // Sweep config — the cartesian product of these axes becomes one Variant each.
    @State private var showSweep = false
    @State private var sweepTemplateIDs: Set<UUID> = []
    @State private var sweepTemps: Set<Double> = [0.3, 0.7]
    @State private var sweepModes: Set<GenConfig.Sampling> = [.greedy, .nucleus]

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
                .frame(minWidth: DS.Size.panelMinWidth, idealWidth: DS.Size.panelIdealWidth)
            detailPane
                .frame(minWidth: DS.Size.panelMinWidth)
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
            VStack(alignment: .leading, spacing: DS.Layout.groupGap) {
                if let msg = ModelAvailability.message {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.dsBody).foregroundStyle(.dsWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("Task", selection: $task) {
                    ForEach(TaskKind.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                DSField(label: "Dataset") {
                    Picker("Dataset", selection: $selectedDatasetID) {
                        ForEach(datasets) { Text("\($0.name) (\($0.examples.count))").tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                }

                DSField(label: "Prompt template") {
                    Picker("Template", selection: $selectedTemplateID) {
                        ForEach(templates) { Text("\($0.name) v\($0.version)").tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                }

                if let t = selectedTemplate {
                    Text(t.instructions)
                        .font(.dsCode)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .dsFlat()
                    variantInspector(t)
                }

                DSField(label: "Output schema") {
                    Picker("Schema", selection: $selectedSchemaID) {
                        Text("Typed (built-in)").tag(UUID?.none)
                        ForEach(schemas) { Text("\($0.name) v\($0.version)").tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                }

                genConfigControls

                Toggle(isOn: $prewarm) { Text("Prewarm session before timing").font(.dsLabel) }
                    .font(.dsBody)

                Button(action: run) {
                    HStack(spacing: DS.Space.sm) {
                        if runner.isRunning && !runner.isSweep { ProgressView().controlSize(.small) }
                        Text(runner.isRunning && !runner.isSweep ? "Running \(runner.completed)/\(runner.total)…" : "Run experiment")
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(runner.isRunning || !ModelAvailability.isAvailable || selectedDataset == nil || selectedTemplate == nil)

                sweepPanel

                if runner.isRunning {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        if runner.isSweep {
                            Text("Variant \(min(runner.sweepCompleted + 1, runner.sweepTotal))/\(runner.sweepTotal)")
                                .font(.dsCaption)
                        }
                        ProgressView(value: runner.progress)
                        Text(runner.currentLabel).font(.dsCaption).foregroundStyle(.secondary)
                        Button("Cancel") { runner.cancel() }.controlSize(.small)
                    }
                }

                Divider().padding(.vertical, DS.Space.xs)

                HStack {
                    DSSectionHeader("Experiments")
                    Spacer()
                    if !experiments.isEmpty {
                        Picker("", selection: $rankByScore) {
                            Text("Recent").tag(false)
                            Text("Top score").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                }
                if experiments.isEmpty {
                    Text("No runs yet. Configure a variant and press Run.")
                        .font(.dsBody).foregroundStyle(.secondary)
                }
                ForEach(displayedExperiments) { exp in experimentRow(exp) }
            }
            .padding(DS.Layout.paneInset)
        }
    }

    private var genConfigControls: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            DSSectionHeader("Generation config")
            GenConfigControls(config: $config)
        }
    }

    private func experimentRow(_ exp: ExperimentModel) -> some View {
        let stats = VariantStats.aggregate(exp.runs.compactMap(\.metrics))
        return Button {
            selectedExperimentID = exp.id
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack {
                    Text(exp.variantLabel).font(.dsBody).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    statusTag(exp.status)
                }
                HStack(spacing: DS.Space.md) {
                    Text(exp.task.label)
                    if exp.sweepID != nil { Text("sweep").foregroundStyle(.dsAccent) }
                    Text(String(format: "score %.0f", stats.meanComposite))
                    Text(String(format: "decode %.0f%%", stats.decodeRate * 100))
                    Text("n=\(exp.runs.count)")
                }
                .font(.dsMicro.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard(raised: selectedExperimentID == exp.id)
        }
        .buttonStyle(.plain)
    }

    // MARK: Detail

    private var detailPane: some View {
        ScrollView {
            if let exp = selectedExperiment {
                VStack(alignment: .leading, spacing: DS.Layout.groupGap) {
                    if let sid = exp.sweepID { sweepComparison(sid) }
                    ExperimentDetail(experiment: exp)
                }
                .padding(DS.Layout.paneInset)
            } else {
                Text("Select an experiment to see its runs, metrics, and golden-readiness.")
                    .font(.dsBody).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Layout.paneInset)
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
            let exp = await runner.run(task: task, template: template, config: cfg, schemaID: schemaID,
                                       schemaDef: def, dataset: dataset, context: context, prewarm: prewarm)
            if let exp { selectedExperimentID = exp.id }
        }
    }

    // MARK: Sweep

    /// Cartesian product of selected templates × sampling modes × temperatures. Greedy is
    /// deterministic (temperature is ignored), so it contributes exactly one variant per template.
    private func buildSweepVariants() -> [Variant] {
        let chosen = templates.filter { sweepTemplateIDs.contains($0.id) }
        let def = selectedSchema?.def
        let schemaID = selectedSchema.map { "dyn:\($0.id.uuidString)" } ?? builtinSchemaID(for: task)
        var variants: [Variant] = []
        for t in chosen {
            for mode in sweepModes.sorted(by: { $0.rawValue < $1.rawValue }) {
                if mode == .greedy {
                    var c = config; c.sampling = .greedy; c.temperature = nil
                    variants.append(Variant(template: t, schemaDef: def, schemaID: schemaID, config: c))
                } else {
                    let temps = sweepTemps.isEmpty ? [config.temperature ?? 0.7] : sweepTemps.sorted()
                    for temp in temps {
                        var c = config; c.sampling = mode; c.temperature = temp
                        if mode == .topK, c.topK == nil { c.topK = 50 }
                        if mode == .nucleus, c.probabilityThreshold == nil { c.probabilityThreshold = 0.9 }
                        variants.append(Variant(template: t, schemaDef: def, schemaID: schemaID, config: c))
                    }
                }
            }
        }
        return variants
    }

    private var sweepVariantCount: Int { buildSweepVariants().count }

    private func runSweep() {
        let variants = buildSweepVariants()
        guard let dataset = selectedDataset, !variants.isEmpty else { return }
        Task {
            let exps = await runner.runSweep(variants: variants, task: task, dataset: dataset,
                                             context: context, prewarm: prewarm)
            if let first = exps.first { selectedExperimentID = first.id }
        }
    }

    private func syncSelections() {
        if selectedDataset == nil { selectedDatasetID = datasets.first?.id }
        if selectedTemplate == nil { selectedTemplateID = templates.first?.id }
        if sweepTemplateIDs.isEmpty, let id = selectedTemplateID { sweepTemplateIDs = [id] }
    }

    /// Label stored when no dynamic schema is chosen (typed lanes name their @Generable; generic = text).
    private func builtinSchemaID(for task: TaskKind) -> String {
        switch task {
        case .gloss:    return "GlossResultGen"
        case .roleplay: return "RoleplayTurnGen"
        case .generic:  return "Text"
        }
    }

    // MARK: Sweep UI

    private var sweepPanel: some View {
        DisclosureGroup(isExpanded: $showSweep) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text("Templates").font(.dsMicro).foregroundStyle(.secondary)
                ForEach(templates) { t in
                    Toggle(isOn: templateChip(t.id)) { Text("\(t.name) v\(t.version)").font(.dsCaption) }
                        .toggleStyle(.checkbox)
                }
                Text("Sampling modes").font(.dsMicro).foregroundStyle(.secondary)
                HStack(spacing: DS.Space.xs) {
                    ForEach([GenConfig.Sampling.greedy, .default, .nucleus, .topK], id: \.self) { m in
                        chip(m.label, on: sweepModes.contains(m)) { toggleMode(m) }
                    }
                }
                Text("Temperatures (random modes only)").font(.dsMicro).foregroundStyle(.secondary)
                HStack(spacing: DS.Space.xs) {
                    ForEach([0.0, 0.3, 0.5, 0.7, 1.0], id: \.self) { temp in
                        chip(String(format: "%.1f", temp), on: sweepTemps.contains(temp)) { toggleTemp(temp) }
                    }
                }
                let exampleCount = selectedDataset?.examples.count ?? 0
                let runs = sweepVariantCount * exampleCount
                Text("\(sweepVariantCount) variants × \(exampleCount) examples = \(runs) runs")
                    .font(.dsCaption)
                    .foregroundStyle(runs > 200 ? AnyShapeStyle(.dsWarning) : AnyShapeStyle(.secondary))
                Button(action: runSweep) {
                    HStack(spacing: DS.Space.sm) {
                        if runner.isRunning && runner.isSweep { ProgressView().controlSize(.small) }
                        Text("Run sweep").frame(maxWidth: .infinity)
                    }
                }
                .controlSize(.large)
                .disabled(runner.isRunning || !ModelAvailability.isAvailable || selectedDataset == nil || sweepVariantCount == 0)
            }
            .padding(.top, DS.Space.xs)
        } label: {
            DSSectionHeader("Sweep — compare variants")
        }
    }

    /// Side-by-side leaderboard over a sweep's experiments, ranked by score, winner highlighted.
    @ViewBuilder private func sweepComparison(_ sid: UUID) -> some View {
        let group = experiments.filter { $0.sweepID == sid }.sorted { score(of: $0) > score(of: $1) }
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            DSSectionHeader("Sweep — \(group.count) variants")
            ForEach(Array(group.enumerated()), id: \.element.id) { idx, exp in
                let st = VariantStats.aggregate(exp.runs.compactMap(\.metrics))
                let ttft = exp.runs.compactMap(\.ttftMs)
                Button { selectedExperimentID = exp.id } label: {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        HStack(spacing: DS.Space.sm) {
                            if idx == 0 { Image(systemName: "trophy.fill").foregroundStyle(.dsAccent).font(.dsMicro) }
                            Text(exp.variantLabel).font(.dsCaption).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(String(format: "%.0f", st.meanComposite)).font(.dsBody.monospacedDigit())
                        }
                        HStack(spacing: DS.Space.md) {
                            Text(String(format: "decode %.0f%%", st.decodeRate * 100))
                            if let r = st.meanReferenceMatch { Text(String(format: "ref %.2f", r)) }
                            if let l = st.meanOnTargetLanguage { Text(String(format: "lang %.2f", l)) }
                            Text("p95 \(st.p95LatencyMs)ms")
                            if !ttft.isEmpty { Text("ttft \(ttft.reduce(0, +) / ttft.count)ms") }
                        }
                        .font(.dsMicro.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsCard(raised: selectedExperimentID == exp.id)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func chip(_ label: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.dsCaption)
                .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xxs)
                .background((on ? Color.dsAccent : Color.secondary).opacity(on ? 0.22 : 0.12), in: Capsule())
                .foregroundStyle(on ? AnyShapeStyle(.dsAccent) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(.plain)
    }
    private func templateChip(_ id: UUID) -> Binding<Bool> {
        Binding(get: { sweepTemplateIDs.contains(id) },
                set: { if $0 { sweepTemplateIDs.insert(id) } else { sweepTemplateIDs.remove(id) } })
    }
    private func toggleMode(_ m: GenConfig.Sampling) {
        if sweepModes.contains(m) { sweepModes.remove(m) } else { sweepModes.insert(m) }
    }
    private func toggleTemp(_ t: Double) {
        if sweepTemps.contains(t) { sweepTemps.remove(t) } else { sweepTemps.insert(t) }
    }

    /// Pre-run sanity net for the selected variant: its hook pipeline, plus the same mis-wiring
    /// guards Single-shot surfaces (malformed tokens, unused hook outputs) and a cross-check that the
    /// chosen dataset's examples actually provide the `{{tokens}}` the template references.
    @ViewBuilder private func variantInspector(_ t: PromptTemplateModel) -> some View {
        let hooks = t.hooks
        let malformed = PromptAnalysis.malformedTokens(in: t.instructions)
        let unused = PromptAnalysis.unusedHookOutputs(instructions: t.instructions, input: "", hooks: hooks)
        let templateVars = PromptAnalysis.variableKeys(instructions: t.instructions, input: "", hooks: hooks)
        let genInputs = (selectedDataset?.examples ?? []).compactMap { $0.genericInput }
        let missing = genInputs.isEmpty ? [] :
            templateVars.filter { tok in genInputs.contains { !$0.variables.keys.contains(tok) } }
        let warnings = variantWarnings(malformed: malformed, unused: unused, missing: missing)

        if !hooks.isEmpty || !warnings.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                if !hooks.isEmpty {
                    Text("Hooks").font(.dsMicro).foregroundStyle(.secondary)
                    ForEach(hooks.pre + hooks.post) { hook in
                        HStack(spacing: DS.Space.xs) {
                            hookPortabilityBadge(hook.op.portability)
                            Text("\(hook.op.displayName) · \(hook.inputVar)→\(hook.outputVar.isEmpty ? "—" : hook.outputVar)")
                                .font(.dsMicro.monospaced())
                                .foregroundStyle(hook.enabled ? Color.primary : Color.secondary)
                        }
                    }
                }
                ForEach(warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill")
                        .font(.dsCaption).foregroundStyle(.dsWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCard()
        }
    }

    private func variantWarnings(malformed: [String], unused: [String], missing: [String]) -> [String] {
        var w: [String] = []
        if !malformed.isEmpty { w.append("Malformed tokens: \(malformed.joined(separator: ", "))") }
        if !unused.isEmpty { w.append("Unused hook output (consumed by no token): \(unused.map { "{{\($0)}}" }.joined(separator: ", "))") }
        if !missing.isEmpty { w.append("Some examples don't provide: \(missing.map { "{{\($0)}}" }.joined(separator: ", "))") }
        return w
    }

    private func hookPortabilityBadge(_ p: Portability) -> some View {
        Text(p.label).font(.dsMicro)
            .padding(.horizontal, DS.Space.xs).padding(.vertical, 1)
            .background((p.isPortable ? Color.dsAccent : Color.dsWarning).opacity(0.18), in: Capsule())
            .foregroundStyle(p.isPortable ? Color.dsAccent : Color.dsWarning)
    }

    private func statusTag(_ status: String) -> some View {
        let color: Color = status == "done" ? .dsSuccess : status == "cancelled" ? .dsWarning : .dsInfo
        return Text(status)
            .font(.dsMicro).fontWeight(.medium)
            .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xxs)
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
    private var meanTTFT: Int? {
        let xs = runs.compactMap(\.ttftMs)
        return xs.isEmpty ? nil : xs.reduce(0, +) / xs.count
    }
    private var meanTokensPerSec: Double? {
        let xs = runs.compactMap(\.tokensPerSec)
        return xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Layout.groupGap) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(experiment.variantLabel).font(.dsTitle)
                Text("\(experiment.task.label) · dataset “\(experiment.datasetName)” · schema \(experiment.schemaID)")
                    .font(.dsCaption).foregroundStyle(.secondary)
            }

            HStack {
                Button(action: runJudge) {
                    HStack(spacing: DS.Space.sm) {
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
                Text(msg).font(.dsCaption).foregroundStyle(.secondary)
            }

            scorecard
            readiness

            DSSectionHeader("Runs")
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
        let cols = [GridItem(.adaptive(minimum: DS.Size.fieldWideWidth), alignment: .leading)]
        return LazyVGrid(columns: cols, alignment: .leading, spacing: DS.Space.sm) {
            stat("Mean score", String(format: "%.1f", stats.meanComposite))
            stat("Decode rate", String(format: "%.0f%%", stats.decodeRate * 100))
            if let l = stats.meanOnTargetLanguage { stat("On-target lang", String(format: "%.2f", l)) }
            stat("p95 context", "\(stats.p95ContextTokens) tok")
            stat("p95 latency", "\(stats.p95LatencyMs) ms")
            if let ref = stats.meanReferenceMatch { stat("Reference match", String(format: "%.2f", ref)) }
            if let ttft = meanTTFT { stat("Mean TTFT", "\(ttft) ms") }
            if let tps = meanTokensPerSec { stat("Mean tok/s", String(format: "%.0f", tps)) }
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
        return VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: golden ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(golden ? AnyShapeStyle(.dsSuccess) : AnyShapeStyle(.secondary))
                Text(golden ? "Golden-ready" : "Not yet golden").font(.dsLabel).fontWeight(.medium)
            }
            ForEach(checks) { c in
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: c.pass ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(c.pass ? AnyShapeStyle(.dsSuccess) : AnyShapeStyle(.dsDanger)).font(.dsCaption)
                    Text(c.name).font(.dsCaption)
                    Spacer()
                    Text(c.detail).font(.dsMicro.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .dsCard()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(label).font(.dsMicro).foregroundStyle(.secondary)
            Text(value).font(.dsBody.monospacedDigit())
        }
    }
}

private struct RunRow: View {
    let run: RunModel
    @Environment(\.modelContext) private var context
    @State private var expanded = false
    @State private var traceExpanded = false

    private var judge: JudgeScore? { JSONCoder.decode(JudgeScore.self, run.judgeJSON) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack {
                Image(systemName: run.decoded ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(run.decoded ? AnyShapeStyle(.dsSuccess) : AnyShapeStyle(.dsDanger))
                Text(run.exampleLabel).font(.dsBody).lineLimit(1)
                Spacer()
                Text(String(format: "%.0f", run.composite)).font(.dsBody.monospacedDigit())
            }
            HStack(spacing: DS.Space.md) {
                Text("ctx \(run.contextTokensEst) (\(run.contextHeadroom) left)")
                Text("\(run.latencyMs) ms")
                if let t = run.ttftMs { Text("ttft \(t)ms") }
                if let tps = run.tokensPerSec { Text(String(format: "%.0f tok/s", tps)) }
                if let l = run.onTargetLanguage { Text(String(format: "lang %.2f", l)) }
                if let r = run.referenceMatch { Text(String(format: "ref %.2f", r)) }
                if let j = judge { Text(String(format: "judge %.1f", j.mean)) }
            }
            .font(.dsMicro.monospacedDigit()).foregroundStyle(.secondary)

            HStack(spacing: DS.Space.sm) {
                Text("Your rating").font(.dsCaption).foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { run.manualRating ?? 0 },
                    set: { run.manualRating = ($0 == 0 ? nil : $0); try? context.save() }
                )) {
                    Text("–").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }

            if let err = run.errorText {
                HStack(alignment: .top, spacing: DS.Space.sm) {
                    if let et = run.metrics?.errorType { errorTag(et) }
                    Text(err).font(.dsCaption).foregroundStyle(.dsDanger).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let j = judge {
                Text("Judge: \(j.rationale)").font(.dsCaption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let trace = run.trace {
                // The same staged pipeline view as Single-shot — replayed from the persisted RunTrace.
                DisclosureGroup("Trace", isExpanded: $traceExpanded) {
                    VStack(alignment: .leading, spacing: DS.Space.sm) {
                        ForEach(trace.stages) { StageCardView($0) }
                    }
                    .padding(.top, DS.Space.xs)
                }
                .font(.dsCaption)
            } else {
                DisclosureGroup("Output", isExpanded: $expanded) {
                    Text(run.turnsJSON ?? run.outputJSON)
                        .font(.dsCode)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dsFlat()
                }
                .font(.dsCaption)
            }
        }
        .dsCard()
    }

    /// Small capsule naming the failure mode (guardrail / unsupportedLanguage / decoding / …).
    private func errorTag(_ type: String) -> some View {
        Text(type)
            .font(.dsMicro).fontWeight(.medium)
            .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xxs)
            .background(Color.dsDanger.opacity(0.18), in: Capsule())
            .foregroundStyle(Color.dsDanger)
    }
}
