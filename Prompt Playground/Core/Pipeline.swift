//
//  Pipeline.swift
//  Prompt Playground
//
//  ExperimentRunner: fans one Variant (template version × schema × GenConfig) over every
//  Example in a Dataset, persisting each result as a RunModel under one ExperimentModel.
//  Runs sequentially — the on-device model serves one session at a time — and is cancellable,
//  with live progress for the UI.
//

import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class ExperimentRunner {
    var isRunning = false
    var total = 0
    var completed = 0
    var currentLabel = ""
    var sweepTotal = 0          // variants in the active sweep (0 = single run)
    var sweepCompleted = 0
    private var cancelRequested = false

    var progress: Double { total == 0 ? 0 : Double(completed) / Double(total) }
    var isSweep: Bool { sweepTotal > 0 }

    func cancel() { cancelRequested = true }

    /// Run a single variant (template × schema × config) over every example in the dataset.
    @discardableResult
    func run(task: TaskKind, template: PromptTemplateModel, config: GenConfig, schemaID: String,
             schemaDef: SchemaDef? = nil, dataset: DatasetModel, context: ModelContext,
             prewarm: Bool = false) async -> ExperimentModel? {
        guard !isRunning else { return nil }
        isRunning = true; cancelRequested = false; sweepTotal = 0; sweepCompleted = 0
        defer { isRunning = false; currentLabel = "" }
        return await execute(task: task, template: template, config: config, schemaID: schemaID,
                             schemaDef: schemaDef, dataset: dataset, context: context,
                             prewarm: prewarm, sweepID: nil)
    }

    /// Fan a set of variants over the SAME dataset, grouped under one sweepID for side-by-side
    /// comparison. Sequential (the on-device model serves one session at a time); cancellable.
    @discardableResult
    func runSweep(variants: [Variant], task: TaskKind, dataset: DatasetModel, context: ModelContext,
                  prewarm: Bool = false) async -> [ExperimentModel] {
        guard !isRunning, !variants.isEmpty else { return [] }
        isRunning = true; cancelRequested = false
        sweepTotal = variants.count; sweepCompleted = 0
        defer { isRunning = false; currentLabel = ""; sweepTotal = 0; sweepCompleted = 0 }
        let sweepID = UUID()
        var out: [ExperimentModel] = []
        for v in variants {
            if cancelRequested { break }
            let exp = await execute(task: task, template: v.template, config: v.config, schemaID: v.schemaID,
                                    schemaDef: v.schemaDef, dataset: dataset, context: context,
                                    prewarm: prewarm, sweepID: sweepID)
            out.append(exp)
            sweepCompleted += 1
        }
        return out
    }

    @discardableResult
    private func execute(task: TaskKind, template: PromptTemplateModel, config: GenConfig, schemaID: String,
                         schemaDef: SchemaDef?, dataset: DatasetModel, context: ModelContext,
                         prewarm: Bool, sweepID: UUID?) async -> ExperimentModel {
        completed = 0
        let examples = dataset.examples.sorted { $0.createdAt < $1.createdAt }
        total = examples.count

        let hooks = template.hooks
        let experiment = ExperimentModel(
            task: task, label: "\(template.name) v\(template.version) · \(dataset.name)",
            templateName: template.name, templateVersion: template.version,
            instructions: template.instructions, schemaID: schemaID, genConfig: config,
            datasetName: dataset.name, hooks: hooks, sweepID: sweepID, prewarmed: prewarm)
        context.insert(experiment)

        for example in examples {
            if cancelRequested { break }
            currentLabel = example.label

            let result: RunResultData
            switch (task, schemaDef) {
            case (.gloss, nil):
                guard let input = example.glossInput else { completed += 1; continue }
                result = await GlossRunner.run(template: template.instructions, input: input, config: config)
            case (.roleplay, nil):
                guard let input = example.roleplayInput else { completed += 1; continue }
                result = await RoleplayRunner.run(template: template.instructions, input: input, config: config)
            case (.generic, nil):
                guard let input = example.genericInput else { completed += 1; continue }
                result = await GenericRunner.run(template: template.instructions, input: input, config: config, hooks: hooks, prewarm: prewarm)
            case (.gloss, let def?):
                guard let input = example.glossInput else { completed += 1; continue }
                result = await DynamicRunner.runGloss(template: template.instructions, input: input, def: def, config: config)
            case (.roleplay, let def?):
                guard let input = example.roleplayInput else { completed += 1; continue }
                result = await DynamicRunner.runRoleplay(template: template.instructions, input: input, def: def, config: config)
            case (.generic, let def?):
                guard let input = example.genericInput else { completed += 1; continue }
                result = await DynamicRunner.runGeneric(template: template.instructions, input: input, def: def, config: config, hooks: hooks, prewarm: prewarm)
            }

            // Reference-based eval: score against the example's expected output when one is provided.
            var metrics = result.metrics
            if !example.expectedOutput.isEmpty {
                metrics.referenceMatch = ReferenceEvaluator.match(
                    output: result.turnsJSON ?? result.outputJSON, expected: example.expectedOutput)
            }

            let run = RunModel(exampleLabel: example.label, inputJSON: example.inputJSON,
                               outputJSON: result.outputJSON, turnsJSON: result.turnsJSON,
                               errorText: result.errorText, metrics: metrics, trace: result.trace)
            run.experiment = experiment
            context.insert(run)
            completed += 1
            try? context.save()
        }

        experiment.status = cancelRequested ? "cancelled" : "done"
        try? context.save()
        return experiment
    }
}

/// One point in a sweep: a template × schema × generation config to fan over the dataset.
struct Variant: Identifiable {
    let id = UUID()
    let template: PromptTemplateModel
    let schemaDef: SchemaDef?
    let schemaID: String
    let config: GenConfig
}
