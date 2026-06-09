//
//  DynamicRunner.swift
//  Prompt Playground
//
//  Headless run engine for the DYNAMIC lane (a custom SchemaDef) — the generic, task-agnostic
//  counterpart to TextRunner. Streams against a runtime GenerationSchema and scores with the
//  schema-agnostic RunEvaluator. Built-in test tasks run their own dynamic variants under their
//  namespaces (Gloss.runDynamic / Roleplay.runDynamic).
//

import Foundation
import FoundationModels

@MainActor
enum DynamicRunner {
    /// Generic lane with a custom output schema: pre-hooks → resolve → STREAM the dynamic schema →
    /// post-hooks, assembling the same staged RunTrace as the text lane. Metrics are scored on the
    /// RAW model JSON; the stored output reflects any post-hook transform.
    static func run(template: String, input: RunInput, def: SchemaDef, config: GenConfig,
                    hooks: HookPipelineDef, prewarm: Bool = false) async -> RunResultData {
        await RunPipeline.run(template: template, input: input, config: config, hooks: hooks,
                              prewarm: prewarm, schemaInjected: true,
                              expectedLanguageKeys: ["native", "learning"]) { session, prompt in
            let schema = try SchemaBuilder.generationSchema(from: def)
            var raw = ""
            var ttft: Int? = nil
            let s = Date()
            for try await snapshot in session.streamResponse(to: prompt, schema: schema,
                                                             includeSchemaInPrompt: true,
                                                             options: config.toOptions()) {
                if ttft == nil { ttft = millis(since: s) }
                raw = snapshot.rawContent.jsonString          // cumulative — last snapshot is complete
            }
            return (prettyJSONString(raw), ttft, millis(since: s))
        }
    }
}
