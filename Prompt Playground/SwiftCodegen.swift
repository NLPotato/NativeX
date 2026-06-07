//
//  SwiftCodegen.swift
//  Prompt Playground
//
//  SchemaDef → Swift @Generable source. The "promote a dynamic prototype to the typed shipping
//  lane" path: emit copyable structs the user pastes into the app target (and ships to wiekant).
//  Uses the same SchemaWalker table as SchemaBuilder so the two never diverge.
//
//  Fidelity note: array min/max are NOT emitted as `.count` guides — the hand-written schemas use
//  a soft "exactly two" in the description instead (see RoleplayPlayground.swift). Tune as @Guides
//  after pasting if you want a hard bound.
//

import Foundation

enum SwiftCodegen {
    /// Best-effort compilable Swift for the schema. Renders even mid-edit (the editor gates real
    /// runs); uses the validated table when possible, else a non-throwing flatten.
    static func emit(_ def: SchemaDef) -> String {
        let table = (try? SchemaWalker.validatedTable(for: def)) ?? SchemaWalker.flatten(def)
        let order = SchemaWalker.topoSortedNames(table, root: def.asObjectDef.name)
        var out = "import FoundationModels\n\n"
        for name in order {
            guard let obj = table[name] else { continue }
            out += emitStruct(obj)
        }
        return out
    }

    private static func emitStruct(_ obj: SchemaDef.ObjectDef) -> String {
        var s = obj.description.isEmpty ? "@Generable\n" : "@Generable(description: \(quoted(obj.description)))\n"
        s += "struct \(ident(obj.name, upperFirst: true)): Codable {\n"
        for f in obj.fields {
            s += guideLine(f)
            s += "    var \(ident(f.name, upperFirst: false)): \(swiftType(f.type))\(f.isOptional ? "?" : "")\n"
        }
        s += "}\n\n"
        return s
    }

    /// The `@Guide(...)` line for a field (empty when there's nothing to say). Enums add `.anyOf`.
    private static func guideLine(_ f: SchemaDef.Field) -> String {
        var args: [String] = []
        if !f.description.isEmpty { args.append("description: \(quoted(f.description))") }
        if case .enumeration(let cases) = f.type {
            let clean = cases.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            args.append(".anyOf([\(clean.map(quoted).joined(separator: ", "))])")
        }
        return args.isEmpty ? "" : "    @Guide(\(args.joined(separator: ", ")))\n"
    }

    private static func swiftType(_ t: SchemaDef.FieldType) -> String {
        switch t {
        case .string:      return "String"
        case .int:         return "Int"
        case .double:      return "Double"
        case .bool:        return "Bool"
        case .enumeration: return "String"                          // closed set enforced via @Guide(.anyOf)
        case .array(let inner, _, _): return "[\(swiftType(inner))]"
        case .object(let o): return ident(o.name, upperFirst: true)
        }
    }

    // MARK: - Identifier / string helpers

    /// Turn an arbitrary name into a valid Swift identifier (CamelCase). Defensive — the editor
    /// encourages clean names, but free text shouldn't produce uncompilable output.
    private static func ident(_ raw: String, upperFirst: Bool) -> String {
        let parts = raw.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !parts.isEmpty else { return upperFirst ? "Type" : "field" }
        var result = ""
        for (i, p) in parts.enumerated() {
            let head = (i == 0 && !upperFirst) ? p.prefix(1).lowercased() : p.prefix(1).uppercased()
            result += head + p.dropFirst()
        }
        if let first = result.first, first.isNumber { result = "_" + result }
        return result
    }

    private static func quoted(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
                       .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}
