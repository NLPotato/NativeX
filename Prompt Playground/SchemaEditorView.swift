//
//  SchemaEditorView.swift
//  Prompt Playground
//
//  Recursive UI for authoring a `SchemaDef` (the dynamic prototyping lane). Fields carry a kind
//  (Text/Integer/.../Enum/Array/Object); Array and Object recurse into nested editors, bounded by
//  `SchemaWalker.maxDepth`. Bindings thread edits back into the enum-based FieldType tree.
//

import SwiftUI

// MARK: - Field kind (the picker surface for FieldType)

enum FieldKind: String, CaseIterable, Identifiable, Hashable {
    case string, int, double, bool, enumeration, array, object
    var id: String { rawValue }

    var label: String {
        switch self {
        case .string:      return "Text"
        case .int:         return "Integer"
        case .double:      return "Decimal"
        case .bool:        return "Boolean"
        case .enumeration: return "Enum"
        case .array:       return "Array"
        case .object:      return "Object"
        }
    }

    init(_ t: SchemaDef.FieldType) {
        switch t {
        case .string:      self = .string
        case .int:         self = .int
        case .double:      self = .double
        case .bool:        self = .bool
        case .enumeration: self = .enumeration
        case .array:       self = .array
        case .object:      self = .object
        }
    }

    /// A fresh FieldType when the user switches kind.
    func defaultType() -> SchemaDef.FieldType {
        switch self {
        case .string:      return .string
        case .int:         return .int
        case .double:      return .double
        case .bool:        return .bool
        case .enumeration: return .enumeration(cases: ["one", "two"])
        case .array:       return .array(of: .string, min: nil, max: nil)
        case .object:      return .object(SchemaDef.ObjectDef(name: "NewType", description: "",
                                                              fields: [SchemaDef.Field(name: "field1", description: "", type: .string)]))
        }
    }
}

// MARK: - Top-level editor

struct SchemaEditorView: View {
    @Binding var def: SchemaDef

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Schema name").font(.footnote).fontWeight(.medium).foregroundStyle(.primary.opacity(0.6))
                    TextField("TypeName", text: $def.typeName).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Description").font(.footnote).fontWeight(.medium).foregroundStyle(.primary.opacity(0.6))
                    TextField("Guides the model — what this schema represents", text: $def.description)
                        .textFieldStyle(.roundedBorder).font(.caption)
                }
            }
            .padding(10)
            .glassCard(radius: 10)

            FieldsEditor(fields: $def.fields, depth: 0)
        }
    }
}

// MARK: - A list of fields (recursive: objects nest more FieldsEditors)

struct FieldsEditor: View {
    @Binding var fields: [SchemaDef.Field]
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($fields) { $field in
                FieldRow(field: $field, depth: depth) { fields.removeAll { $0.id == field.id } }
            }
            Button {
                fields.append(SchemaDef.Field(name: "field\(fields.count + 1)", description: "", type: .string))
            } label: { Label("Add field", systemImage: "plus.circle") }
                .font(.caption).buttonStyle(.borderless)
        }
    }
}

struct FieldRow: View {
    @Binding var field: SchemaDef.Field
    let depth: Int
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("name", text: $field.name).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                Spacer()
                Toggle("optional", isOn: $field.isOptional).toggleStyle(.checkbox).font(.caption2)
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            TextField("description", text: $field.description).textFieldStyle(.roundedBorder).font(.caption)
            TypeEditor(type: $field.type, depth: depth)
        }
        .padding(10)
        .glassCard(radius: 10)
    }
}

// MARK: - Type editor (kind picker + per-kind payload)

struct TypeEditor: View {
    @Binding var type: SchemaDef.FieldType
    let depth: Int

    private var kinds: [FieldKind] {
        depth >= SchemaWalker.maxDepth ? [.string, .int, .double, .bool, .enumeration] : FieldKind.allCases
    }
    private var kind: Binding<FieldKind> {
        Binding(get: { FieldKind(type) }, set: { type = $0.defaultType() })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: kind) {
                ForEach(kinds) { Text($0.label).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()

            switch type {
            case .enumeration: EnumCasesEditor(type: $type)
            case .array:       ArrayEditor(type: $type, depth: depth)
            case .object:      ObjectEditor(type: $type, depth: depth)
            default:           EmptyView()
            }
        }
    }
}

// MARK: - Enum cases

struct EnumCasesEditor: View {
    @Binding var type: SchemaDef.FieldType

    private var cases: [String] { if case .enumeration(let c) = type { return c } else { return [] } }
    private func setCases(_ c: [String]) { type = .enumeration(cases: c) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(cases.enumerated()), id: \.offset) { idx, _ in
                HStack(spacing: 4) {
                    TextField("case", text: Binding(
                        get: { idx < cases.count ? cases[idx] : "" },
                        set: { var c = cases; if idx < c.count { c[idx] = $0; setCases(c) } }))
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        var c = cases; if idx < c.count { c.remove(at: idx); setCases(c) }
                    } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            Button { setCases(cases + ["case\(cases.count + 1)"]) } label: { Label("Add case", systemImage: "plus") }
                .font(.caption2).buttonStyle(.borderless)
        }
        .padding(.leading, 8)
    }
}

// MARK: - Array (element type + optional bounds)

struct ArrayEditor: View {
    @Binding var type: SchemaDef.FieldType
    let depth: Int

    private var element: Binding<SchemaDef.FieldType> {
        Binding(
            get: { if case .array(let inner, _, _) = type { return inner } else { return .string } },
            set: { newInner in
                if case .array(_, let mn, let mx) = type { type = .array(of: newInner, min: mn, max: mx) }
                else { type = .array(of: newInner, min: nil, max: nil) }
            })
    }
    private var minText: Binding<String> {
        Binding(
            get: { if case .array(_, let mn, _) = type { return mn.map(String.init) ?? "" } else { return "" } },
            set: { s in if case .array(let i, _, let mx) = type { type = .array(of: i, min: Int(s), max: mx) } })
    }
    private var maxText: Binding<String> {
        Binding(
            get: { if case .array(_, _, let mx) = type { return mx.map(String.init) ?? "" } else { return "" } },
            set: { s in if case .array(let i, let mn, _) = type { type = .array(of: i, min: mn, max: Int(s)) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("count min").font(.caption2).foregroundStyle(.secondary)
                TextField("–", text: minText).frame(width: 40).textFieldStyle(.roundedBorder)
                Text("max").font(.caption2).foregroundStyle(.secondary)
                TextField("–", text: maxText).frame(width: 40).textFieldStyle(.roundedBorder)
                Text("of:").font(.caption2).foregroundStyle(.secondary)
            }
            TypeEditor(type: element, depth: depth + 1)
        }
        .padding(.leading, 14)
        .background(Color.white.opacity(0.03 * Double(min(depth + 1, 3))),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.accent.opacity(0.25)).frame(width: 3) }
    }
}

// MARK: - Nested object

struct ObjectEditor: View {
    @Binding var type: SchemaDef.FieldType
    let depth: Int

    private var obj: SchemaDef.ObjectDef {
        if case .object(let o) = type { return o }
        return SchemaDef.ObjectDef(name: "NewType", description: "", fields: [])
    }
    private func set(_ o: SchemaDef.ObjectDef) { type = .object(o) }
    private var name: Binding<String> { Binding(get: { obj.name }, set: { var o = obj; o.name = $0; set(o) }) }
    private var desc: Binding<String> { Binding(get: { obj.description }, set: { var o = obj; o.description = $0; set(o) }) }
    private var fields: Binding<[SchemaDef.Field]> { Binding(get: { obj.fields }, set: { var o = obj; o.fields = $0; set(o) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Type name", text: name).textFieldStyle(.roundedBorder)
            TextField("Description", text: desc).textFieldStyle(.roundedBorder).font(.caption)
            FieldsEditor(fields: fields, depth: depth + 1)
        }
        .padding(.leading, 14)
        .background(Color.white.opacity(0.03 * Double(min(depth + 1, 3))),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.accent.opacity(0.25)).frame(width: 3) }
    }
}
