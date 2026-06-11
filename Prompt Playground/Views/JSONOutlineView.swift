//
//  JSONOutlineView.swift
//  Prompt Playground
//
//  Structured rendering for model output: parses JSON into an ORDER-PRESERVING node tree (Foundation's
//  JSONSerialization loses object key order, which matters for @Generable schemas — property order is
//  the schema's order) and renders it as a key-value outline instead of raw indented JSON. Scalars are
//  typed (string/number/bool/null) so the eye can scan values; nested containers indent under a
//  hairline rule; arrays of objects read as numbered entries. Falls back upstream when parsing fails.
//

import SwiftUI

/// One parsed JSON value. Object entries keep source order; numbers keep their source lexeme.
enum JSONNode {
    case object([(key: String, value: JSONNode)])
    case array([JSONNode])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    var isContainer: Bool {
        switch self { case .object, .array: return true; default: return false }
    }
}

enum JSONOutline {
    /// Strict parse of the whole string; nil on any trailing garbage (caller falls back to plain text).
    static func parse(_ text: String) -> JSONNode? {
        var p = Parser(text)
        guard let v = p.parseValue(), p.isAtEnd() else { return nil }
        return v
    }

    /// Minimal recursive-descent JSON parser — exists ONLY because key order must survive (see header).
    private struct Parser {
        private let s: [Character]
        private var i = 0
        init(_ text: String) { s = Array(text) }

        private mutating func skipWS() { while i < s.count, s[i].isWhitespace { i += 1 } }
        mutating func isAtEnd() -> Bool { skipWS(); return i == s.count }

        mutating func parseValue() -> JSONNode? {
            skipWS()
            guard i < s.count else { return nil }
            switch s[i] {
            case "{":  return parseObject()
            case "[":  return parseArray()
            case "\"": return parseString().map { .string($0) }
            case "t":  return literal("true")  ? .bool(true)  : nil
            case "f":  return literal("false") ? .bool(false) : nil
            case "n":  return literal("null")  ? JSONNode.null : nil
            default:   return parseNumber()
            }
        }

        private mutating func literal(_ lit: String) -> Bool {
            let l = Array(lit)
            guard i + l.count <= s.count, Array(s[i..<(i + l.count)]) == l else { return false }
            i += l.count
            return true
        }

        private mutating func parseObject() -> JSONNode? {
            i += 1   // consume {
            var entries: [(key: String, value: JSONNode)] = []
            skipWS()
            if i < s.count, s[i] == "}" { i += 1; return .object(entries) }
            while true {
                skipWS()
                guard i < s.count, s[i] == "\"", let key = parseString() else { return nil }
                skipWS()
                guard i < s.count, s[i] == ":" else { return nil }
                i += 1
                guard let v = parseValue() else { return nil }
                entries.append((key, v))
                skipWS()
                guard i < s.count else { return nil }
                if s[i] == "," { i += 1; continue }
                if s[i] == "}" { i += 1; return .object(entries) }
                return nil
            }
        }

        private mutating func parseArray() -> JSONNode? {
            i += 1   // consume [
            var items: [JSONNode] = []
            skipWS()
            if i < s.count, s[i] == "]" { i += 1; return .array(items) }
            while true {
                guard let v = parseValue() else { return nil }
                items.append(v)
                skipWS()
                guard i < s.count else { return nil }
                if s[i] == "," { i += 1; continue }
                if s[i] == "]" { i += 1; return .array(items) }
                return nil
            }
        }

        private mutating func parseString() -> String? {
            guard i < s.count, s[i] == "\"" else { return nil }
            i += 1
            var out = ""
            while i < s.count {
                let c = s[i]
                if c == "\"" { i += 1; return out }
                if c == "\\" {
                    i += 1
                    guard i < s.count else { return nil }
                    switch s[i] {
                    case "\"": out.append("\"")
                    case "\\": out.append("\\")
                    case "/":  out.append("/")
                    case "n":  out.append("\n")
                    case "t":  out.append("\t")
                    case "r":  out.append("\r")
                    case "b":  out.append("\u{08}")
                    case "f":  out.append("\u{0C}")
                    case "u":
                        guard i + 4 < s.count,
                              let code = UInt32(String(s[(i + 1)...(i + 4)]), radix: 16),
                              let scalar = Unicode.Scalar(code) else { return nil }   // (surrogate pairs → fall back)
                        out.append(Character(scalar))
                        i += 4
                    default: return nil
                    }
                    i += 1
                } else {
                    out.append(c)
                    i += 1
                }
            }
            return nil
        }

        private mutating func parseNumber() -> JSONNode? {
            let start = i
            let extras: Set<Character> = ["-", "+", ".", "e", "E"]
            while i < s.count, s[i].isNumber || extras.contains(s[i]) { i += 1 }
            let lexeme = String(s[start..<i])
            guard i > start, Double(lexeme) != nil else { return nil }
            return .number(lexeme)
        }
    }
}

// MARK: - Outline renderer

struct JSONOutlineView: View {
    let node: JSONNode

    var body: some View {
        switch node {
        case .object(let entries):
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                    entryRow(e.key, e.value)
                }
            }
        case .array(let items):
            arrayView(items)
        default:
            scalarView(node)
        }
    }

    @ViewBuilder private func entryRow(_ key: String, _ value: JSONNode) -> some View {
        if value.isContainer {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                keyText(key)
                JSONOutlineView(node: value)
                    .padding(.leading, DS.Space.md)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(.dsHairline).frame(width: 1).padding(.leading, DS.Space.xxs)
                    }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.sm) {
                keyText(key)
                scalarView(value)
            }
        }
    }

    @ViewBuilder private func arrayView(_ items: [JSONNode]) -> some View {
        if items.isEmpty {
            Text("(empty)").font(.dsCaption).foregroundStyle(.tertiary)
        } else if items.allSatisfy({ !$0.isContainer }) {
            // A scalar list reads best as one wrapped line, not one row per value.
            Text(items.map(scalarString).joined(separator: " · "))
                .font(.dsCaption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                ForEach(items.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        if items.count > 1 {
                            Text("\(i + 1)").font(.dsCodeMicro.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        JSONOutlineView(node: items[i])
                    }
                    if i < items.count - 1 { Divider().opacity(0.4) }
                }
            }
        }
    }

    private func keyText(_ key: String) -> some View {
        Text(key).font(.dsCodeMicro.weight(.medium)).foregroundStyle(.secondary)
    }

    @ViewBuilder private func scalarView(_ n: JSONNode) -> some View {
        switch n {
        case .string(let v):
            Text(v).font(.dsCaption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        case .number(let v):
            Text(v).font(.dsCaption.monospacedDigit()).foregroundStyle(Theme.gold)
        case .bool(let v):
            Text(v ? "true" : "false").font(.dsCodeMicro).foregroundStyle(Theme.pink)
        case .null:
            Text("null").font(.dsCaption).foregroundStyle(.tertiary)
        default:
            EmptyView()
        }
    }

    private func scalarString(_ n: JSONNode) -> String {
        switch n {
        case .string(let v): return v
        case .number(let v): return v
        case .bool(let b):   return b ? "true" : "false"
        case .null:          return "null"
        default:             return ""
        }
    }
}
