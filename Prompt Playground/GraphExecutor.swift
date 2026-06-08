//
//  GraphExecutor.swift
//  Prompt Playground
//
//  Headless DAG executor for a GraphDef. Topologically sorts the nodes, runs each once, and threads
//  a [String:String] dataflow along the explicit edges: a node's inputs are assembled from its
//  literal statics plus every incoming edge (ctx[inputPort] = outputs[fromNode][outputKey]).
//
//  Every node branch is a THIN call into logic that already ships:
//    • message / prompt  → Vars.substitute            (PlaygroundCore.swift)
//    • nativeAPI / hook  → HookEngine.runOne          (HookEngine.swift)
//    • fm (free text)    → LanguageModelSession.respond(to:options:)
//    • fm (guided gen)   → DynamicRun.respond          (SchemaBuilder.swift)
//  The FM transcript is built from the message-kind ancestors of the FM node, in topological order —
//  mirroring ChatModel.buildTranscript (ChatPlayground.swift). No persistent session: each FM node
//  creates a fresh LanguageModelSession(transcript:), matching the Chat tab today.
//

import Foundation
import FoundationModels

@MainActor
enum GraphExecutor {

    // MARK: Errors

    enum ExecError: LocalizedError {
        case cycle
        case missingPrompt(node: String)
        case emptyGraph
        case noFMNode

        var errorDescription: String? {
            switch self {
            case .cycle:                 return "The graph has a cycle — nodes must form a DAG."
            case .missingPrompt(let n):  return "FM node “\(n)” has no prompt input. Connect a prompt node (or message) to its prompt port."
            case .emptyGraph:            return "The graph is empty."
            case .noFMNode:              return "The graph has no Foundation Model node to run."
            }
        }
    }

    private struct HookFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: Result

    struct RunResult {
        var outputs: [UUID: [String: String]] = [:]   // per-node output dicts
        var runs: [UUID: GraphNodeRun] = [:]           // per-node status/timing/error
        var order: [UUID] = []                          // topological order executed
    }

    // MARK: Entry point

    /// Execute the whole graph in topological order. `onUpdate` fires when a node starts and again
    /// when it finishes — the canvas uses it to animate per-node status. Throws only on structural
    /// failure (cycle); a per-node failure is captured on that node's GraphNodeRun and does not stop
    /// the run (downstream nodes simply see no value on the failed edge).
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
                run.outputs = try await execute(node, graph: graph, order: order, outputs: result.outputs)
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

    private static func execute(_ node: GraphNode, graph: GraphDef, order: [UUID],
                                outputs: [UUID: [String: String]]) async throws -> [String: String] {
        var ctx = inputContext(for: node, graph: graph, outputs: outputs)

        switch node.kind {
        case .message:
            let p = node.message ?? MessagePayload()
            return ["message": Vars.substitute(p.content, ctx)]

        case .prompt:
            let p = node.prompt ?? PromptPayload()
            var body = Vars.substitute(p.template, ctx)
            let shots = p.fewShots.filter { !$0.user.isEmpty || !$0.assistant.isEmpty }
            if !shots.isEmpty {
                let block = shots.map {
                    "User: \(Vars.substitute($0.user, ctx))\nAssistant: \(Vars.substitute($0.assistant, ctx))"
                }.joined(separator: "\n\n")
                body = body.isEmpty ? block : "\(block)\n\n\(body)"
            }
            return ["prompt": body]

        case .nativeAPI, .hook:
            guard let hook = node.hook else { return [:] }
            let step = await HookEngine.runOne(hook, context: &ctx)
            if let err = step.error { throw HookFailure(message: err) }
            let key = hook.outputVar.isEmpty ? "output" : hook.outputVar
            return [key: step.output ?? ""]

        case .fm:
            return try await runFM(node, graph: graph, order: order, ctx: ctx, outputs: outputs)
        }
    }

    /// Assemble a node's input context: its literal statics first, then each incoming edge overwrites.
    private static func inputContext(for node: GraphNode, graph: GraphDef,
                                     outputs: [UUID: [String: String]]) -> [String: String] {
        var ctx = node.prompt?.statics ?? [:]
        for edge in graph.incoming(node.id) {
            if let value = outputs[edge.fromNodeID]?[edge.outputKey] {
                ctx[edge.inputPort] = value
            }
        }
        return ctx
    }

    // MARK: FM node

    private static func runFM(_ node: GraphNode, graph: GraphDef, order: [UUID],
                              ctx: [String: String], outputs: [UUID: [String: String]]) async throws -> [String: String] {
        let payload = node.fm ?? FMPayload()
        let prompt = ctx["prompt"] ?? ""
        guard !prompt.isEmpty else { throw ExecError.missingPrompt(node: node.title) }

        let transcript = buildTranscript(messageAncestors(of: node, graph: graph, order: order, outputs: outputs))
        let session = LanguageModelSession(transcript: transcript)
        let options = payload.config.toOptions()

        if payload.useGuidedGen, let def = payload.schemaDef {
            let content = try await DynamicRun.respond(session: session, prompt: prompt, def: def, options: options)
            return ["output": prettyJSONString(content.jsonString), "json": content.jsonString]
        } else {
            let response = try await session.respond(to: prompt, options: options)
            return ["output": response.content]
        }
    }

    /// The message-kind ancestors of `node`, in topological order, paired with their RESOLVED content.
    private static func messageAncestors(of node: GraphNode, graph: GraphDef, order: [UUID],
                                         outputs: [UUID: [String: String]]) -> [(MessageRole, String)] {
        let anc = ancestors(of: node.id, in: graph)
        return order
            .filter { anc.contains($0) }
            .compactMap { graph.node($0) }
            .filter { $0.kind == .message }
            .map { n in
                let role = n.message?.role ?? .human
                let text = outputs[n.id]?["message"] ?? Vars.substitute(n.message?.content ?? "", [:])
                return (role, text)
            }
    }

    /// Build the seed Transcript: system messages → Instructions; human/ai → prompt/response entries.
    /// Mirrors ChatModel.buildTranscript (ChatPlayground.swift).
    private static func buildTranscript(_ messages: [(role: MessageRole, text: String)]) -> Transcript {
        var entries: [Transcript.Entry] = []
        let system = messages.filter { $0.role == .system }.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !system.isEmpty {
            entries.append(.instructions(Transcript.Instructions(segments: [.text(.init(content: system))],
                                                                 toolDefinitions: [])))
        }
        for msg in messages where msg.role != .system {
            switch msg.role {
            case .human:  entries.append(.prompt(Transcript.Prompt(segments: [.text(.init(content: msg.text))])))
            case .ai:     entries.append(.response(Transcript.Response(assetIDs: [], segments: [.text(.init(content: msg.text))])))
            case .system: break
            }
        }
        return Transcript(entries: entries)
    }

    // MARK: Graph traversal

    /// Kahn topological sort over the node DAG. Throws `.cycle` if not all nodes can be ordered.
    static func topoSort(_ graph: GraphDef) throws -> [UUID] {
        var adjacency: [UUID: [UUID]] = [:]
        var indegree: [UUID: Int] = [:]
        for node in graph.nodes { adjacency[node.id] = []; indegree[node.id] = 0 }
        for edge in graph.edges where graph.node(edge.fromNodeID) != nil && graph.node(edge.toNodeID) != nil {
            adjacency[edge.fromNodeID, default: []].append(edge.toNodeID)
            indegree[edge.toNodeID, default: 0] += 1
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

    /// All transitive predecessors of `id` (reverse reachability over edges).
    private static func ancestors(of id: UUID, in graph: GraphDef) -> Set<UUID> {
        var predecessors: [UUID: [UUID]] = [:]
        for edge in graph.edges { predecessors[edge.toNodeID, default: []].append(edge.fromNodeID) }
        var seen = Set<UUID>()
        var stack = predecessors[id] ?? []
        while let current = stack.popLast() {
            if seen.insert(current).inserted {
                stack.append(contentsOf: predecessors[current] ?? [])
            }
        }
        return seen
    }
}
