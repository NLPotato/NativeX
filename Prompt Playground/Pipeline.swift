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
    private var cancelRequested = false

    var progress: Double { total == 0 ? 0 : Double(completed) / Double(total) }

    func cancel() { cancelRequested = true }

    @discardableResult
    func run(task: TaskKind, template: PromptTemplateModel, config: GenConfig, schemaID: String,
             schemaDef: SchemaDef? = nil, dataset: DatasetModel, context: ModelContext) async -> ExperimentModel? {
        guard !isRunning else { return nil }
        isRunning = true
        cancelRequested = false
        completed = 0
        defer { isRunning = false; currentLabel = "" }

        let examples = dataset.examples.sorted { $0.createdAt < $1.createdAt }
        total = examples.count

        let hooks = template.hooks
        let experiment = ExperimentModel(
            task: task, label: "\(template.name) v\(template.version) · \(dataset.name)",
            templateName: template.name, templateVersion: template.version,
            instructions: template.instructions, schemaID: schemaID, genConfig: config,
            datasetName: dataset.name, hooks: hooks)
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
                result = await GenericRunner.run(template: template.instructions, input: input, config: config, hooks: hooks)
            case (.gloss, let def?):
                guard let input = example.glossInput else { completed += 1; continue }
                result = await DynamicRunner.runGloss(template: template.instructions, input: input, def: def, config: config)
            case (.roleplay, let def?):
                guard let input = example.roleplayInput else { completed += 1; continue }
                result = await DynamicRunner.runRoleplay(template: template.instructions, input: input, def: def, config: config)
            case (.generic, let def?):
                guard let input = example.genericInput else { completed += 1; continue }
                result = await DynamicRunner.runGeneric(template: template.instructions, input: input, def: def, config: config, hooks: hooks)
            }

            let run = RunModel(exampleLabel: example.label, inputJSON: example.inputJSON,
                               outputJSON: result.outputJSON, turnsJSON: result.turnsJSON,
                               errorText: result.errorText, metrics: result.metrics)
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
