//
//  GraphBatchRunner.swift
//  Prompt Playground
//
//  Runs a whole graph over every row of a dataset — the Graph tab's batch lane. It orchestrates the
//  EXISTING single-pass GraphExecutor (one run per row, the row's values injected at the dataset-bound
//  Input node) and persists each row as a RunModel under one ExperimentModel — the same shape a Lab
//  experiment produces, so the result shows in the Lab and feeds VariantStats. Sequential (the on-device
//  model serves one session at a time) and cancellable, mirroring ExperimentRunner.
//

import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class GraphBatchRunner {
    var isRunning = false
    var total = 0
    var completed = 0
    var currentLabel = ""
    private var cancelRequested = false

    var progress: Double { total == 0 ? 0 : Double(completed) / Double(total) }
    func cancel() { cancelRequested = true }

    /// Fan `graph` over every example in `dataset`, one RunModel per row under one ExperimentModel.
    @discardableResult
    func run(graph: GraphDef, dataset: DatasetModel, graphName: String,
             context: ModelContext) async -> ExperimentModel? {
        guard !isRunning else { return nil }
        isRunning = true; cancelRequested = false; completed = 0
        defer { isRunning = false; currentLabel = "" }

        let examples = dataset.examples.sorted { $0.createdAt < $1.createdAt }
        total = examples.count

        let experiment = ExperimentModel(
            task: .custom, label: "\(graphName) · \(dataset.name)",
            templateName: graphName, templateVersion: 1, instructions: "",
            schemaID: "graph", genConfig: GenConfig(), datasetName: dataset.name)
        context.insert(experiment)

        for example in examples {
            if cancelRequested { break }
            currentLabel = example.label

            let data: RunResultData
            do {
                let result = try await GraphExecutor.run(graph, row: example.rowValues)
                data = result.asRunResultData()
            } catch {
                let (type, text) = classify(error)
                data = RunResultData(outputJSON: "", turnsJSON: nil, errorText: text,
                                     metrics: .failure(type, latencyMs: 0))
            }

            var metrics = data.metrics
            if !example.expectedOutput.isEmpty {
                metrics.referenceMatch = ReferenceEvaluator.match(
                    output: data.outputJSON, expected: example.expectedOutput)
            }

            let run = RunModel(exampleLabel: example.label, inputJSON: example.inputJSON,
                               outputJSON: data.outputJSON, turnsJSON: data.turnsJSON,
                               errorText: data.errorText, metrics: metrics, trace: data.trace)
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
