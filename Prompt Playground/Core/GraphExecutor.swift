//
//  GraphExecutor.swift
//  Prompt Playground
//
//  Headless DAG executor for a GraphDef (v2). Topologically sorts the nodes and runs each once.
//  TWO lanes flow along the graph (docs/prd.md §5.2):
//    • the VARIABLE lane — [String:String] per edge (ctx[inputPort] = outputs[fromNode][outputKey]):
//      Input values, native-op/hook results, {{var}} substitution. The templating sidecar.
//    • the CONVERSATION lane — a `TranscriptDef` (Codable mirror of FoundationModels.Transcript,
//      see TranscriptDef.swift): a Prompt group emits the assembled REQUEST (instructions + history
//      + the current turn as the trailing prompt entry, carrying schema + sampling); the FM seeds
//      LanguageModelSession(transcript:) from its leading entries, responds with the trailing
//      prompt, then reads `session.transcript` BACK and emits the full conversation — on the node
//      run (`GraphNodeRun.transcript`), in `RunResult.transcripts`, and as a readable text
//      projection on its `transcript` output port.
//
//  A **Prompt** is a group of member blocks (membership = `groupID`, the SINGLE source of truth — there
//  is no edge-ancestry walk). The executor:
//    • runs each block individually (instruction / history / current / few-shot) so per-node status,
//      the wired-inputs map, and resolved-output previews keep working;
//    • runs an Input node into its variable→value map (edges carry those to block {{vars}});
//    • runs the `.promptGroup` container, which ASSEMBLES its members into the request TranscriptDef;
//    • runs an FM node on its wired Prompt group's request (above).
//  Implicit member→group ordering edges (added in topoSort) guarantee members run before the group, and
//  the real group→FM edge orders the group before the FM. Each FM build is a FRESH
//  LanguageModelSession(transcript:) — never reused (a persistent session would double-count history);
//  seeding is append-only, which is what keeps the KV cache valid on shared paths (PRD §6.1).
//
//  Every model branch is a thin call into shipping logic: Vars.substitute · HookEngine.runOne ·
//  DynamicRun.respond (guided) / LanguageModelSession.respond (free text).
//

import Foundation
import FoundationModels
import os

@MainActor
enum GraphExecutor {

    /// Signposts each node's execution so a user can profile a graph run in Instruments (Points of
    /// Interest / os_signpost) — the workbench's "execution tracing" carried down to the OS profiler.
    /// Disabled signposts compile to no-ops; harmless and identical on iOS.
    private static let signposter = OSSignposter(
        logHandle: OSLog(subsystem: "com.nativex.promptplayground", category: .pointsOfInterest))

    // MARK: Errors

    enum ExecError: LocalizedError {
        case cycle
        case emptyGraph
        case missingPromptGroup(node: String)
        case missingCurrentTurn(node: String)
        case dynamicInputUnsupported(source: String)
        case datasetNeedsBatch(node: String)   // a dataset-bound Input hit on a single (non-batch) run
        case notReady([String])   // pre-run validation (GraphValidator) — aborts before any node runs

        var errorDescription: String? {
            switch self {
            case .cycle:                          return "The graph has a cycle — nodes must form a DAG."
            case .emptyGraph:                     return "The graph is empty."
            case .missingPromptGroup(let n):      return "FM node “\(n)” isn’t fed by a Prompt. Wire a Prompt group’s output into its prompt port."
            case .missingCurrentTurn(let n):      return "Prompt feeding “\(n)” has no current turn. Add a Current-turn block (and an Input to fill it)."
            case .dynamicInputUnsupported(let s): return "Input source “\(s)” isn’t supported yet — use Static or JSON for now."
            case .datasetNeedsBatch(let n):       return "“\(n)” is bound to a dataset — press “Run dataset” to run over its rows (plain Run is single-shot)."
            case .notReady(let msgs):             return msgs.count == 1 ? msgs[0]
                                                       : "This graph isn’t ready to run:\n• " + msgs.joined(separator: "\n• ")
            }
        }
    }

    private struct HookFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Result

    struct RunResult {
        var outputs: [UUID: [String: String]] = [:]
        var transcripts: [UUID: TranscriptDef] = [:]   // the conversation lane, per producing node
        var runs: [UUID: GraphNodeRun] = [:]
        var order: [UUID] = []
        var trace = ExecTrace()        // per-step records for the Run History page
    }

    /// The fully-assembled request a Prompt group feeds to an FM (also the source of the group/FM previews).
    struct AssembledPrompt {
        var instructionsText: String = ""
        var history: [(role: TurnRole, text: String)] = []
        var currentTurn: String = ""
        var guided: SchemaDef? = nil
        var transcriptText: String = ""        // role-labeled preview (system + history)
    }

    // MARK: Entry point

    @discardableResult
    static func run(_ graph: GraphDef, row: [String: String]? = nil,
                    onUpdate: ((GraphNodeRun) -> Void)? = nil) async throws -> RunResult {
        guard !graph.nodes.isEmpty else { throw ExecError.emptyGraph }
        let order = try topoSort(graph)
        // Fail FAST, before any node runs: a long pipeline shouldn't grind through hooks + tokenizers only
        // to die at the final FM node for a missing current turn. Dedup messages (a shared group/block can
        // surface the same problem twice) while preserving order.
        var seen = Set<String>()
        let problems = GraphValidator.issues(in: graph).map(\.message).filter { seen.insert($0).inserted }
        if !problems.isEmpty { throw ExecError.notReady(problems) }
        // A dataset-bound Input is filled only by the batch runner (which passes `row`). On a plain run
        // (row == nil) there's nothing to substitute, so abort up front instead of letting the FM generate
        // on an unsubstituted turn and burn a generation. Batch passes a row, so it sails past this.
        if row == nil, let ds = graph.nodes.first(where: { $0.kind == .input && $0.input?.source == .dataset }) {
            throw ExecError.datasetNeedsBatch(node: ds.title.isEmpty ? ds.kind.label : ds.title)
        }
        var result = RunResult(order: order)
        let execStart = Date()

        for id in order {
            guard let node = graph.node(id) else { continue }
            var run = GraphNodeRun(nodeID: id, status: .running)
            onUpdate?(run)
            let start = Date()
            let spState = signposter.beginInterval("node", id: signposter.makeSignpostID(),
                                                   "\(node.kind.label, privacy: .public) · \(node.apiName ?? "", privacy: .public)")
            do {
                let exec = try await execute(node, graph: graph, outputs: result.outputs,
                                             transcripts: result.transcripts, row: row)
                run.outputs = exec.outputs
                run.transcript = exec.transcript
                run.status = .ok
            } catch {
                run.status = .error
                run.error = error.localizedDescription
            }
            signposter.endInterval("node", spState, "\(run.status == .ok ? "ok" : "error", privacy: .public)")
            run.ms = Int(Date().timeIntervalSince(start) * 1000)
            result.outputs[id] = run.outputs
            if let t = run.transcript { result.transcripts[id] = t }
            result.runs[id] = run
            onUpdate?(run)
            if let step = traceStep(for: node, run: run, graph: graph, outputs: result.outputs) {
                result.trace.steps.append(step)
            }
        }
        result.trace.totalMs = Int(Date().timeIntervalSince(execStart) * 1000)
        result.trace.status = result.trace.steps.allSatisfy(\.ok) ? "ok" : "error"
        return result
    }

    // MARK: Per-node execution

    /// One node's execution result: the variable-lane outputs (per-port strings) plus the
    /// conversation-lane value when the node participates in it (Prompt group / FM).
    private struct NodeExecution {
        var outputs: [String: String]
        var transcript: TranscriptDef? = nil
    }

    private static func execute(_ node: GraphNode, graph: GraphDef,
                                outputs: [UUID: [String: String]],
                                transcripts: [UUID: TranscriptDef],
                                row: [String: String]? = nil) async throws -> NodeExecution {
        var ctx = inputContext(for: node, graph: graph, outputs: outputs)

        switch node.kind {
        case .input:
            let p = node.input ?? InputPayload()
            switch p.source {
            case .staticLiteral: return NodeExecution(outputs: p.statics)
            case .json:          return NodeExecution(outputs: GraphJSON.scalarObject(p.jsonLiteral))
            case .dataset:
                // Batch: GraphBatchRunner injects the current row; emit only this node's declared columns.
                guard let row else { throw ExecError.datasetNeedsBatch(node: node.title.isEmpty ? node.kind.label : node.title) }
                return NodeExecution(outputs: row.filter { node.outputKeys.contains($0.key) })
            default:             throw ExecError.dynamicInputUnsupported(source: p.source.label)
            }

        case .instruction:
            return NodeExecution(outputs: ["text": Vars.substitute(node.instruction?.text ?? "", ctx)])

        case .history:
            return NodeExecution(outputs: ["turn": Vars.substitute(node.history?.content ?? "", ctx)])

        case .current:
            return NodeExecution(outputs: ["currentturn": Vars.substitute(node.current?.template ?? "", ctx)])

        case .fewshot:
            let pairs = (node.fewshot?.shots ?? []).filter { !$0.user.isEmpty || !$0.assistant.isEmpty }
            return NodeExecution(outputs: ["fewshot": pairs.map { "User: \($0.user)\nAssistant: \($0.assistant)" }.joined(separator: "\n\n")])

        case .guided, .tool, .compare:
            return NodeExecution(outputs: [:])   // metadata / reference nodes — no dataflow output (Compare runs via GraphCompareRunner)

        case .nativeAPI, .hook:
            guard let hook = node.hook else { return NodeExecution(outputs: [:]) }
            let step = await HookEngine.runOne(hook, context: &ctx)
            if let err = step.error { throw HookFailure(message: err) }
            let key = hook.outputVar.isEmpty ? "output" : hook.outputVar
            return NodeExecution(outputs: [key: step.output ?? ""])

        case .promptGroup:
            let a = assemble(groupID: node.id, graph: graph, outputs: outputs)
            // The group's conversation-lane output: the REQUEST as a Transcript. Its trailing prompt
            // entry records the guided schema and the sampling label of the FM this group feeds.
            let config = graph.fmID(fedBy: node.id).flatMap { graph.node($0)?.fm?.config }
            return NodeExecution(
                outputs: ["instructions": a.instructionsText, "_currentturn": a.currentTurn, "_transcript": a.transcriptText],
                transcript: transcriptDef(from: a, config: config))

        case .fm:
            return try await runFM(node, graph: graph, outputs: outputs, transcripts: transcripts)
        }
    }

    /// A node's input context: each incoming edge sets ctx[inputPort] = the value on that edge.
    private static func inputContext(for node: GraphNode, graph: GraphDef,
                                     outputs: [UUID: [String: String]]) -> [String: String] {
        var ctx: [String: String] = [:]
        for edge in graph.incoming(node.id) {
            if let value = outputs[edge.fromNodeID]?[edge.outputKey] { ctx[edge.inputPort] = value }
        }
        return ctx
    }

    // MARK: Prompt-group assembly

    /// RESOLVED assembly (runtime): member text comes from run `outputs`; falls back to the raw template
    /// for a member that produced nothing. Blocks have already run (members→group ordering in topoSort).
    static func assemble(groupID: UUID, graph: GraphDef, outputs: [UUID: [String: String]]) -> AssembledPrompt {
        assemble(groupID: groupID, graph: graph) { n in
            if let key = n.blockOutputKey, let v = outputs[n.id]?[key] { return v }
            return rawText(of: n)
        }
    }

    /// TEMPLATE assembly (pre-run): the RAW {{var}} templates in order, so the inspector can show the
    /// full composed prompt — and how multiple instruction blocks concatenate — before any run.
    static func assembleTemplate(groupID: UUID, graph: GraphDef) -> AssembledPrompt {
        assemble(groupID: groupID, graph: graph) { rawText(of: $0) }
    }

    /// A block's raw template text (un-substituted), by kind.
    private static func rawText(of n: GraphNode) -> String {
        switch n.kind {
        case .instruction: return n.instruction?.text ?? ""
        case .history:     return n.history?.content ?? ""
        case .current:     return n.current?.template ?? ""
        default:           return ""
        }
    }

    /// Shared gather. `text` returns each block's contribution (resolved or raw). Block order follows
    /// VISIBLE canvas position (top→bottom): instructions → few-shot pairs → tool descriptions, then the
    /// PAST history turns, then the current turn. What the user sees top-to-bottom is what gets sent.
    private static func assemble(groupID: UUID, graph: GraphDef, text: (GraphNode) -> String) -> AssembledPrompt {
        let members = graph.members(of: groupID)
        var a = AssembledPrompt()

        var parts = members.filter { $0.kind == .instruction }.sorted { $0.y < $1.y }
            .map(text).filter { !$0.isEmpty }

        for fs in members.filter({ $0.kind == .fewshot }).sorted(by: { $0.y < $1.y }) {
            let pairs = (fs.fewshot?.shots ?? []).filter { !$0.user.isEmpty || !$0.assistant.isEmpty }
            if !pairs.isEmpty {
                parts.append("Examples:\n" + pairs.map { "User: \($0.user)\nAssistant: \($0.assistant)" }.joined(separator: "\n\n"))
            }
        }

        let tools = members.compactMap { $0.tool }.filter { !$0.name.isEmpty }
        if !tools.isEmpty {
            let lines = tools.map { "- \($0.name): \($0.toolDescription)" }.joined(separator: "\n")
            parts.append("You have access to the following tools (say when you would use each; you cannot call them directly):\n\(lines)")
        }
        a.instructionsText = parts.joined(separator: "\n\n")

        a.history = members.filter { $0.kind == .history }.sorted { $0.y < $1.y }
            .map { ($0.history?.role ?? .human, text($0)) }

        if let cur = members.first(where: { $0.kind == .current }) { a.currentTurn = text(cur) }
        a.guided = members.first { $0.kind == .guided }?.guided?.schemaDef

        var lines: [String] = []
        if !a.instructionsText.isEmpty { lines.append("SYSTEM: \(a.instructionsText)") }
        lines += a.history.map { "\($0.role.label.uppercased()): \($0.text)" }
        a.transcriptText = lines.joined(separator: "\n\n")
        return a
    }

    // MARK: FM node

    /// Run the model on the wired Prompt group's request `TranscriptDef`. The FM-boundary contract
    /// (TranscriptDef.swift): leading entries seed a FRESH `LanguageModelSession(transcript:)`; the
    /// trailing prompt entry's text is the live `respond(to:)` argument (the framework appends the
    /// prompt + response entries to `session.transcript` itself — seeding the turn would double-send
    /// it). Afterwards the session's transcript is read BACK and emitted as the node's conversation-
    /// lane output, so downstream nodes (and the trace) see the real recorded conversation.
    private static func runFM(_ node: GraphNode, graph: GraphDef,
                              outputs: [UUID: [String: String]],
                              transcripts: [UUID: TranscriptDef]) async throws -> NodeExecution {
        let payload = node.fm ?? FMPayload()
        guard let groupID = graph.promptGroupID(feeding: node.id) else {
            throw ExecError.missingPromptGroup(node: node.title)
        }
        let a = assemble(groupID: groupID, graph: graph, outputs: outputs)
        // The group runs before the FM (topo order), so its emitted request is in `transcripts`;
        // re-assembling is the defensive fallback only.
        let request = transcripts[groupID] ?? transcriptDef(from: a, config: payload.config)
        guard let turn = request.trailingPrompt, !turn.text.isEmpty else {
            throw ExecError.missingCurrentTurn(node: node.title)
        }

        let session = LanguageModelSession(transcript: request.seed.toTranscript())
        let options = payload.config.toOptions()

        var out: [String: String]
        if let def = a.guided {
            let content = try await DynamicRun.respond(session: session, prompt: turn.text, def: def, options: options)
            out = ["output": prettyJSONString(content.jsonString), "json": content.jsonString]
        } else {
            let response = try await session.respond(to: turn.text, options: options)
            out = ["output": response.content]
        }

        // Readback: the framework recorded the prompt entry (with its responseFormat on guided runs)
        // and the response. Stamp the sampling label (+ schema name on the free-text fallback) onto
        // the live prompt entry — GenerationOptions isn't introspectable from a readback.
        var full = TranscriptDef(session.transcript)
        if let i = full.entries.lastIndex(where: { $0.kind == .prompt }) {
            full.entries[i].responseFormatName = full.entries[i].responseFormatName ?? a.guided?.typeName
            full.entries[i].optionsLabel = payload.config.label
        }
        out["transcript"] = full.text
        out["_currentturn"] = turn.text
        out["_transcript"] = a.transcriptText
        return NodeExecution(outputs: out, transcript: full)
    }

    /// AssembledPrompt → the request `TranscriptDef` a Prompt group emits: instructions entry,
    /// history prompt/response entries, then the current turn as the TRAILING prompt entry carrying
    /// the guided schema name and the sampling label in force.
    static func transcriptDef(from a: AssembledPrompt, config: GenConfig?) -> TranscriptDef {
        var entries: [TranscriptDef.Entry] = []
        if !a.instructionsText.isEmpty {
            entries.append(.init(kind: .instructions, segments: [.init(text: a.instructionsText)]))
        }
        for turn in a.history where !turn.text.isEmpty {
            entries.append(.init(kind: turn.role == .human ? .prompt : .response,
                                 segments: [.init(text: turn.text)]))
        }
        if !a.currentTurn.isEmpty {
            var e = TranscriptDef.Entry(kind: .prompt, segments: [.init(text: a.currentTurn)])
            e.responseFormatName = a.guided?.typeName
            e.optionsLabel = config?.label
            entries.append(e)
        }
        return TranscriptDef(entries: entries)
    }

    // MARK: Run-history trace (per-step records)

    /// Build a logged step for the nodes a user inspects in Run History: every FM node becomes an LLM
    /// record (its final prompt re-assembled into instruction/history/current-turn blocks + estimated
    /// tokens + output), and every native-API / hook node becomes a process step (op + resolved input +
    /// output). Assembly/input/block nodes carry no record of their own — their text shows up inside the
    /// LLM record they feed. Pure: re-derives from the run outputs, so the executor stays SwiftData-free.
    private static func traceStep(for node: GraphNode, run: GraphNodeRun, graph: GraphDef,
                                  outputs: [UUID: [String: String]]) -> ExecStep? {
        switch node.kind {
        case .fm:
            let a = graph.promptGroupID(feeding: node.id)
                .map { assemble(groupID: $0, graph: graph, outputs: outputs) } ?? AssembledPrompt()
            let output = run.outputs["output"] ?? ""
            // Token figures from the conversation-lane readback when the run produced one (prompt
            // side = every entry before the generated response); string re-assembly on error runs.
            // Heuristic estimates either way — see TokenEstimator for the 26.4 native-API plan.
            let promptTok: Int
            let outputTok: Int
            if let def = run.transcript, let last = def.entries.last, last.kind == .response {
                promptTok = TranscriptDef(entries: Array(def.entries.dropLast())).estimatedTokens
                outputTok = TokenEstimator.estimate(last.text)
            } else {
                promptTok = TokenEstimator.estimate(a.instructionsText)
                    + a.history.reduce(0) { $0 + TokenEstimator.estimate($1.text) }
                    + TokenEstimator.estimate(a.currentTurn)
                outputTok = TokenEstimator.estimate(output)
            }
            return .llm(id: run.id, title: node.title.isEmpty ? NodeKind.fm.label : node.title,
                        ms: run.ms ?? 0, ok: run.status == .ok, error: run.error,
                        instructions: a.instructionsText,
                        history: a.history.map { TurnLine(role: $0.role.label, text: $0.text) },
                        currentTurn: a.currentTurn, schemaName: a.guided?.typeName,
                        output: run.status == .ok ? output : nil, configLabel: node.fm?.config.label,
                        promptTokens: promptTok, outputTokens: outputTok,
                        transcript: run.transcript)

        case .nativeAPI, .hook:
            guard let hook = node.hook else { return nil }
            let key = hook.outputVar.isEmpty ? "output" : hook.outputVar
            let ctx = inputContext(for: node, graph: graph, outputs: outputs)
            return .process(id: run.id, type: node.kind == .nativeAPI ? "api" : "hook",
                            title: node.title.isEmpty ? hook.op.displayName : node.title,
                            ms: run.ms ?? 0, ok: run.status == .ok, error: run.error,
                            op: hook.op.displayName, input: ctx[hook.inputVar], output: run.outputs[key])

        default:
            return nil
        }
    }

    // MARK: Topological sort

    /// Kahn topological sort. Adds IMPLICIT member→group edges so every block runs before its group
    /// container (and the real group→FM edge then orders the group before the FM). Throws `.cycle`.
    static func topoSort(_ graph: GraphDef) throws -> [UUID] {
        var adjacency: [UUID: [UUID]] = [:]
        var indegree: [UUID: Int] = [:]
        for node in graph.nodes { adjacency[node.id] = []; indegree[node.id] = 0 }

        func link(_ from: UUID, _ to: UUID) {
            guard graph.node(from) != nil, graph.node(to) != nil else { return }
            adjacency[from, default: []].append(to)
            indegree[to, default: 0] += 1
        }

        for edge in graph.edges { link(edge.fromNodeID, edge.toNodeID) }
        for node in graph.nodes {
            if let g = node.groupID, graph.node(g)?.kind == .promptGroup { link(node.id, g) }
        }

        var queue = graph.nodes.map(\.id).filter { indegree[$0] == 0 }
        var order: [UUID] = []
        while !queue.isEmpty {
            let id = queue.removeFirst()
            order.append(id)
            for next in adjacency[id] ?? [] {
                indegree[next, default: 0] -= 1
                if indegree[next] == 0 { queue.append(next) }
            }
        }
        guard order.count == graph.nodes.count else { throw ExecError.cycle }
        return order
    }
}

// MARK: - Bridge: a whole-graph execution → one persistable run
// So batch (GraphBatchRunner) and, later, the Compare runner store a graph run as a RunModel under an
// ExperimentModel — the SAME shape a Lab run produces, so VariantStats / the leaderboard / parity all reuse.

extension GraphExecutor.RunResult {
    /// Collapse this execution into one `RunResultData`: the terminal FM output, metrics scored exactly
    /// like a Lab run (`RunEvaluator`), and the staged trace.
    func asRunResultData() -> RunResultData {
        let llm = trace.steps.last { $0.type == "llm" }
        let firstError = trace.steps.first { !$0.ok }
        guard let llm else {
            return RunResultData(outputJSON: "", turnsJSON: nil, errorText: firstError?.errorReason,
                                 metrics: .failure("generation", latencyMs: trace.totalMs),
                                 trace: trace.asRunTrace())
        }
        let output = llm.output ?? ""
        // instr + history + current turn — mirrors the Run History promptTokens estimate (traceStep),
        // so a batch run's promptTokensEst doesn't under-count vs the same run logged to Run History.
        let historyText = (llm.history ?? []).map(\.text).joined(separator: "\n")
        let resolvedPrompt = [llm.instructions, historyText, llm.currentTurn]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        let json = llm.schemaName != nil ? output : RunPipeline.jsonWrap(output)
        let metrics = llm.ok
            ? RunEvaluator.metrics(json: json, decoded: true, latencyMs: trace.totalMs,
                                   resolvedPrompt: resolvedPrompt, expectedLanguage: "",
                                   context: llm.contextTokens ?? 0)
            : .failure("generation", latencyMs: trace.totalMs)
        return RunResultData(outputJSON: output, turnsJSON: nil,
                             errorText: llm.ok ? nil : llm.errorReason,
                             metrics: metrics, trace: trace.asRunTrace())
    }
}

extension ExecTrace {
    /// Map to the Lab's `RunTrace` so a batch/compare run renders in the per-run staged view (StageCardView).
    func asRunTrace() -> RunTrace {
        RunTrace(stages: steps.map { s in
            let body: String
            if s.type == "llm" {
                body = [s.instructions.map { "INSTRUCTIONS\n\($0)" },
                        s.currentTurn.map { "PROMPT\n\($0)" },
                        s.output.map { "OUTPUT\n\($0)" }].compactMap { $0 }.joined(separator: "\n\n")
            } else {
                body = [s.input.map { "IN\n\($0)" },
                        s.stepOutput.map { "OUT\n\($0)" }].compactMap { $0 }.joined(separator: "\n\n")
            }
            return RunTrace.Stage(kind: s.type == "llm" ? "model" : "preHook", ok: s.ok,
                                  title: s.title, body: body, ms: s.ms, note: s.errorReason)
        })
    }
}
