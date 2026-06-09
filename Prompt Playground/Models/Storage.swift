//
//  Storage.swift
//  Prompt Playground
//
//  Local LLMOps store (SwiftData). LangSmith-style entities: versioned prompt templates,
//  datasets of examples, and experiments that fan a Variant over a dataset into runs. Each
//  Run keeps the full output + metric bundle as JSON plus first-class sortable columns
//  (decoded / composite / latency / tokens) so leaderboards and headroom checks are cheap.
//

import Foundation
import SwiftData

// MARK: - Example inputs (Codable; stored as JSON on ExampleModel / RunModel)

/// A generic run's example input: a free user message plus the `{{name}}` variable bindings the
/// prompt and any pre-hooks consume. Built-in test tasks (Gloss, Roleplay) define their own Input
/// shapes under their namespaces (Tasks/).
struct RunInput: Codable, Equatable, Sendable {
    var input: String
    var variables: [String: String]
}

enum JSONCoder {
    static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
    static func decode<T: Decodable>(_ type: T.Type, _ json: String?) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Prompt templates (versioned)

@Model
final class PromptTemplateModel {
    var id: UUID
    var createdAt: Date
    var taskRaw: String
    var name: String
    var version: Int
    var instructions: String
    var notes: String
    var genConfigJSON: String = "{}"     // GenConfig captured at save time (seeds pipeline runs)
    var hooksJSON: String = "{}"         // HookPipelineDef captured at save time (replayed in the Lab)

    var task: TaskKind { TaskKind(rawValue: taskRaw) ?? .gloss }
    var genConfig: GenConfig { JSONCoder.decode(GenConfig.self, genConfigJSON) ?? GenConfig() }
    var hooks: HookPipelineDef { JSONCoder.decode(HookPipelineDef.self, hooksJSON) ?? .empty }

    init(task: TaskKind, name: String, version: Int = 1, instructions: String, notes: String = "",
         genConfig: GenConfig = GenConfig(), hooks: HookPipelineDef = .empty) {
        self.id = UUID()
        self.createdAt = Date()
        self.taskRaw = task.rawValue
        self.name = name
        self.version = version
        self.instructions = instructions
        self.notes = notes
        self.genConfigJSON = JSONCoder.encode(genConfig)
        self.hooksJSON = JSONCoder.encode(hooks)
    }
}

// MARK: - Custom output schemas (the dynamic-lane SchemaDef, versioned like a template)

@Model
final class SchemaModel {
    var id: UUID
    var createdAt: Date
    var taskRaw: String
    var name: String
    var version: Int
    var defJSON: String            // SchemaDef, encoded
    var genConfigJSON: String      // GenConfig captured alongside the schema (seeds pipeline runs)
    var notes: String

    var task: TaskKind { TaskKind(rawValue: taskRaw) ?? .gloss }
    var def: SchemaDef? { JSONCoder.decode(SchemaDef.self, defJSON) }
    var genConfig: GenConfig { JSONCoder.decode(GenConfig.self, genConfigJSON) ?? GenConfig() }

    init(task: TaskKind, name: String, version: Int = 1, def: SchemaDef,
         genConfig: GenConfig = GenConfig(), notes: String = "") {
        self.id = UUID()
        self.createdAt = Date()
        self.taskRaw = task.rawValue
        self.name = name
        self.version = version
        self.defJSON = JSONCoder.encode(def)
        self.genConfigJSON = JSONCoder.encode(genConfig)
        self.notes = notes
    }
}

// MARK: - Datasets

@Model
final class DatasetModel {
    var id: UUID
    var createdAt: Date
    var taskRaw: String
    var name: String
    @Relationship(deleteRule: .cascade, inverse: \ExampleModel.dataset)
    var examples: [ExampleModel]

    var task: TaskKind { TaskKind(rawValue: taskRaw) ?? .gloss }

    init(task: TaskKind, name: String, examples: [ExampleModel] = []) {
        self.id = UUID()
        self.createdAt = Date()
        self.taskRaw = task.rawValue
        self.name = name
        self.examples = examples
    }
}

@Model
final class ExampleModel {
    var id: UUID
    var createdAt: Date
    var taskRaw: String
    var label: String
    var inputJSON: String          // Gloss.Input or Roleplay.Input, encoded
    var dataset: DatasetModel?

    var expectedOutput: String = ""   // optional ground-truth reference for reference-based scoring

    var task: TaskKind { TaskKind(rawValue: taskRaw) ?? .gloss }
    var glossInput: Gloss.Input? { JSONCoder.decode(Gloss.Input.self, inputJSON) }
    var roleplayInput: Roleplay.Input? { JSONCoder.decode(Roleplay.Input.self, inputJSON) }
    var runInput: RunInput? { JSONCoder.decode(RunInput.self, inputJSON) }

    init(task: TaskKind, label: String, inputJSON: String, expectedOutput: String = "") {
        self.id = UUID()
        self.createdAt = Date()
        self.taskRaw = task.rawValue
        self.label = label
        self.inputJSON = inputJSON
        self.expectedOutput = expectedOutput
    }
}

// MARK: - Experiments + runs

@Model
final class ExperimentModel {
    var id: UUID
    var createdAt: Date
    var taskRaw: String
    var label: String
    var templateName: String
    var templateVersion: Int
    var instructions: String       // raw template used (with {{vars}})
    var schemaID: String           // which @Generable schema (e.g. "Gloss.Result")
    var genConfigJSON: String      // GenConfig, encoded
    var hooksJSON: String = "{}"   // HookPipelineDef snapshot — which hooks produced this experiment
    var datasetName: String
    var status: String             // "running" | "done" | "cancelled"
    var sweepID: UUID? = nil       // groups the experiments produced by one variant sweep
    var prewarmed: Bool = false    // session.prewarm() was called before timing
    @Relationship(deleteRule: .cascade, inverse: \RunModel.experiment)
    var runs: [RunModel]

    var task: TaskKind { TaskKind(rawValue: taskRaw) ?? .gloss }
    var genConfig: GenConfig { JSONCoder.decode(GenConfig.self, genConfigJSON) ?? GenConfig() }
    var hooks: HookPipelineDef { JSONCoder.decode(HookPipelineDef.self, hooksJSON) ?? .empty }
    var variantLabel: String { "\(templateName) v\(templateVersion) · \(genConfig.label)" }

    init(task: TaskKind, label: String, templateName: String, templateVersion: Int,
         instructions: String, schemaID: String, genConfig: GenConfig, datasetName: String,
         hooks: HookPipelineDef = .empty, sweepID: UUID? = nil, prewarmed: Bool = false) {
        self.id = UUID()
        self.createdAt = Date()
        self.taskRaw = task.rawValue
        self.label = label
        self.templateName = templateName
        self.templateVersion = templateVersion
        self.instructions = instructions
        self.schemaID = schemaID
        self.genConfigJSON = JSONCoder.encode(genConfig)
        self.hooksJSON = JSONCoder.encode(hooks)
        self.datasetName = datasetName
        self.status = "running"
        self.sweepID = sweepID
        self.prewarmed = prewarmed
        self.runs = []
    }
}

extension ExperimentModel {
    /// nil = typed/built-in schema (schemaID is just a label like "Gloss.Result"); non-nil = the
    /// dynamic SchemaModel id to load and run via the dynamic path (schemaID == "dyn:<uuid>").
    var dynamicSchemaID: UUID? {
        schemaID.hasPrefix("dyn:") ? UUID(uuidString: String(schemaID.dropFirst(4))) : nil
    }
}

@Model
final class RunModel {
    var id: UUID
    var createdAt: Date
    var exampleLabel: String
    var inputJSON: String
    var outputJSON: String          // generated @Generable, pretty JSON
    var turnsJSON: String?          // role-play: per-turn outputs, encoded
    var errorText: String?

    // First-class sortable columns (mirrors of fields inside metricsJSON).
    var decoded: Bool
    var composite: Double
    var latencyMs: Int
    var promptTokensEst: Int
    var outputTokensEst: Int
    var contextTokensEst: Int
    var contextHeadroom: Int
    var onTargetLanguage: Double?
    // First-class mirrors of the new metric fields (sortable in leaderboards / comparison tables).
    var ttftMs: Int? = nil
    var tokensPerSec: Double? = nil
    var referenceMatch: Double? = nil

    var metricsJSON: String         // full RunMetrics, encoded
    var traceJSON: String = "{}"    // RunTrace snapshot — the staged pipeline view for this run

    // Subjective (Phase 2).
    var manualRating: Int?          // 1–5
    var judgeJSON: String?          // JudgeScore, encoded

    var experiment: ExperimentModel?

    var metrics: RunMetrics? { JSONCoder.decode(RunMetrics.self, metricsJSON) }
    var trace: RunTrace? { let t = JSONCoder.decode(RunTrace.self, traceJSON); return (t?.isEmpty ?? true) ? nil : t }

    init(exampleLabel: String, inputJSON: String, outputJSON: String, turnsJSON: String? = nil,
         errorText: String? = nil, metrics: RunMetrics, trace: RunTrace? = nil) {
        self.id = UUID()
        self.createdAt = Date()
        self.exampleLabel = exampleLabel
        self.inputJSON = inputJSON
        self.outputJSON = outputJSON
        self.turnsJSON = turnsJSON
        self.errorText = errorText
        self.decoded = metrics.decoded
        self.composite = Scoring.composite(metrics)
        self.latencyMs = metrics.latencyMs
        self.promptTokensEst = metrics.promptTokensEst
        self.outputTokensEst = metrics.outputTokensEst
        self.contextTokensEst = metrics.contextTokensEst
        self.contextHeadroom = metrics.contextHeadroom
        self.onTargetLanguage = metrics.onTargetLanguage
        self.ttftMs = metrics.ttftMs
        self.tokensPerSec = metrics.tokensPerSec
        self.referenceMatch = metrics.referenceMatch
        self.metricsJSON = JSONCoder.encode(metrics)
        self.traceJSON = trace.map(JSONCoder.encode) ?? "{}"
        self.manualRating = nil
        self.judgeJSON = nil
    }
}

// MARK: - Node graphs (the visual ComfyUI/FigJam-style canvas; whole GraphDef as one JSON blob)

@Model
final class GraphModel {
    var id: UUID
    var createdAt: Date
    var name: String
    var version: Int = 1
    var notes: String = ""
    var graphJSON: String = "{}"          // GraphDef, encoded — migrated up from legacy shapes on read

    // Routes through GraphMigrator (NOT a bare decode) so legacy v1 blobs are lifted to v2 instead of
    // silently decoding to an empty GraphDef — which would destroy the user's saved graph with no error.
    var graphDef: GraphDef { GraphMigrator.load(graphJSON) }

    init(name: String, graph: GraphDef = GraphDef(), version: Int = 1, notes: String = "") {
        self.id = UUID()
        self.createdAt = Date()
        self.name = name
        self.version = version
        self.notes = notes
        self.graphJSON = JSONCoder.encode(graph)
    }
}

// MARK: - Container

enum PlaygroundStore {
    static let models: [any PersistentModel.Type] = [
        PromptTemplateModel.self, SchemaModel.self, DatasetModel.self, ExampleModel.self,
        ExperimentModel.self, RunModel.self, GraphModel.self
    ]
}
