//
//  DatasetImport.swift
//  Prompt Playground
//
//  Turn a picked .csv / .json file into a plain table (header columns + string rows) the Datasets tab
//  can lift into a `.custom` DatasetModel. Pure (Data → Table) — no SwiftData, no SwiftUI — so it stays
//  in the task-agnostic Core layer and is unit-testable. The column→{{var}} mapping is the graph's job
//  (bind an Input to the dataset, then auto-wire); this layer only exposes every column as a row value.
//

import Foundation

enum DatasetImport {
    /// A parsed file: the header `columns` (first-seen order) and each row as `{column: value}`.
    struct Table {
        var columns: [String]
        var rows: [[String: String]]
    }

    enum ImportError: LocalizedError {
        case empty, noColumns, badJSON, jsonNotObjects
        var errorDescription: String? {
            switch self {
            case .empty:        return "The file has no data rows."
            case .noColumns:    return "No column names found in the header row."
            case .badJSON:      return "Couldn’t parse the file as JSON."
            case .jsonNotObjects: return "Expected a JSON array of objects — each object becomes one row."
            }
        }
    }

    /// Dispatch on extension: `.json` → array-of-objects; anything else → CSV (the file picker only
    /// offers .csv / .json, so the else-branch is CSV in practice).
    static func parse(data: Data, filename: String) throws -> Table {
        if (filename as NSString).pathExtension.lowercased() == "json" { return try parseJSON(data) }
        return try parseCSV(data)
    }

    // MARK: CSV (RFC-4180: quoted fields, "" escapes, commas/newlines inside quotes, CRLF)

    private static func parseCSV(_ data: Data) throws -> Table {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              !text.isEmpty else { throw ImportError.empty }
        let records = csvRecords(text)
        guard let header = records.first else { throw ImportError.empty }
        let columns = header.map { $0.trimmingCharacters(in: .whitespaces) }
        guard columns.contains(where: { !$0.isEmpty }) else { throw ImportError.noColumns }

        var rows: [[String: String]] = []
        for rec in records.dropFirst() {
            if rec.count == 1, rec[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue } // blank line
            var row: [String: String] = [:]
            for (i, col) in columns.enumerated() where !col.isEmpty {
                row[col] = i < rec.count ? rec[i] : ""
            }
            rows.append(row)
        }
        guard !rows.isEmpty else { throw ImportError.empty }
        return Table(columns: columns.filter { !$0.isEmpty }, rows: rows)
    }

    /// Split CSV text into records of fields, honoring quotes. `\r\n`/`\r`/`\n` are one grapheme each
    /// (`Character.isNewline`), so a single check covers every line ending.
    private static func csvRecords(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 2; continue } // "" → "
                    inQuotes = false; i += 1; continue
                }
                field.append(c); i += 1
            } else if c == "\"" {
                inQuotes = true; i += 1
            } else if c == "," {
                record.append(field); field = ""; i += 1
            } else if c.isNewline {
                record.append(field); field = ""
                records.append(record); record = []
                i += 1
            } else {
                field.append(c); i += 1
            }
        }
        if !field.isEmpty || !record.isEmpty { record.append(field); records.append(record) } // flush last (no trailing newline)
        return records
    }

    // MARK: JSON (top-level array of objects; a lone object → one row)

    private static func parseJSON(_ data: Data) throws -> Table {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { throw ImportError.badJSON }
        let array: [Any]
        if let a = obj as? [Any] { array = a }
        else if let d = obj as? [String: Any] { array = [d] }
        else { throw ImportError.jsonNotObjects }

        var columns: [String] = []
        var seen = Set<String>()
        var rows: [[String: String]] = []
        for item in array {
            guard let dict = item as? [String: Any] else { throw ImportError.jsonNotObjects }
            var row: [String: String] = [:]
            for (k, v) in dict {
                row[k] = stringify(v)
                if seen.insert(k).inserted { columns.append(k) }
            }
            rows.append(row)
        }
        guard !rows.isEmpty else { throw ImportError.empty }
        return Table(columns: columns, rows: rows)
    }

    /// JSON scalar → display string. Booleans arrive as NSNumber, so distinguish them by CF type id
    /// (else `true` would stringify to "1"); nested arrays/objects fall back to compact JSON.
    private static func stringify(_ v: Any) -> String {
        switch v {
        case let s as String: return s
        case is NSNull: return ""
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "true" : "false" }
            return n.stringValue
        default:
            if let d = try? JSONSerialization.data(withJSONObject: v),
               let s = String(data: d, encoding: .utf8) { return s }
            return "\(v)"
        }
    }
}
