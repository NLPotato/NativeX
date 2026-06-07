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

struct GlossInput: Codable, Equatable, Sendable {
    var sentence: String
    var learning: String   // language being learned (the sentence's language)
    var native: String     // user's language (translations land here)
}

struct RoleplayInput: Codable, Equatable, Sendable {
    var learning: String
    var native: String
    var situation: String
    var youRole: String
    var aiRole: String
    /// Drives the conversation headlessly. When exhausted (or empty) the runner auto-picks the
    /// first suggestion so a scene can still be exercised over several turns.
    var scriptedUserTurns: [String]
    /// Total AI turns to generate, including the opening turn.
    var maxTurns: Int
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

    var task: TaskKind { TaskKind(rawValue: taskRaw) ?? .gloss }
    var genConfig: GenConfig { JSONCoder.decode(GenConfig.self, genConfigJSON) ?? GenConfig() }

    init(task: TaskKind, name: String, version: Int = 1, instructions: String, notes: String = "",
         genConfig: GenConfig = GenConfig()) {
        self.id = UUID()
        self.createdAt = Date()
        self.taskRaw = task.rawValue
        self.name = name
        self.version = version
        self.instructions = instructions
        self.notes = notes
        self.genConfigJSON = JSONCoder.encode(genConfig)
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
    var inputJSON: String          // GlossInput or RoleplayInput, encoded
    var dataset: DatasetModel?

    var task: TaskKind { TaskKind(rawValue: taskRaw) ?? .gloss }
    var glossInput: GlossInput? { JSONCoder.decode(GlossInput.self, inputJSON) }
    var roleplayInput: RoleplayInput? { JSONCoder.decode(RoleplayInput.self, inputJSON) }

    init(task: TaskKind, label: String, inputJSON: String) {
        self.id = UUID()
        self.createdAt = Date()
        self.taskRaw = task.rawValue
        self.label = label
        self.inputJSON = inputJSON
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
    var schemaID: String           // which @Generable schema (e.g. "GlossResultGen")
    var genConfigJSON: String      // GenConfig, encoded
    var datasetName: String
    var status: String             // "running" | "done" | "cancelled"
    @Relationship(deleteRule: .cascade, inverse: \RunModel.experiment)
    var runs: [RunModel]

    var task: TaskKind { TaskKind(rawValue: taskRaw) ?? .gloss }
    var genConfig: GenConfig { JSONCoder.decode(GenConfig.self, genConfigJSON) ?? GenConfig() }
    var variantLabel: String { "\(templateName) v\(templateVersion) · \(genConfig.label)" }

    init(task: TaskKind, label: String, templateName: String, templateVersion: Int,
         instructions: String, schemaID: String, genConfig: GenConfig, datasetName: String) {
        self.id = UUID()
        self.createdAt = Date()
        self.taskRaw = task.rawValue
        self.label = label
        self.templateName = templateName
        self.templateVersion = templateVersion
        self.instructions = instructions
        self.schemaID = schemaID
        self.genConfigJSON = JSONCoder.encode(genConfig)
        self.datasetName = datasetName
        self.status = "running"
        self.runs = []
    }
}

extension ExperimentModel {
    /// nil = typed/built-in schema (schemaID is just a label like "GlossResultGen"); non-nil = the
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

    var metricsJSON: String         // full RunMetrics, encoded

    // Subjective (Phase 2).
    var manualRating: Int?          // 1–5
    var judgeJSON: String?          // JudgeScore, encoded

    var experiment: ExperimentModel?

    var metrics: RunMetrics? { JSONCoder.decode(RunMetrics.self, metricsJSON) }

    init(exampleLabel: String, inputJSON: String, outputJSON: String, turnsJSON: String? = nil,
         errorText: String? = nil, metrics: RunMetrics) {
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
        self.metricsJSON = JSONCoder.encode(metrics)
        self.manualRating = nil
        self.judgeJSON = nil
    }
}

// MARK: - Container

enum PlaygroundStore {
    static let models: [any PersistentModel.Type] = [
        PromptTemplateModel.self, SchemaModel.self, DatasetModel.self, ExampleModel.self,
        ExperimentModel.self, RunModel.self
    ]
}
