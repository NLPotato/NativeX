# Prompt Playground

Native **macOS SwiftUI** bench (pure Swift, no Expo/JS bridge) to iterate on Apple **Foundation Models** prompts, `@Generable` schemas, and configs that ship to the **wiekant** Expo app (`/Users/lwj/workspace/wiekant`, same on-device model on iOS — asset parity means a prompt tuned here behaves the same on iPhone). This Mac is just the faster iteration surface.

**Docs index:** `docs/REGISTRY.yml` — per-domain canonical references (read first).

## Hard rule
Never add `#Playground { }` auto-run blocks — Xcode auto-runs them and crashes/re-instantiates the model. Test via the SwiftUI app; run destination **My Mac**.

**Never invoke the `expo-libs` skill (or any Expo/JS-oriented skill) here.** This is a pure native Swift macOS app — no Expo, no JS bridge. That skill is irrelevant. For Foundation Models, `Core/GraphExecutor.swift` (live model calls) and `Tasks/Gloss.swift` (runtime `DynamicGenerationSchema`) are the canonical in-repo usage examples; `docs/reference/foundation-models.md` is the API-truths + gotchas reference.

## Structure (orientation for coding agents)
`App/ContentView.swift` is a `NavigationSplitView` left menu (seeds the store on first launch) with two pages: **Playground** — the original 3-tab `TabView` (**Graph** authoring · **Datasets** CRUD · **Lab** batch eval) — and **Run History** (run log). All share one SwiftData store (`Models/Storage.swift`) and one core layer (`Core/PlaygroundCore.swift`).

Files are grouped **by layer**: `App/` (entry + root tabs) · `Views/` (SwiftUI screens) · `Engines/` (`@Observable` view-models) · `Models/` (SwiftData + node tree) · `Core/` (generic, task-agnostic headless logic + shared utilities) · `Tasks/` (the built-in test tasks — `Gloss`, `Roleplay` — each a self-contained namespace) · `DesignSystem/` (tokens + theme). Swift has no folder-namespacing — folders are organizational only.

Every output schema runs in one of **two lanes**:
- **Typed** (default) — compile-time `@Generable` structs. The canonical lane that ships to wiekant; keeps typed metrics. Add one: a `@Generable` struct (file scope, app target) wired into the Lab runner.
- **Dynamic** (prototyping, additive — never the default) — a UI-authored `SchemaDef` tree compiled at runtime to `DynamicGenerationSchema`. Run instantly, persist, or codegen back to a typed `@Generable` to promote it. See `docs/reference/foundation-models.md`.

### Graph tab — authoring (unifies the former single-shot + chat tabs)
Visual node-DAG editor: typed nodes (prompt groups; instruction/few-shot/history/current-turn blocks; input sources; native-API/hook processors; FM calls; compare nodes) wired into a graph, topologically executed.
- `Views/GraphView.swift` · `Views/GraphCanvas.swift` · `Views/NodeInspector.swift` — canvas + inspector UI.
- `Engines/GraphEngine.swift` — `@Observable` view-model (graph state, transform, selection, mutation API).
- `Models/GraphCore.swift` — `GraphDef`/`GraphNode`/`GraphEdge` + node kinds; `Storage.swift` persists `GraphModel`.
- `Core/GraphExecutor.swift` (topo-sort + per-node dispatch + live FM calls; emits an `ExecTrace` per run → Run History; `run(_:row:)` injects a batch row at a dataset-bound Input) · `Core/GraphValidator.swift` (pre-run checks) · `Core/GraphMigration.swift` (legacy-format migration).
- `Core/GraphBatchRunner.swift` — **batch lane**: bind an Input to a dataset (`source: .dataset`) and the toolbar's "Run dataset" fans the graph over every row → one `ExperimentModel` (shows in the Lab). Reuses `GraphExecutor.run(_:row:)` + the `RunResult.asRunResultData()` bridge (graph run → `RunModel`). *(Phase 1 of the [[graph-batch-compare-plan]].)*
- `Core/GraphCompareRunner.swift` + `Views/CompareResultView.swift` — **compare lane**: a `.compare` node references N prompt groups (`ComparePayload.laneGroupIDs`, reference-collector — not nested); "Run comparison" (its inspector) executes the graph ONCE, collects each lane's FM output side-by-side, and persists M `ExperimentModel`s under one `sweepID` (a Lab sweep → `VariantStats` leaderboard). *(Phase 2 of [[graph-batch-compare-plan]]; "Insert example: compare" seeds a 2-lane A/B graph.)*

### Datasets tab — curation
- `Views/DatasetsView.swift` — master–detail manager over the shared store: list datasets (both tasks), CRUD `ExampleModel`s, create/rename/duplicate/delete `DatasetModel`s. `ExampleEditorSheet` switches form on task (`Gloss.Input`/`Roleplay.Input`/`RunInput`). Reference-free — examples carry inputs only (expected outputs = roadmap).

### Lab tab — batch eval — ⚠ tab label only; code is still `Pipeline*`
LangSmith-style layer that fans a prompt variant over a dataset and scores it.
- `Core/Pipeline.swift` — `ExperimentRunner` (fan a variant over a dataset; persist; progress+cancel).
- `Views/PipelineView.swift` — configure/run experiments, leaderboard, scorecard, manual ratings, judge, export.
- `Core/Runners.swift` — the generic, task-agnostic engine: `RunPipeline` (execution spine) + `TextRunner` (free-text). Built-in test-task runners live with their tasks in `Tasks/` (`Gloss.Runner` one-shot; `Roleplay.Runner` scripted multi-turn, auto-advances on `suggestions[0]`).
- `Core/Metrics.swift` — `RunMetrics`, composite `Scoring`, `VariantStats`, `GoldenThresholds` (ship gates), shared `Evaluators` helpers. `RunEvaluator` scores dynamic-lane runs (no typed bundle); each test task owns its `evaluate` in `Tasks/`.
- `Core/Judge.swift` — on-device LLM-as-judge (`JudgeScore` 1–5) + judge-vs-human `Agreement`.
- `Core/GoldenExport.swift` — export winner → `Documents/golden/*.json` to bundle into wiekant.
- `Tasks/Gloss.swift` / `Tasks/Roleplay.swift` — the two built-in **test tasks**, each a self-contained `enum` namespace (input · schema/DTOs · pipeline · runner · evaluator): `Gloss.Pipeline`/`Gloss.Result`/`Gloss.Runner`, `Roleplay.TurnGen`/`Roleplay.Runner`/`Roleplay.defaultInstructions`. They're fixtures the Lab runs headlessly — the generic core (`RunPipeline`/`RunEvaluator`/`Experiment`) never names a task.

> **Naming:** the **Lab** tab was formerly "Pipeline" — only the tab label changed. Files (`Pipeline.swift`, `PipelineView.swift`) and the `PipelineView` type keep the `Pipeline` name in code. The generic `TaskKind.custom` lane persists as rawValue `"generic"` (pinned for back-compat).

### Run History page — run log (observability)
LangSmith-style trace log of live executions. Each Graph run persists one `TraceModel` (a grouped record of *consecutive* steps); each FM node logs as an **LLM record** (final prompt in blocks · token estimates · output · sampling · error), each native-API/hook node as a **step** (op · input · output).
- `Views/RunHistoryView.swift` — master list of runs + per-step detail (reuses `StageCardView`).
- `Core/ExecTrace.swift` — the plain `ExecTrace`/`ExecStep` the executor returns; `GraphView` maps it to `TraceModel`. Logs Graph executions; the Lab keeps its own experiment history (leaderboard).

### Shared layers
- `Core/PlaygroundCore.swift` — `TaskKind`; `GenConfig` (Codable mirror of `GenerationOptions`); `TokenEstimator` (**Apple exposes NO token API** — ESTIMATED: CJK≈1 tok/char else ≈1 tok/4 chars; 4096 window per Apple TN3193); `LanguageTools` (NaturalLanguage); shared `prettyJSON`; `ModelAvailability`.
- `Models/Storage.swift` — SwiftData models: `PromptTemplateModel` + `SchemaModel` (both versioned), `DatasetModel`→`ExampleModel`, `ExperimentModel`→`RunModel`, `GraphModel`, `TraceModel` (run history), + `RunInput` (built-in tasks define their own `Gloss.Input`/`Roleplay.Input` in `Tasks/`); plus `JSONCoder`.
- `Core/HookEngine.swift` + `Core/HookDef.swift` — pre/post native-op hook pipeline (shared by the Graph executor + Lab runners).
- `Core/RunTrace.swift` — persisted staged trace + the shared `StageCardView` renderer.
- `Core/SeedData.swift` — first-launch templates + starter datasets (incl. Starbucks barista).
- **Dynamic-schema lane:** `Models/SchemaDef.swift` (Codable node-tree + walker/validation, `maxDepth=3`) · `Core/SchemaBuilder.swift` (`SchemaDef`→`GenerationSchema`; `DynamicRun.respond`) · `Core/SwiftCodegen.swift` (`SchemaDef`→`@Generable` source) · `Core/DynamicRunner.swift` (headless dynamic runs) · `Views/SchemaEditorView.swift` (recursive editor) · `Views/GenConfigControls.swift` (shared config UI).

### Placeholders
Lab + seeds use canonical `{{learning}}/{{native}}`; some legacy templates emit `{{source}}/{{target}}` (runners accept both; saving to the Lab canonicalizes them).

## Sync to wiekant (on request)
The latest wiekant prompts live on its **`feat/prompting`** branch — read them with `git -C /Users/lwj/workspace/wiekant show feat/prompting:<path>` or `git grep <term> feat/prompting`, **NOT** the working tree (it may sit on an older branch). When the user says a prompt/config is final, port it into wiekant: locate the matching `@Generable`/prompt via a **targeted grep** (never a full read), confirm the file with the user, then edit. Record the resolved path here after the first sync.

## Requirements
macOS 26+, Apple silicon, Apple Intelligence enabled (Siri language must match device language).
