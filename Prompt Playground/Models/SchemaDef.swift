//
//  SchemaDef.swift
//  Prompt Playground
//
//  Unified, serializable description of a structured-output schema — the single source of truth
//  that (1) builds a runtime DynamicGenerationSchema (SchemaBuilder), (2) emits Swift @Generable
//  source (SwiftCodegen), and (3) persists as JSON (SchemaModel). Intentionally a MINIMAL subset
//  of JSON-schema: scalars, string-enum, bounded arrays, nested objects.
//
//  Two lanes (see CLAUDE.md): the hand-written @Generable structs are the canonical SHIPPING
//  lane; a SchemaDef is the PROTOTYPING lane — authored in the UI, run dynamically, then promoted
//  to a typed struct via codegen when it's good.
//

import Foundation

// MARK: - Model

struct SchemaDef: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var typeName: String          // root struct name + DynamicGenerationSchema name
    var description: String
    var fields: [Field]

    struct Field: Codable, Sendable, Identifiable {
        var id = UUID()
        var name: String
        var description: String
        var type: FieldType
        var isOptional: Bool = false
    }

    /// Recursive leaf/array/object descriptor. Arrays-of-objects = `.array(of: .object(...))`.
    indirect enum FieldType: Codable, Equatable, Sendable {
        case string, int, double, bool
        case enumeration(cases: [String])               // string-backed closed set
        case array(of: FieldType, min: Int?, max: Int?) // bounded homogeneous array
        case object(ObjectDef)                          // nested object, carried by value
    }

    /// A nested object's shape. No `id`: nested objects are addressed by `name`, not identity.
    struct ObjectDef: Codable, Equatable, Sendable {
        var name: String
        var description: String
        var fields: [Field]
    }

    /// The root as an ObjectDef so traversal treats root + nested objects uniformly.
    var asObjectDef: ObjectDef { ObjectDef(name: typeName, description: description, fields: fields) }
}

// Equatable EXCLUDES `id` (identity-only, for SwiftUI/persistence) so two structurally-identical
// objects compare equal — this lets the builder dedupe a reused nested type (e.g. `Line` used by
// both `reply` and `suggestions`) instead of flagging it as a name collision.
extension SchemaDef.Field: Equatable {
    static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.description == b.description && a.type == b.type && a.isOptional == b.isOptional
    }
}

// MARK: - Starter schemas (mirror the typed presets so Custom mode is runnable immediately)

extension SchemaDef {
    /// Mirrors `Gloss.Result` — a nested array-of-objects with a string-enum field.
    static var glossLike: SchemaDef {
        let word = ObjectDef(name: "GlossWord", description: "One mined word from the sentence", fields: [
            Field(name: "surface", description: "Word exactly as it appears in the sentence", type: .string),
            Field(name: "lemma", description: "Dictionary / base (lemma) form of the word", type: .string),
            Field(name: "partOfSpeech", description: "Part of speech",
                  type: .enumeration(cases: ["noun", "verb", "adjective", "adverb", "pronoun",
                                             "preposition", "conjunction", "determiner", "particle",
                                             "numeral", "interjection"])),
            Field(name: "translation", description: "Translation of this word in context", type: .string),
            Field(name: "register", description: "Register or usage note, if relevant", type: .string, isOptional: true),
        ])
        return SchemaDef(typeName: "GlossResult", description: "Learning material extracted from a sentence", fields: [
            Field(name: "words", description: "Each meaningful word in the sentence, in order",
                  type: .array(of: .object(word), min: nil, max: nil)),
            Field(name: "sentenceTranslation", description: "Translation of the whole sentence", type: .string),
            Field(name: "grammarNotes", description: "One or two short grammar notes",
                  type: .array(of: .string, min: nil, max: nil)),
        ])
    }

    /// Reading-aware gloss for non-Latin (CJK) sentences. `reading` is the one piece native APIs CAN
    /// do for CJK deterministically (CFStringTokenizer → romaja/pinyin/romaji, surfaced by the
    /// Enrich-tokens hook); `dictionaryForm` and `partOfSpeech` are the pieces they CAN'T (NLTagger
    /// doesn't tag CJK), so the model supplies them. Pairs with the "CJK gloss" preset's pre-hook.
    static var cjkGloss: SchemaDef {
        let word = ObjectDef(name: "CJKGlossWord", description: "One word from the sentence, with its reading and analysis", fields: [
            Field(name: "surface", description: "Word exactly as it appears, in the original script", type: .string),
            Field(name: "reading", description: "Pronunciation in Latin letters (romaja / pinyin / romaji), copied from the reading given for this word", type: .string),
            Field(name: "dictionaryForm", description: "Dictionary / base form in the word's OWN script (Hangul / Kanji / Hanzi), never the romanized reading — the unconjugated verb or adjective, or the surface with any attached particle removed", type: .string),
            Field(name: "partOfSpeech", description: "Part of speech",
                  type: .enumeration(cases: ["noun", "verb", "adjective", "adverb", "pronoun", "determiner",
                                             "particle", "numeral", "classifier", "conjunction", "interjection", "other"])),
            Field(name: "meaning", description: "In-context meaning as one short gloss in the learner's native language", type: .string),
        ])
        return SchemaDef(typeName: "CJKGlossResult", description: "Reading-aware gloss for a non-Latin (CJK) sentence", fields: [
            Field(name: "words", description: "Each word in the sentence, in order",
                  type: .array(of: .object(word), min: nil, max: nil)),
            Field(name: "sentenceTranslation", description: "Natural translation of the whole sentence", type: .string),
            Field(name: "grammarNotes", description: "One or two short grammar notes (particles, honorifics, word order)",
                  type: .array(of: .string, min: nil, max: nil)),
        ])
    }

    /// Whole-sentence CJK morphology — the schema for the "CJK morphology — deep single pass" preset.
    /// Per-word morphology is FLATTENED to a single `morphemeBreakdown` string because a structured
    /// morphemes array-of-objects nested inside the `words[]` array-of-objects exceeds maxDepth=3 (proven
    /// on-device), and a `[String]` array made the model split entries on internal commas. A structured
    /// per-word schema (with a `morphemes[]` array-of-objects) is only viable as a STANDALONE root — see
    /// the deferred per-word drill-down design in docs/decisions/ADR-20260608-cjk-two-stage-morphology.md.
    static var morphologyFull: SchemaDef {
        let word = ObjectDef(name: "MorphologyWordFlat", description: "One word, decomposed, with its dictionary form", fields: [
            Field(name: "surface", description: "Word exactly as it appears, in the original script", type: .string),
            Field(name: "reading", description: "Pronunciation in Latin letters, copied from the reading given for this word — do not re-romanize", type: .string),
            Field(name: "dictionaryForm", description: "Dictionary / base form in the word's OWN script (Hangul / Kanji / Hanzi), never the romanized reading — the plain unconjugated verb/adjective (다 form) or the noun with any attached particle removed", type: .string),
            Field(name: "morphemeBreakdown", description: "The surface decomposed into a stem plus every ending/particle as ONE short string, e.g. \"보-(to see) + -았-(past) + -어요(polite)\"", type: .string),
            Field(name: "conjugation", description: "How the surface is conjugated/inflected from the dictionary form (one short explanation); empty if uninflected", type: .string),
            Field(name: "partOfSpeech", description: "Part of speech",
                  type: .enumeration(cases: ["noun", "verb", "adjective", "adverb", "pronoun", "determiner",
                                             "particle", "numeral", "classifier", "conjunction", "interjection", "other"])),
            Field(name: "register", description: "Honorific level / politeness / register note, if relevant", type: .string),
            Field(name: "meaning", description: "In-context meaning as one short gloss in the learner's native language", type: .string),
            Field(name: "example", description: "One short, natural usage example in the learning language", type: .string),
        ])
        return SchemaDef(typeName: "MorphologyResult", description: "Full morphological analysis of a non-Latin (CJK) sentence", fields: [
            Field(name: "words", description: "Each word in the sentence, fully analyzed, in order",
                  type: .array(of: .object(word), min: nil, max: nil)),
            Field(name: "sentenceTranslation", description: "Natural translation of the whole sentence into the learner's native language", type: .string),
            Field(name: "grammarNotes", description: "One or two short grammar notes (particles, honorifics, word order)",
                  type: .array(of: .string, min: nil, max: nil)),
        ])
    }

    /// Mirrors `Roleplay.TurnGen` — nested object + bounded array-of-objects (the canonical nesting test).
    static var roleplayLike: SchemaDef {
        let line = ObjectDef(name: "Line", description: "One spoken line of dialogue, with a translation", fields: [
            Field(name: "text", description: "What is said, in the learning language", type: .string),
            Field(name: "translation", description: "A natural translation into the native language", type: .string),
        ])
        return SchemaDef(typeName: "Turn", description: "The character's reply plus two suggested user lines", fields: [
            Field(name: "reply", description: "What the character says now, in the learning language",
                  type: .object(line)),
            Field(name: "suggestions", description: "Exactly two things the user could say next",
                  type: .array(of: .object(line), min: 2, max: 2)),
        ])
    }

    static func starter(for task: TaskKind) -> SchemaDef { task == .roleplay ? .roleplayLike : .glossLike }

    /// A minimal one-field schema — the "New schema" reset target in the editor.
    static var blank: SchemaDef {
        SchemaDef(typeName: "Output", description: "",
                  fields: [Field(name: "field1", description: "", type: .string)])
    }
}

// MARK: - Shared traversal (used by SchemaBuilder + SwiftCodegen so they never diverge)

enum SchemaWalker {
    static let maxDepth = 3

    enum ValidationError: LocalizedError {
        case emptyName
        case emptyObject(String)
        case duplicateTypeName(String)
        case duplicateField(object: String, field: String)
        case emptyEnum(String)
        case tooDeep(Int)

        var errorDescription: String? {
            switch self {
            case .emptyName:                       return "Every type and field needs a name."
            case .emptyObject(let n):              return "Object “\(n)” has no fields."
            case .duplicateTypeName(let n):        return "Two different objects are both named “\(n)”. Type names must be unique."
            case .duplicateField(let o, let f):    return "Object “\(o)” has two fields named “\(f)”."
            case .emptyEnum(let f):                return "Enum field “\(f)” needs at least one case."
            case .tooDeep(let d):                  return "Schema nesting is too deep (max \(d) levels)."
            }
        }
    }

    /// Validate + flatten every object (root + nested) into a name-keyed table. Throws on the first
    /// problem; used before a real run so a malformed schema never reaches the model.
    static func validatedTable(for def: SchemaDef) throws -> [String: SchemaDef.ObjectDef] {
        var table: [String: SchemaDef.ObjectDef] = [:]
        try collect(def.asObjectDef, depth: 0, into: &table)
        return table
    }

    /// Non-throwing flatten — best-effort, last-writer-wins. For codegen, which must render even
    /// while the user is mid-edit. Falls back here when `validatedTable` would throw.
    static func flatten(_ def: SchemaDef) -> [String: SchemaDef.ObjectDef] {
        var table: [String: SchemaDef.ObjectDef] = [:]
        func walk(_ o: SchemaDef.ObjectDef) {
            table[o.name] = o
            for f in o.fields { walkType(f.type) }
        }
        func walkType(_ t: SchemaDef.FieldType) {
            switch t {
            case .object(let o):          walk(o)
            case .array(let inner, _, _): walkType(inner)
            default:                      break
            }
        }
        walk(def.asObjectDef)
        return table
    }

    /// Object names ordered dependencies-first (so emitted Swift compiles top-to-bottom). The
    /// by-value tree is acyclic by construction; unreachable names are appended in stable order.
    static func topoSortedNames(_ table: [String: SchemaDef.ObjectDef], root: String) -> [String] {
        var visited = Set<String>(), order: [String] = []
        func visit(_ name: String) {
            guard !visited.contains(name), let obj = table[name] else { return }
            visited.insert(name)
            for f in obj.fields { for ref in referenced(f.type) { visit(ref) } }
            order.append(name)                      // dependencies appended before self
        }
        visit(root)
        for name in table.keys.sorted() where !visited.contains(name) { visit(name) }
        return order
    }

    private static func referenced(_ t: SchemaDef.FieldType) -> [String] {
        switch t {
        case .object(let o):          return [o.name]
        case .array(let inner, _, _): return referenced(inner)
        default:                      return []
        }
    }

    private static func collect(_ obj: SchemaDef.ObjectDef, depth: Int,
                                into table: inout [String: SchemaDef.ObjectDef]) throws {
        guard depth <= maxDepth else { throw ValidationError.tooDeep(maxDepth) }
        let name = obj.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw ValidationError.emptyName }
        guard !obj.fields.isEmpty else { throw ValidationError.emptyObject(name) }
        if let existing = table[name], existing != obj { throw ValidationError.duplicateTypeName(name) }
        table[name] = obj

        var seenFields = Set<String>()
        for f in obj.fields {
            let fn = f.name.trimmingCharacters(in: .whitespaces)
            guard !fn.isEmpty else { throw ValidationError.emptyName }
            guard seenFields.insert(fn).inserted else { throw ValidationError.duplicateField(object: name, field: fn) }
            try collectType(f.type, depth: depth, fieldName: fn, into: &table)
        }
    }

    private static func collectType(_ t: SchemaDef.FieldType, depth: Int, fieldName: String,
                                    into table: inout [String: SchemaDef.ObjectDef]) throws {
        switch t {
        case .object(let o):
            try collect(o, depth: depth + 1, into: &table)
        case .array(let inner, _, _):
            try collectType(inner, depth: depth + 1, fieldName: fieldName, into: &table)
        case .enumeration(let cases):
            if cases.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                throw ValidationError.emptyEnum(fieldName)
            }
        default:
            break
        }
    }
}
