//
//  GraphCompareRunner.swift
//  Prompt Playground
//
//  The Graph tab's A/B lane. A Compare node references N prompt groups (the lanes); this runs them
//  side-by-side and reports their outputs + core metrics. It reuses the existing executor wholesale:
//  ONE GraphExecutor.run executes every FM in the graph, so all lanes' outputs come from a single pass —
//  we just collect each referenced lane's terminal FM output.
//
//  Two modes, one code path:
//   • single input  (dataset == nil) — one pass on the graph's static input → one RunModel per lane.
//   • over a dataset (dataset != nil, PHASE 3) — fan the SAME graph over every row → N RunModels per lane.
//  Either way each lane persists as one ExperimentModel; all share a sweepID (identical to a Lab sweep →
//  the Lab leaderboard + VariantStats rank the lanes). Each row is also logged once to Run History.
//
//  A lane's cost sums its WHOLE FM chain, not just the terminal call: a "consecutive" lane (extract →
//  elaborate, 2 FMs in series) counts both, so a 1-call lane and a 2-call lane compare honestly.
//

import Foundation
import SwiftData
import Observation

/// One lane's result for the side-by-side view. In dataset mode the metric fields are per-lane means and
/// `output` is the first row's output (a sample); `rowCount`/`decodeRate` summarize the batch.
struct CompareLaneResult: Identifiable, Sendable {
    let id: UUID            // the prompt group id
    var title: String
    var output: String
    var ms: Int
    var promptTokens: Int
    var outputTokens: Int
    var ok: Bool
    var error: String?
    var rowCount: Int = 1
    var decodeRate: Double = 1
}

struct CompareOutcome: Sendable {
    var lanes: [CompareLaneResult]
    var sweepID: UUID
    var skipped: [String] = []     // selected lanes with no FM wired — reported, never silently dropped
    var datasetName: String? = nil // non-nil ⇒ dataset (Phase 3) mode; drives the result-view summary
    var rows: Int = 1
}

@MainActor
@Observable
final class GraphCompareRunner {
    var isRunning = false
    var error: String? = nil
    var lastOutcome: CompareOutcome? = nil
    var total = 0
    var completed = 0
    private var cancelRequested = false

    func cancel() { cancelRequested = true }

    /// A lane resolved to the graph nodes it needs: its prompt group, the FM that group feeds (the call
    /// whose output IS the lane's answer), and every FM in that FM's upstream chain (for summed cost).
    private struct LaneSpec { let groupID: UUID; let title: String; let terminalFM: UUID; let chainFMs: [UUID] }

    /// One (lane, row) outcome: scored metrics + the terminal output + the prompt that produced it.
    private struct LaneRow {
        var metrics: RunMetrics; var output: String; var ok: Bool; var error: String?
        var instructions: String; var currentTurn: String; var guided: Bool
    }

    /// Run the referenced prompt-group lanes and persist them as a sweep. `dataset == nil` ⇒ one pass on
    /// the graph's static input; `dataset != nil` ⇒ fan over every row (Phase 3).
    @discardableResult
    func run(graph: GraphDef, laneGroupIDs: [UUID], graphName: String,
             dataset: DatasetModel? = nil, context: ModelContext) async -> CompareOutcome? {
        guard !isRunning else { return nil }
        isRunning = true; error = nil; cancelRequested = false; completed = 0
        defer { isRunning = false }

        // Re-resolve the dataset Input's columns from the LIVE dataset (a bind-time snapshot can go stale —
        // see GraphBatchRunner). Mutates a local copy.
        var graph = graph
        if let dataset {
            let liveColumns = Set(dataset.examples.flatMap { $0.rowValues.keys }).sorted()
            for i in graph.nodes.indices where graph.nodes[i].kind == .input
                && graph.nodes[i].input?.source == .dataset
                && graph.nodes[i].input?.datasetID == dataset.id {
                graph.nodes[i].input?.datasetColumns = liveColumns
            }
        }

        // Resolve the lanes once (graph topology is row-independent).
        let sweepID = UUID()
        var laneSpecs: [LaneSpec] = []
        var skipped: [String] = []
        for groupID in laneGroupIDs {
            guard let group = graph.node(groupID), group.kind == .promptGroup else { continue }
            let title = group.title.isEmpty ? "Lane" : group.title
            guard let fmID = graph.fmID(fedBy: groupID) else { skipped.append(title); continue }
            laneSpecs.append(LaneSpec(groupID: groupID, title: title, terminalFM: fmID,
                                      chainFMs: Self.chainFMIDs(terminalFM: fmID, graph: graph)))
        }

        // One experiment per lane (all sharing the sweepID → the Lab leaderboard ranks them).
        var experiments: [UUID: ExperimentModel] = [:]
        for spec in laneSpecs {
            let exp = ExperimentModel(
                task: .custom, label: "\(graphName) · \(spec.title)",
                templateName: spec.title, templateVersion: 1, instructions: "",
                schemaID: "graph", genConfig: graph.node(spec.terminalFM)?.fm?.config ?? GenConfig(),
                datasetName: dataset?.name ?? "compare", sweepID: sweepID)
            context.insert(exp)
            experiments[spec.groupID] = exp
        }

        // The rows to fan over: the dataset's examples, or a single pseudo-row (nil) for the static input.
        let examples = dataset.map { $0.examples.sorted { $0.createdAt < $1.createdAt } }
        let rowCount = examples?.count ?? 1
        total = rowCount

        var acc: [UUID: [LaneRow]] = [:]   // groupID → per-row results, for the in-memory summary
        for rowIndex in 0..<rowCount {
            if cancelRequested { break }
            let example = examples?[rowIndex]

            let result: GraphExecutor.RunResult
            do {
                result = try await GraphExecutor.run(graph, row: example?.rowValues)
            } catch {
                // A throw is structural (validation / topology) → it fails every row identically. Abort, and
                // if nothing landed yet, drop the empty experiments so the Lab isn't littered.
                self.error = error.localizedDescription
                if completed == 0 { experiments.values.forEach(context.delete); try? context.save(); return nil }
                break
            }

            // One Run History trace per row — it covers every lane's FM in this pass.
            if !result.trace.steps.isEmpty {
                let suffix = example.map { " · \($0.label)" } ?? ""
                context.insert(TraceModel(result.trace, sourceName: "\(graphName)\(suffix) · compare"))
            }

            let label = example?.label ?? "shared input"
            let inputJSON = example?.inputJSON ?? "{}"
            for spec in laneSpecs {
                let lr = Self.laneRow(spec: spec, result: result, graph: graph)
                let trace = RunTrace(stages: [
                    .prompt(instructions: lr.instructions, prompt: lr.currentTurn, schemaInjected: lr.guided),
                    lr.ok ? .model(output: lr.output, ms: lr.metrics.latencyMs, ttftMs: nil,
                                   tokensPerSec: nil, schemaInjected: lr.guided)
                          : .modelError(lr.error ?? "Generation failed", ms: lr.metrics.latencyMs)
                ])
                let run = RunModel(exampleLabel: label, inputJSON: inputJSON, outputJSON: lr.output,
                                   turnsJSON: nil, errorText: lr.error, metrics: lr.metrics, trace: trace)
                run.experiment = experiments[spec.groupID]
                context.insert(run)
                acc[spec.groupID, default: []].append(lr)
            }
            completed += 1
            try? context.save()
        }

        for exp in experiments.values { exp.status = cancelRequested ? "cancelled" : "done" }
        try? context.save()

        // Collapse to the side-by-side summary (means in dataset mode; the single row in static mode).
        var lanes: [CompareLaneResult] = []
        for spec in laneSpecs {
            let rows = acc[spec.groupID] ?? []
            let n = rows.count
            func mean(_ xs: [Int]) -> Int { n == 0 ? 0 : xs.reduce(0, +) / n }
            let decodeRate = n == 0 ? 0 : Double(rows.filter(\.ok).count) / Double(n)
            lanes.append(CompareLaneResult(
                id: spec.groupID, title: spec.title,
                output: rows.first?.output ?? "", ms: mean(rows.map(\.metrics.latencyMs)),
                promptTokens: mean(rows.map(\.metrics.promptTokensEst)),
                outputTokens: mean(rows.map(\.metrics.outputTokensEst)),
                ok: decodeRate > 0, error: rows.first?.error,
                rowCount: n, decodeRate: decodeRate))
        }

        let outcome = CompareOutcome(lanes: lanes, sweepID: sweepID, skipped: skipped,
                                     datasetName: dataset?.name, rows: rowCount)
        lastOutcome = outcome
        return outcome
    }

    // MARK: Lane scoring

    /// Score one (lane, row): the terminal output drives decode/quality; latency + tokens sum the whole
    /// FM chain (terminal + every upstream FM) so a multi-step lane reports its true cost.
    private static func laneRow(spec: LaneSpec, result: GraphExecutor.RunResult, graph: GraphDef) -> LaneRow {
        let term = GraphExecutor.assemble(groupID: spec.groupID, graph: graph, outputs: result.outputs)
        let guided = term.guided != nil
        let terminalRun = result.runs[spec.terminalFM]
        let output = result.outputs[spec.terminalFM]?["output"] ?? ""
        let ok = terminalRun?.status == .ok

        var chainMs = 0, chainPromptTok = 0, chainOutTok = 0
        var promptParts: [String] = []
        for fm in spec.chainFMs {
            chainMs += result.runs[fm]?.ms ?? 0
            if let g = graph.promptGroupID(feeding: fm) {
                let a = GraphExecutor.assemble(groupID: g, graph: graph, outputs: result.outputs)
                let text = [a.instructionsText, a.history.map(\.text).joined(separator: "\n"), a.currentTurn]
                    .filter { !$0.isEmpty }.joined(separator: "\n")
                promptParts.append(text); chainPromptTok += TokenEstimator.estimate(text)
            }
            chainOutTok += TokenEstimator.estimate(result.outputs[fm]?["output"] ?? "")
        }
        let json = guided ? output : RunPipeline.jsonWrap(output)
        let metrics = ok
            ? RunEvaluator.metrics(json: json, decoded: true, latencyMs: chainMs,
                                   resolvedPrompt: promptParts.joined(separator: "\n\n"),
                                   expectedLanguage: "", context: chainPromptTok + chainOutTok)
            : .failure("generation", latencyMs: chainMs)
        return LaneRow(metrics: metrics, output: output, ok: ok, error: ok ? nil : terminalRun?.error,
                       instructions: term.instructionsText, currentTurn: term.currentTurn, guided: guided)
    }

    /// The terminal FM plus every FM upstream of it — backward reachability over the dependency graph
    /// (producer→consumer edges + implicit member→group), the same topology topoSort uses. Lets a lane's
    /// cost include earlier calls (e.g. the word-extraction FM that feeds the elaboration FM).
    private static func chainFMIDs(terminalFM: UUID, graph: GraphDef) -> [UUID] {
        var rev: [UUID: [UUID]] = [:]
        for e in graph.edges { rev[e.toNodeID, default: []].append(e.fromNodeID) }
        for n in graph.nodes where n.groupID != nil && graph.node(n.groupID!)?.kind == .promptGroup {
            rev[n.groupID!, default: []].append(n.id)
        }
        var seen: Set<UUID> = [terminalFM]
        var queue = [terminalFM]
        while let id = queue.popLast() {
            for p in rev[id] ?? [] where seen.insert(p).inserted { queue.append(p) }
        }
        return graph.nodes.filter { $0.kind == .fm && seen.contains($0.id) }.map(\.id)
    }
}
