//
//  NodeInspector.swift
//  Prompt Playground
//
//  Right-hand inspector for the selected graph node. Switches on node.kind and binds straight into
//  the node's typed payload — reusing the existing control views (GenConfigControls, SchemaEditorView)
//  verbatim for the FM node, and the hook param model for nativeAPI / hook nodes.
//

import SwiftUI

struct NodeInspector: View {
    @Binding var node: GraphNode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                header
                Divider()
                switch node.kind {
                case .message:           messageEditor
                case .prompt:            promptEditor
                case .nativeAPI, .hook:  hookEditor
                case .fm:                fmEditor
                }
            }
            .padding(DS.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: node.kind.symbol).foregroundStyle(.dsAccent)
            VStack(alignment: .leading, spacing: 1) {
                TextField("Title", text: $node.title).dsTextField()
                Text(node.kind.label).font(.dsMicro).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Message

    @ViewBuilder private var messageEditor: some View {
        if let msg = Binding($node.message) {
            DSField(label: "Role") {
                Picker("", selection: msg.role) {
                    ForEach(MessageRole.allCases, id: \.self) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            DSField(label: "Content", help: "{{variables}} are filled by incoming edges or upstream output keys.") {
                TextEditor(text: msg.content).font(.dsCode).dsEditor(lines: 8)
            }
        }
    }

    // MARK: Prompt

    @ViewBuilder private var promptEditor: some View {
        if let p = Binding($node.prompt) {
            DSField(label: "Template", help: "The current user turn sent to the FM. Use {{name}} placeholders.") {
                TextEditor(text: p.template).font(.dsCode).dsEditor(lines: 6)
            }
            DSSectionHeader("Variables")
            let keys = Vars.keys(in: node.prompt?.template ?? "")
            if keys.isEmpty {
                Text("No variables. Add a {{name}} token to the template.")
                    .font(.dsCaption).foregroundStyle(.tertiary)
            } else {
                ForEach(keys, id: \.self) { key in
                    DSField(label: key, help: "Empty = wired from an upstream node’s output port.") {
                        TextField("static value", text: staticBinding(key)).dsTextField()
                    }
                }
            }
            DSSectionHeader("Few-shot")
            ForEach(p.fewShots) { $shot in
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    TextField("user", text: $shot.user).dsTextField()
                    TextField("assistant", text: $shot.assistant).dsTextField()
                }.dsFlat()
            }
            HStack {
                Button { node.prompt?.fewShots.append(FewShot()) } label: { Label("Add example", systemImage: "plus") }
                if !(node.prompt?.fewShots.isEmpty ?? true) {
                    Button(role: .destructive) { node.prompt?.fewShots.removeLast() } label: { Label("Remove last", systemImage: "minus") }
                }
            }.font(.dsCaption)
        }
    }

    // MARK: Hook / Native API

    @ViewBuilder private var hookEditor: some View {
        if let h = Binding($node.hook) {
            DSField(label: "Operation") {
                Picker("", selection: h.opRaw) {
                    ForEach(opChoices, id: \.self) { Text($0.displayName).tag($0.rawValue) }
                }.labelsHidden()
            }
            if let op = node.hook?.op {
                Text(op.detail).font(.dsCaption).foregroundStyle(.secondary)
                if !op.portability.isPortable {
                    Label(op.portability.label, systemImage: "exclamationmark.triangle")
                        .font(.dsMicro).foregroundStyle(.dsWarning)
                }
            }
            HStack(spacing: DS.Space.md) {
                DSField(label: "in (input var)") { TextField("input", text: h.inputVar).dsTextField() }
                DSField(label: "out (output var)") { TextField("output", text: h.outputVar).dsTextField() }
            }
            ForEach(node.hook?.op.paramKeys ?? [], id: \.self) { param in
                DSField(label: param.label, help: param.placeholder) {
                    TextField(param.placeholder, text: paramBinding(param.rawValue)).dsTextField()
                }
            }
        }
    }

    private var opChoices: [HookOp] {
        node.kind == .nativeAPI
            ? [.tokenizeWords, .enrichGloss, .detectLanguage, .sentenceSplit]
            : [.script, .regexExtract, .regexReplace, .jsonExtract, .textTransform]
    }

    // MARK: FM

    @ViewBuilder private var fmEditor: some View {
        if let fm = Binding($node.fm) {
            if let msg = node.fm == nil ? nil : engineAvailability {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.dsCaption).foregroundStyle(.dsWarning).fixedSize(horizontal: false, vertical: true)
            }
            DSSectionHeader("Sampling")
            GenConfigControls(config: fm.config)
            DSSectionHeader("Guided Generation")
            Toggle("Constrain output to a schema", isOn: fm.useGuidedGen).font(.dsBody)
            if fm.useGuidedGen.wrappedValue {
                SchemaEditorView(def: schemaBinding)
            }
        }
    }

    private var engineAvailability: String? { ModelAvailability.message }

    // MARK: Bindings

    private func staticBinding(_ key: String) -> Binding<String> {
        Binding(get: { node.prompt?.statics[key] ?? "" },
                set: { node.prompt?.statics[key] = $0 })
    }
    private func paramBinding(_ key: String) -> Binding<String> {
        Binding(get: { node.hook?.params[key] ?? "" },
                set: { node.hook?.params[key] = $0 })
    }
    private var schemaBinding: Binding<SchemaDef> {
        Binding(get: { node.fm?.schemaDef ?? .glossLike },
                set: { node.fm?.schemaDef = $0 })
    }
}
