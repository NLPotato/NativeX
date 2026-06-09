//
//  GoldenExport.swift
//  Prompt Playground
//
//  Phase 3: capture a winning Experiment (the variant + its scorecard + a few best outputs,
//  and for role-play the golden scenarios) into a self-contained JSON file to bundle into the
//  wiekant app. Written into the app's Documents/golden folder and revealed in Finder — no
//  extra sandbox entitlements needed; the user copies it into wiekant at sync time.
//

import Foundation
import AppKit

struct GoldenExemplar: Codable {
    var label: String
    var inputJSON: String
    var outputJSON: String
    var composite: Double
    var manualRating: Int?
    var judgeMean: Double?
}

struct GoldenExport: Codable {
    var task: String
    var exportedAt: String
    var templateName: String
    var templateVersion: Int
    var instructionsRaw: String        // template with {{vars}} — port this into wiekant
    var schemaID: String               // the @Generable schema this output matches
    var generationConfig: GenConfig
    var stats: VariantStats
    var goldenReady: Bool
    var exemplars: [GoldenExemplar]
    var scenarios: [Roleplay.Input]?    // role-play only: the golden scenes to bundle

    @MainActor
    static func build(from e: ExperimentModel) -> GoldenExport {
        let decoded = e.runs.filter(\.decoded).sorted { $0.composite > $1.composite }
        let exemplars = decoded.prefix(3).map { r in
            GoldenExemplar(label: r.exampleLabel, inputJSON: r.inputJSON,
                           outputJSON: r.turnsJSON ?? r.outputJSON, composite: r.composite,
                           manualRating: r.manualRating,
                           judgeMean: JSONCoder.decode(JudgeScore.self, r.judgeJSON)?.mean)
        }
        let stats = VariantStats.aggregate(
            e.runs.compactMap(\.metrics),
            manualRatings: e.runs.compactMap(\.manualRating),
            judgeScores: e.runs.compactMap { JSONCoder.decode(JudgeScore.self, $0.judgeJSON)?.mean })
        let scenarios = e.task == .roleplay
            ? e.runs.compactMap { JSONCoder.decode(Roleplay.Input.self, $0.inputJSON) }
            : nil
        return GoldenExport(
            task: e.task.rawValue,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            templateName: e.templateName, templateVersion: e.templateVersion,
            instructionsRaw: e.instructions, schemaID: e.schemaID,
            generationConfig: e.genConfig, stats: stats,
            goldenReady: GoldenThresholds.isGolden(stats, task: e.task),
            exemplars: Array(exemplars), scenarios: scenarios)
    }

    /// Write the export to Documents/golden and reveal it in Finder. Returns the file URL.
    @MainActor
    @discardableResult
    static func export(_ e: ExperimentModel) -> URL? {
        let json = prettyJSON(build(from: e))
        let dir = URL.documentsDirectory.appending(path: "golden", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let url = dir.appending(path: "golden-\(e.task.rawValue)-v\(e.templateVersion)-\(stamp).json")
        do {
            try Data(json.utf8).write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return url
        } catch {
            return nil
        }
    }
}
