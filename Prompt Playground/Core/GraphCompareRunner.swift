//
//  GraphCompareRunner.swift
//  Prompt Playground
//
//  The Graph tab's A/B lane. A Compare node references N prompt groups (the lanes); this runs them
//  side-by-side on the SAME input and reports their outputs + core metrics. It reuses the existing
//  executor wholesale: ONE GraphExecutor.run executes every FM in the graph, so all lanes' outputs come
//  from a single pass — we just collect each referenced lane's FM output. Results persist as M
//  ExperimentModels under one sweepID (identical to a Lab sweep → the Lab leaderboard + VariantStats
//  reuse them), and an in-memory CompareOutcome drives the side-by-side view.
//

import Foundation
import SwiftData
import Observation

/// One lane's result in a comparison (a referenced prompt group → its FM output + core metrics).
struct CompareLaneResult: Identifiable, Sendable {
    let id: UUID            // the prompt group id
    var title: String
    var output: String
    var ms: Int
    var promptTokens: Int
    var outputTokens: Int
    var ok: Bool
    var error: String?
}

struct CompareOutcome: Sendable {
    var lanes: [CompareLaneResult]
    var sweepID: UUID
}

@MainActor
@Observable
final class GraphCompareRunner {
    var isRunning = false
    var error: String? = nil
    var lastOutcome: CompareOutcome? = nil

    /// Run the referenced prompt-group lanes side-by-side (one graph pass) and persist them as a sweep.
    @discardableResult
    func run(graph: GraphDef, laneGroupIDs: [UUID], graphName: String,
             context: ModelContext) async -> CompareOutcome? {
        guard !isRunning else { return nil }
        isRunning = true; error = nil
        defer { isRunning = false }

        let result: GraphExecutor.RunResult
        do {
            result = try await GraphExecutor.run(graph)
        } catch {
            self.error = error.localizedDescription
            return nil
        }

        let sweepID = UUID()
        var lanes: [CompareLaneResult] = []

        for groupID in laneGroupIDs {
            // Resolve the lane: a prompt group + the FM it feeds (the call that produced the output).
            guard let group = graph.node(groupID), group.kind == .promptGroup,
                  let fmID = graph.edges.first(where: {
                      $0.fromNodeID == groupID && graph.node($0.toNodeID)?.kind == .fm
                  })?.toNodeID
            else { continue }

            let nodeRun = result.runs[fmID]
            let output = result.outputs[fmID]?["output"] ?? ""
            let assembled = GraphExecutor.assemble(groupID: groupID, graph: graph, outputs: result.outputs)
            let title = group.title.isEmpty ? "Lane" : group.title
            let ok = nodeRun?.status == .ok
            let ms = nodeRun?.ms ?? 0

            // Score exactly like a Lab run (RunEvaluator) — same metrics whatever the front-end.
            let resolvedPrompt = assembled.instructionsText + "\n" + assembled.currentTurn
            let json = assembled.guided != nil ? output : RunPipeline.jsonWrap(output)
            let contextTok = TokenEstimator.estimate(resolvedPrompt) + TokenEstimator.estimate(output)
            let metrics = ok
                ? RunEvaluator.metrics(json: json, decoded: true, latencyMs: ms, resolvedPrompt: resolvedPrompt,
                                       expectedLanguage: "", context: contextTok)
                : .failure("generation", latencyMs: ms)

            let trace = RunTrace(stages: [
                .prompt(instructions: assembled.instructionsText, prompt: assembled.currentTurn,
                        schemaInjected: assembled.guided != nil),
                ok ? .model(output: output, ms: ms, ttftMs: nil, tokensPerSec: nil,
                            schemaInjected: assembled.guided != nil)
                   : .modelError(nodeRun?.error ?? "Generation failed", ms: ms)
            ])

            // Persist as a Lab sweep: one experiment per lane, all sharing this sweepID.
            let exp = ExperimentModel(
                task: .custom, label: "\(graphName) · \(title)",
                templateName: title, templateVersion: 1, instructions: assembled.instructionsText,
                schemaID: assembled.guided?.typeName ?? "graph",
                genConfig: graph.node(fmID)?.fm?.config ?? GenConfig(),
                datasetName: "compare", sweepID: sweepID)
            context.insert(exp)
            let run = RunModel(exampleLabel: "shared input", inputJSON: "{}", outputJSON: output,
                               turnsJSON: nil, errorText: ok ? nil : nodeRun?.error,
                               metrics: metrics, trace: trace)
            run.experiment = exp
            context.insert(run)

            lanes.append(CompareLaneResult(
                id: groupID, title: title, output: output, ms: ms,
                promptTokens: metrics.promptTokensEst, outputTokens: metrics.outputTokensEst,
                ok: ok, error: ok ? nil : nodeRun?.error))
        }

        try? context.save()
        let outcome = CompareOutcome(lanes: lanes, sweepID: sweepID)
        lastOutcome = outcome
        return outcome
    }
}
