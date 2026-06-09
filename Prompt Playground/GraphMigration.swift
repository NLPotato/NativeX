//
//  GraphMigration.swift
//  Prompt Playground
//
//  Loads a GraphDef from its stored JSON blob, migrating the legacy v1 node model
//  (message / prompt / fm-with-schema) UP to the current v2 model (promptGroup + typed blocks + Input)
//  BEFORE typed decoding. This exists because the old `JSONCoder.decode(GraphDef.self) ?? GraphDef()`
//  turned ANY decode failure into a silent empty canvas — and removing the `.message`/`.prompt`
//  NodeKind cases makes every legacy blob fail to decode. So a non-empty blob must NEVER come back empty.
//
//  Migration runs at the raw-dictionary layer (JSONSerialization), so it can rewrite node kinds the new
//  enum can't even decode. v1 graphs are best-effort lifted into a single Prompt group; simple shapes
//  (the gloss/chat seeds) round-trip runnably, complex ones may need a wiring review — but nothing is lost.
//
//  NOTE: Swift's synthesized Codable does NOT apply property defaults for missing keys, so every
//  non-optional field of a v2 payload must be present in the dicts this file builds.
//

import Foundation

enum GraphMigrator {
    /// The single entry point used by GraphModel.graphDef. Never returns an empty graph for a non-empty blob.
    static func load(_ json: String) -> GraphDef {
        guard let data = json.data(using: .utf8) else { return GraphDef() }
        guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Not even a JSON object — fall back to a direct decode (covers `{}` / brand-new defaults).
            return (try? JSONDecoder().decode(GraphDef.self, from: data)) ?? GraphDef()
        }
        let version = obj["schemaVersion"] as? Int ?? 1
        if version < GraphDef.currentVersion || containsLegacyKind(obj) {
            obj = migrateV1toV2(obj)
        }
        if let migrated = try? JSONSerialization.data(withJSONObject: obj),
           let def = try? JSONDecoder().decode(GraphDef.self, from: migrated) {
            return def
        }
        // Last resort: a direct decode of the original (a non-legacy v2 blob that JSONSerialization
        // round-tripped oddly). Better than silently emptying.
        return (try? JSONDecoder().decode(GraphDef.self, from: data)) ?? GraphDef()
    }

    private static func containsLegacyKind(_ obj: [String: Any]) -> Bool {
        guard let nodes = obj["nodes"] as? [[String: Any]] else { return false }
        let legacy: Set<String> = ["message", "prompt"]
        return nodes.contains { legacy.contains($0["kind"] as? String ?? "") }
    }

    // MARK: v1 → v2

    private static func migrateV1toV2(_ old: [String: Any]) -> [String: Any] {
        let oldNodes = old["nodes"] as? [[String: Any]] ?? []
        let oldEdges = old["edges"] as? [[String: Any]] ?? []

        let groupID = UUID().uuidString
        var newNodes: [[String: Any]] = []
        var newEdges: [[String: Any]] = []

        // top-left of the existing nodes — place the group frame just above/left of them.
        let xs = oldNodes.compactMap { $0["x"] as? Double }, ys = oldNodes.compactMap { $0["y"] as? Double }
        let minX = xs.min() ?? 60, minY = ys.min() ?? 60

        var inputNodeFor: [String: String] = [:]   // old prompt node id → synthesized Input node id
        var firstStaticVar: [String: String] = [:] // old prompt node id → its first static var (for rewiring)
        var fmIDs: [String] = []
        let promptIDs = Set(oldNodes.filter { ($0["kind"] as? String) == "prompt" }.compactMap { $0["id"] as? String })
        let messageIDs = Set(oldNodes.filter { ($0["kind"] as? String) == "message" }.compactMap { $0["id"] as? String })

        for n in oldNodes {
            let kind = n["kind"] as? String ?? ""
            let id = n["id"] as? String ?? UUID().uuidString
            let x = n["x"] as? Double ?? 0, y = n["y"] as? Double ?? 0
            let title = n["title"] as? String ?? ""
            switch kind {
            case "message":
                let msg = n["message"] as? [String: Any] ?? [:]
                let role = msg["role"] as? String ?? "human"
                let content = msg["content"] as? String ?? ""
                if role == "system" {
                    newNodes.append(node(id: id, kind: "instruction", x: x, y: y,
                                         title: title.isEmpty ? "Instruction" : title, groupID: groupID,
                                         key: "instruction", payload: ["text": content]))
                } else {
                    newNodes.append(node(id: id, kind: "history", x: x, y: y,
                                         title: title.isEmpty ? "History" : title, groupID: groupID,
                                         key: "history",
                                         payload: ["role": role == "ai" ? "ai" : "human", "content": content]))
                }
            case "prompt":
                let p = n["prompt"] as? [String: Any] ?? [:]
                let template = p["template"] as? String ?? "{{input}}"
                let statics = (p["statics"] as? [String: String]) ?? [:]
                newNodes.append(node(id: id, kind: "current", x: x, y: y,
                                     title: title.isEmpty ? "Current turn" : title, groupID: groupID,
                                     key: "current", payload: ["template": template]))
                if !statics.isEmpty {
                    let inID = UUID().uuidString
                    inputNodeFor[id] = inID
                    firstStaticVar[id] = statics.keys.sorted().first
                    newNodes.append(node(id: inID, kind: "input", x: x - 240, y: y,
                                         title: "Input", groupID: nil, key: "input",
                                         payload: ["source": "staticLiteral", "statics": statics, "jsonLiteral": ""]))
                    // wire input → current for every shared variable
                    for key in Vars.keys(in: template) where statics[key] != nil {
                        newEdges.append(edge(from: inID, key: key, to: id, port: key))
                    }
                }
            case "fm":
                let fm = n["fm"] as? [String: Any] ?? [:]
                let config = fm["config"] as? [String: Any] ?? [:]
                fmIDs.append(id)
                newNodes.append(node(id: id, kind: "fm", x: x, y: y,
                                     title: title.isEmpty ? "Foundation Model" : title, groupID: nil,
                                     key: "fm", payload: ["config": config]))
                if (fm["useGuidedGen"] as? Bool ?? false), let schema = fm["schemaDef"] as? [String: Any] {
                    let gID = UUID().uuidString
                    newNodes.append(node(id: gID, kind: "guided", x: x - 240, y: y + 130,
                                         title: "Guided output", groupID: groupID,
                                         key: "guided", payload: ["schemaDef": schema]))
                }
            default:
                newNodes.append(n)   // nativeAPI / hook / anything else — keep verbatim
            }
        }

        for e in oldEdges {
            let from = e["fromNodeID"] as? String ?? ""
            let to = e["toNodeID"] as? String ?? ""
            let port = e["inputPort"] as? String ?? ""
            if fmIDs.contains(to) { continue }                       // old FM ports replaced by the group edge
            if promptIDs.contains(from), let inID = inputNodeFor[from], let v = firstStaticVar[from] {
                newEdges.append(edge(from: inID, key: v, to: to, port: port))   // prompt output → Input value source
                continue
            }
            if messageIDs.contains(from) { continue }                // message→message threading replaced by membership
            newEdges.append(e)                                       // e.g. tokenizer→instruction {{words}} stays valid
        }

        newNodes.append(node(id: groupID, kind: "promptGroup", x: minX - 40, y: minY - 70,
                             title: "Prompt", groupID: nil, key: "group",
                             payload: ["width": 320, "height": 160]))
        for fm in fmIDs { newEdges.append(edge(from: groupID, key: "prompt", to: fm, port: "prompt")) }

        return ["schemaVersion": GraphDef.currentVersion, "nodes": newNodes, "edges": newEdges]
    }

    // MARK: dict builders

    private static func node(id: String, kind: String, x: Double, y: Double, title: String,
                             groupID: String?, key: String, payload: [String: Any]) -> [String: Any] {
        var n: [String: Any] = ["id": id, "kind": kind, "x": x, "y": y, "title": title, key: payload]
        if let g = groupID { n["groupID"] = g }
        return n
    }
    private static func edge(from: String, key: String, to: String, port: String) -> [String: Any] {
        ["id": UUID().uuidString, "fromNodeID": from, "outputKey": key, "toNodeID": to, "inputPort": port]
    }
}
