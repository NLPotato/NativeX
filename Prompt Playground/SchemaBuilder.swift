//
//  SchemaBuilder.swift
//  Prompt Playground
//
//  SchemaDef → a runtime FoundationModels `GenerationSchema` (via `DynamicGenerationSchema`),
//  plus the thin run helper that executes a dynamic schema on a session and returns pretty JSON.
//
//  API verified against the installed SDK swiftinterface:
//    DynamicGenerationSchema(name:description:properties:) / (arrayOf:minimumElements:maximumElements:)
//    / (type:guides:) / (referenceTo:);  .Property(name:description:schema:isOptional:)  [no guides:]
//    GenerationSchema(root:dependencies:) throws ;  session.respond(to:schema:…) -> GeneratedContent
//

import Foundation
import FoundationModels

enum SchemaBuilder {
    /// Build a usable `GenerationSchema` from a `SchemaDef`. Throws `SchemaWalker.ValidationError`
    /// on a malformed def, or `GenerationSchema.SchemaError` on unresolved references.
    static func generationSchema(from def: SchemaDef) throws -> GenerationSchema {
        let table = try SchemaWalker.validatedTable(for: def)
        let rootName = def.asObjectDef.name
        guard let rootObj = table[rootName] else { throw SchemaWalker.ValidationError.emptyName }
        let root = objectSchema(rootObj, in: table)
        let deps = table.keys
            .filter { $0 != rootName }
            .sorted()
            .compactMap { table[$0] }
            .map { objectSchema($0, in: table) }
        return try GenerationSchema(root: root, dependencies: deps)
    }

    private static func objectSchema(_ obj: SchemaDef.ObjectDef,
                                     in table: [String: SchemaDef.ObjectDef]) -> DynamicGenerationSchema {
        let props = obj.fields.map { f in
            DynamicGenerationSchema.Property(
                name: f.name,
                description: f.description.isEmpty ? nil : f.description,
                schema: schema(for: f.type),
                isOptional: f.isOptional
            )
        }
        return DynamicGenerationSchema(
            name: obj.name,
            description: obj.description.isEmpty ? nil : obj.description,
            properties: props
        )
    }

    /// FieldType → DynamicGenerationSchema. Nested objects become `referenceTo:` (resolved via the
    /// `dependencies:` list); enums become a String leaf with an `.anyOf` guide (Property carries no
    /// guides, so the constraint must live on the leaf node).
    private static func schema(for type: SchemaDef.FieldType) -> DynamicGenerationSchema {
        switch type {
        case .string: return DynamicGenerationSchema(type: String.self)
        case .int:    return DynamicGenerationSchema(type: Int.self)
        case .double: return DynamicGenerationSchema(type: Double.self)
        case .bool:   return DynamicGenerationSchema(type: Bool.self)
        case .enumeration(let cases):
            let clean = cases.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return DynamicGenerationSchema(type: String.self, guides: [.anyOf(clean)])
        case .array(let inner, let min, let max):
            return DynamicGenerationSchema(arrayOf: schema(for: inner), minimumElements: min, maximumElements: max)
        case .object(let o):
            return DynamicGenerationSchema(referenceTo: o.name)
        }
    }
}

// MARK: - Dynamic run helper

/// Runs a `SchemaDef` dynamically on a session and returns pretty JSON of the result. Shared by
/// the live engines (`PlaygroundModel`/`RoleplayModel`) and the headless pipeline (`DynamicRunner`).
@MainActor
enum DynamicRun {
    static func respond(session: LanguageModelSession, prompt: String, def: SchemaDef,
                        options: GenerationOptions) async throws -> GeneratedContent {
        let schema = try SchemaBuilder.generationSchema(from: def)
        let response = try await session.respond(to: prompt, schema: schema,
                                                 includeSchemaInPrompt: true, options: options)
        return response.content
    }
}

// MARK: - JSON pretty-printing for the dynamic lane

/// Re-pretty-print a JSON string. `GeneratedContent` is not `Encodable`, so the shared
/// `prettyJSON<Encodable>` can't be used — we round-trip its compact `.jsonString` instead.
/// Falls back to the input on any parse failure.
func prettyJSONString(_ json: String) -> String {
    guard let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
          let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                                   options: [.prettyPrinted, .withoutEscapingSlashes]),
          let out = String(data: pretty, encoding: .utf8) else { return json }
    return out
}
