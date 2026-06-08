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
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Schema name").font(.dsLabel).foregroundStyle(.secondary)
                    TextField("TypeName", text: $def.typeName).dsTextField()
                }
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Description").font(.dsLabel).foregroundStyle(.secondary)
                    TextField("Guides the model — what this schema represents", text: $def.description)
                        .dsTextField()
                }
            }
            .dsCard()

            FieldsEditor(fields: $def.fields, depth: 0)
        }
    }
}

// MARK: - A list of fields (recursive: objects nest more FieldsEditors)

struct FieldsEditor: View {
    @Binding var fields: [SchemaDef.Field]
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            ForEach($fields) { $field in
                FieldRow(field: $field, depth: depth) { fields.removeAll { $0.id == field.id } }
            }
            Button {
                fields.append(SchemaDef.Field(name: "field\(fields.count + 1)", description: "", type: .string))
            } label: { Label("Add field", systemImage: "plus.circle") }
                .font(.dsCaption).buttonStyle(.borderless)
        }
    }
}

struct FieldRow: View {
    @Binding var field: SchemaDef.Field
    let depth: Int
    let onDelete: () -> Void
    @State private var expanded: Bool

    init(field: Binding<SchemaDef.Field>, depth: Int, onDelete: @escaping () -> Void) {
        self._field = field
        self.depth = depth
        self.onDelete = onDelete
        _expanded = State(initialValue: depth == 0)   // top-level fields open; nested collapsed so deep trees stay scannable
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                HStack(spacing: DS.Space.sm) {
                    TextField("name", text: $field.name).dsTextField().frame(maxWidth: 200)
                    Toggle("optional", isOn: $field.isOptional).toggleStyle(.checkbox).font(.dsCaption)
                }
                TextField("description", text: $field.description).dsTextField()
                TypeEditor(type: $field.type, depth: depth)
            }
            .padding(.top, DS.Space.sm)
        } label: {
            HStack(spacing: DS.Space.sm) {
                Text(field.name.isEmpty ? "unnamed" : field.name)
                    .fontWeight(.medium)
                    .foregroundStyle(field.name.isEmpty ? Color.secondary : Color.primary)
                Text(field.type.shortLabel)
                    .font(.dsCaption).foregroundStyle(.secondary)
                    .padding(.horizontal, DS.Space.xs).padding(.vertical, DS.Space.xxs)
                    .background(.quaternary, in: Capsule())
                if field.isOptional {
                    Text("optional").font(.dsMicro).foregroundStyle(.tertiary)
                }
                Spacer()
                Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
        }
        .dsCard()
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
        VStack(alignment: .leading, spacing: DS.Space.sm) {
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
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            ForEach(Array(cases.enumerated()), id: \.offset) { idx, _ in
                HStack(spacing: DS.Space.xs) {
                    TextField("case", text: Binding(
                        get: { idx < cases.count ? cases[idx] : "" },
                        set: { var c = cases; if idx < c.count { c[idx] = $0; setCases(c) } }))
                        .dsTextField()
                    Button(role: .destructive) {
                        var c = cases; if idx < c.count { c.remove(at: idx); setCases(c) }
                    } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            Button { setCases(cases + ["case\(cases.count + 1)"]) } label: { Label("Add case", systemImage: "plus") }
                .font(.dsMicro).buttonStyle(.borderless)
        }
        .padding(.leading, DS.Space.sm)
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
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Text("count min").font(.dsCaption).foregroundStyle(.secondary)
                TextField("–", text: minText).frame(width: 44).dsTextField()
                Text("max").font(.dsCaption).foregroundStyle(.secondary)
                TextField("–", text: maxText).frame(width: 44).dsTextField()
                Text("of:").font(.dsCaption).foregroundStyle(.secondary)
            }
            TypeEditor(type: element, depth: depth + 1)
        }
        .padding(.leading, DS.Space.lg)
        .background(Color.white.opacity(0.03 * Double(min(depth + 1, 3))),
                    in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
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
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            TextField("Type name", text: name).dsTextField()
            TextField("Description", text: desc).dsTextField()
            FieldsEditor(fields: fields, depth: depth + 1)
        }
        .padding(.leading, DS.Space.lg)
        .background(Color.white.opacity(0.03 * Double(min(depth + 1, 3))),
                    in: RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.accent.opacity(0.25)).frame(width: 3) }
    }
}

// MARK: - Collapsed-row summary

extension SchemaDef.FieldType {
    /// Compact one-word summary shown on a collapsed field row, e.g. "Array<Object>", "Enum (3)".
    var shortLabel: String {
        switch self {
        case .string:              return "Text"
        case .int:                 return "Integer"
        case .double:              return "Decimal"
        case .bool:                return "Boolean"
        case .enumeration(let c):  return "Enum (\(c.count))"
        case .array(let of, _, _): return "Array<\(of.shortLabel)>"
        case .object(let o):       return "Object {\(o.fields.count)}"
        }
    }
}

// MARK: - Modal sheet host

/// Hosts the schema editor in a focused sheet so a deep tree gets room to breathe instead of pushing
/// the left-panel controls off-screen. Edits bind live; "New schema" resets to a blank one-field def.
struct SchemaEditorSheet: View {
    @Binding var def: SchemaDef
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Guided Generation schema").font(.dsTitle)
                Spacer()
                Button("New schema") { def = .blank }
                Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction)
            }
            .padding(DS.Space.lg)
            Divider()
            ScrollView { SchemaEditorView(def: $def).padding(DS.Space.xl) }
        }
        .frame(minWidth: DS.Size.sheetMinWidth, idealWidth: 640, minHeight: 520, idealHeight: 680)
        .playgroundBackground()
    }
}
