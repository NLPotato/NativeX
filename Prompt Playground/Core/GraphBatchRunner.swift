//
//  GraphBatchRunner.swift
//  Prompt Playground
//
//  Runs a whole graph over every row of a dataset — the Graph tab's batch lane. It orchestrates the
//  EXISTING single-pass GraphExecutor (one run per row, the row's values injected at the dataset-bound
//  Input node) and persists each row as a RunModel under one ExperimentModel — the same shape a Lab
//  experiment produces, so the result shows in the Lab and feeds VariantStats. Each row is ALSO logged to
//  Run History as one TraceModel (per-row input→output trace). Sequential (the on-device model serves one
//  session at a time) and cancellable, mirroring ExperimentRunner.
//

import Foundation
import SwiftData
import Observation

/// Aggregate of a finished batch run — drives the on-canvas summary card (Phase 5).
struct BatchSummary: Sendable {
    var rows: Int
    var ok: Int
    var errors: Int
    var avgMs: Int
    var decodePct: Double
    var experimentID: UUID
}

@MainActor
@Observable
final class GraphBatchRunner {
    var isRunning = false
    var total = 0
    var completed = 0
    var currentLabel = ""
    var lastSummary: BatchSummary? = nil   // set on completion → drives the on-canvas summary card
    private var cancelRequested = false

    var progress: Double { total == 0 ? 0 : Double(completed) / Double(total) }
    func cancel() { cancelRequested = true }

    /// Fan `graph` over every example in `dataset`, one RunModel per row under one ExperimentModel.
    @discardableResult
    func run(graph: GraphDef, dataset: DatasetModel, graphName: String,
             context: ModelContext) async -> ExperimentModel? {
        guard !isRunning else { return nil }
        isRunning = true; cancelRequested = false; completed = 0; lastSummary = nil
        defer { isRunning = false; currentLabel = "" }

        // Re-resolve the dataset Input's columns from the LIVE dataset. The node's `datasetColumns` is a
        // bind-time snapshot (NodeInspector); a column added/removed since then would leave stale ports and
        // drop the new value from each row (the executor emits only declared columns). Refresh on every run.
        var graph = graph
        let liveColumns = Set(dataset.examples.flatMap { $0.rowValues.keys }).sorted()
        for i in graph.nodes.indices where graph.nodes[i].kind == .input
            && graph.nodes[i].input?.source == .dataset
            && graph.nodes[i].input?.datasetID == dataset.id {
            graph.nodes[i].input?.datasetColumns = liveColumns
        }

        let examples = dataset.examples.sorted { $0.createdAt < $1.createdAt }
        total = examples.count

        let experiment = ExperimentModel(
            task: .custom, label: "\(graphName) · \(dataset.name)",
            templateName: graphName, templateVersion: 1, instructions: "",
            schemaID: "graph", genConfig: GenConfig(), datasetName: dataset.name)
        context.insert(experiment)

        var okCount = 0, errCount = 0, msSum = 0, decodedCount = 0
        for example in examples {
            if cancelRequested { break }
            currentLabel = example.label

            let data: RunResultData
            var rowOK = true
            do {
                let result = try await GraphExecutor.run(graph, row: example.rowValues)
                data = result.asRunResultData()
                // Also log this row to Run History (one TraceModel per row), alongside the Lab experiment —
                // same trace GraphView persists for a single run. Guard on non-empty steps like persistRun.
                if !result.trace.steps.isEmpty {
                    context.insert(TraceModel(result.trace, sourceName: "\(graphName) · \(example.label)"))
                }
            } catch {
                let (type, text) = classify(error)
                data = RunResultData(outputJSON: "", turnsJSON: nil, errorText: text,
                                     metrics: .failure(type, latencyMs: 0))
                rowOK = false
            }
            if rowOK { okCount += 1 } else { errCount += 1 }
            msSum += data.metrics.latencyMs
            if data.metrics.decoded { decodedCount += 1 }

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
        let done = okCount + errCount
        lastSummary = BatchSummary(rows: done, ok: okCount, errors: errCount,
                                   avgMs: done == 0 ? 0 : msSum / done,
                                   decodePct: done == 0 ? 0 : Double(decodedCount) / Double(done),
                                   experimentID: experiment.id)
        return experiment
    }
}
