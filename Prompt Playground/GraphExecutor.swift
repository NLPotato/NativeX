//
//  GraphExecutor.swift
//  Prompt Playground
//
//  Headless DAG executor for a GraphDef (v2). Topologically sorts the nodes, runs each once, and threads
//  a [String:String] dataflow along the explicit edges: a node's inputs come from every incoming edge
//  (ctx[inputPort] = outputs[fromNode][outputKey]).
//
//  A **Prompt** is a group of member blocks (membership = `groupID`, the SINGLE source of truth — there
//  is no edge-ancestry walk). The executor:
//    • runs each block individually (instruction / history / current / few-shot) so per-node status,
//      the wired-inputs map, and resolved-output previews keep working;
//    • runs an Input node into its variable→value map (edges carry those to block {{vars}});
//    • runs the `.promptGroup` container, which ASSEMBLES its members into a preview;
//    • runs an FM node by finding its wired Prompt group, assembling instructions + history + current
//      turn + guided schema + tools, and calling the model.
//  Implicit member→group ordering edges (added in topoSort) guarantee members run before the group, and
//  the real group→FM edge orders the group before the FM. Each FM build is a FRESH
//  LanguageModelSession(transcript:) — never reused (a persistent session would double-count history).
//
//  Every model branch is a thin call into shipping logic: Vars.substitute · HookEngine.runOne ·
//  DynamicRun.respond (guided) / LanguageModelSession.respond (free text).
//

import Foundation
import FoundationModels

@MainActor
enum GraphExecutor {

    // MARK: Errors

    enum ExecError: LocalizedError {
        case cycle
        case emptyGraph
        case missingPromptGroup(node: String)
        case missingCurrentTurn(node: String)
        case dynamicInputUnsupported(source: String)

        var errorDescription: String? {
            switch self {
            case .cycle:                          return "The graph has a cycle — nodes must form a DAG."
            case .emptyGraph:                     return "The graph is empty."
            case .missingPromptGroup(let n):      return "FM node “\(n)” isn’t fed by a Prompt. Wire a Prompt group’s output into its prompt port."
            case .missingCurrentTurn(let n):      return "Prompt feeding “\(n)” has no current turn. Add a Current-turn block (and an Input to fill it)."
            case .dynamicInputUnsupported(let s): return "Input source “\(s)” isn’t supported yet — use Static or JSON for now."
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
        var runs: [UUID: GraphNodeRun] = [:]
        var order: [UUID] = []
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
    static func run(_ graph: GraphDef, onUpdate: ((GraphNodeRun) -> Void)? = nil) async throws -> RunResult {
        guard !graph.nodes.isEmpty else { throw ExecError.emptyGraph }
        let order = try topoSort(graph)
        var result = RunResult(order: order)

        for id in order {
            guard let node = graph.node(id) else { continue }
            var run = GraphNodeRun(nodeID: id, status: .running)
            onUpdate?(run)
            let start = Date()
            do {
                run.outputs = try await execute(node, graph: graph, outputs: result.outputs)
                run.status = .ok
            } catch {
                run.status = .error
                run.error = error.localizedDescription
            }
            run.ms = Int(Date().timeIntervalSince(start) * 1000)
            result.outputs[id] = run.outputs
            result.runs[id] = run
            onUpdate?(run)
        }
        return result
    }

    // MARK: Per-node execution

    private static func execute(_ node: GraphNode, graph: GraphDef,
                                outputs: [UUID: [String: String]]) async throws -> [String: String] {
        var ctx = inputContext(for: node, graph: graph, outputs: outputs)

        switch node.kind {
        case .input:
            let p = node.input ?? InputPayload()
            switch p.source {
            case .staticLiteral: return p.statics
            case .json:          return GraphJSON.scalarObject(p.jsonLiteral)
            default:             throw ExecError.dynamicInputUnsupported(source: p.source.label)
            }

        case .instruction:
            return ["text": Vars.substitute(node.instruction?.text ?? "", ctx)]

        case .history:
            return ["turn": Vars.substitute(node.history?.content ?? "", ctx)]

        case .current:
            return ["currentturn": Vars.substitute(node.current?.template ?? "", ctx)]

        case .fewshot:
            let pairs = (node.fewshot?.shots ?? []).filter { !$0.user.isEmpty || !$0.assistant.isEmpty }
            return ["fewshot": pairs.map { "User: \($0.user)\nAssistant: \($0.assistant)" }.joined(separator: "\n\n")]

        case .guided, .tool:
            return [:]   // metadata blocks — no dataflow output; assembled directly from the payload

        case .nativeAPI, .hook:
            guard let hook = node.hook else { return [:] }
            let step = await HookEngine.runOne(hook, context: &ctx)
            if let err = step.error { throw HookFailure(message: err) }
            let key = hook.outputVar.isEmpty ? "output" : hook.outputVar
            return [key: step.output ?? ""]

        case .promptGroup:
            let a = assemble(groupID: node.id, graph: graph, outputs: outputs)
            return ["instructions": a.instructionsText, "_currentturn": a.currentTurn, "_transcript": a.transcriptText]

        case .fm:
            return try await runFM(node, graph: graph, outputs: outputs)
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

    /// Gather a group's resolved member outputs into one request spec. Blocks have already run (members →
    /// group ordering is enforced in topoSort), so values come from `outputs`; the `?? substitute(...)`
    /// fallback covers a member that produced nothing (e.g. empty template).
    static func assemble(groupID: UUID, graph: GraphDef, outputs: [UUID: [String: String]]) -> AssembledPrompt {
        let members = graph.members(of: groupID)
        var a = AssembledPrompt()

        // Block order follows VISIBLE canvas position (top→bottom) — what the user sees is what is sent.
        // Instructions: instruction blocks → few-shot pairs → tool descriptions, all as text.
        var parts = members.filter { $0.kind == .instruction }
            .sorted { $0.y < $1.y }
            .map { outputs[$0.id]?["text"] ?? Vars.substitute($0.instruction?.text ?? "", [:]) }
            .filter { !$0.isEmpty }

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

        // History: PAST turns, top→bottom.
        a.history = members.filter { $0.kind == .history }
            .sorted { $0.y < $1.y }
            .map { n in
                let role = n.history?.role ?? .human
                let text = outputs[n.id]?["turn"] ?? Vars.substitute(n.history?.content ?? "", [:])
                return (role, text)
            }

        // Current turn (the live `respond(to:)` prompt) + guided schema.
        if let cur = members.first(where: { $0.kind == .current }) {
            a.currentTurn = outputs[cur.id]?["currentturn"] ?? Vars.substitute(cur.current?.template ?? "", [:])
        }
        a.guided = members.first { $0.kind == .guided }?.guided?.schemaDef

        var lines: [String] = []
        if !a.instructionsText.isEmpty { lines.append("SYSTEM: \(a.instructionsText)") }
        lines += a.history.map { "\($0.role.label.uppercased()): \($0.text)" }
        a.transcriptText = lines.joined(separator: "\n\n")
        return a
    }

    // MARK: FM node

    private static func runFM(_ node: GraphNode, graph: GraphDef,
                              outputs: [UUID: [String: String]]) async throws -> [String: String] {
        let payload = node.fm ?? FMPayload()
        guard let groupID = graph.promptGroupID(feeding: node.id) else {
            throw ExecError.missingPromptGroup(node: node.title)
        }
        let a = assemble(groupID: groupID, graph: graph, outputs: outputs)
        guard !a.currentTurn.isEmpty else { throw ExecError.missingCurrentTurn(node: node.title) }

        let session = LanguageModelSession(transcript: buildTranscript(instructions: a.instructionsText, history: a.history))
        let options = payload.config.toOptions()

        if let def = a.guided {
            let content = try await DynamicRun.respond(session: session, prompt: a.currentTurn, def: def, options: options)
            return ["output": prettyJSONString(content.jsonString), "json": content.jsonString,
                    "_currentturn": a.currentTurn, "_transcript": a.transcriptText]
        } else {
            let response = try await session.respond(to: a.currentTurn, options: options)
            return ["output": response.content, "_currentturn": a.currentTurn, "_transcript": a.transcriptText]
        }
    }

    /// Seed Transcript: instructions → Instructions entry; history human/ai → prompt/response entries.
    /// The current turn is NOT here — it is the live `respond(to:)` argument.
    private static func buildTranscript(instructions: String, history: [(role: TurnRole, text: String)]) -> Transcript {
        var entries: [Transcript.Entry] = []
        if !instructions.isEmpty {
            entries.append(.instructions(Transcript.Instructions(segments: [.text(.init(content: instructions))],
                                                                 toolDefinitions: [])))
        }
        for turn in history where !turn.text.isEmpty {
            switch turn.role {
            case .human: entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: turn.text))])))
            case .ai:    entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: turn.text))])))
            }
        }
        return Transcript(entries: entries)
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
