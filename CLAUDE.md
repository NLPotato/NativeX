# Prompt Playground

Native **macOS SwiftUI** bench (pure Swift, no Expo/JS bridge) to iterate on Apple **Foundation Models** prompts, `@Generable` schemas, and configs that ship to the **wiekant** Expo app (`/Users/lwj/workspace/wiekant`, same on-device model on iOS — asset parity means a prompt tuned here behaves the same on iPhone). This Mac is just the faster iteration surface.

**Docs index:** `docs/REGISTRY.yml` — per-domain canonical references (read first).

## Hard rule
Never add `#Playground { }` auto-run blocks — Xcode auto-runs them and crashes/re-instantiates the model. Test via the SwiftUI app; run destination **My Mac**.

**Never invoke the `expo-libs` skill (or any Expo/JS-oriented skill) here.** This is a pure native Swift macOS app — no Expo, no JS bridge. That skill is irrelevant. For Foundation Models, `Core/GraphExecutor.swift` (live model calls) and `Models/GlossPlayground.swift` (runtime `DynamicGenerationSchema`) are the canonical in-repo usage examples; `docs/reference/foundation-models.md` is the API-truths + gotchas reference.

## Structure (orientation for coding agents)
`App/ContentView.swift` is a 3-tab `TabView` (seeds the store on first launch): **Graph** (authoring), **Datasets** (CRUD), **Lab** (batch eval). All share one SwiftData store (`Models/Storage.swift`) and one core layer (`Core/PlaygroundCore.swift`).

Files are grouped **by layer**: `App/` (entry + root tabs) · `Views/` (SwiftUI screens) · `Engines/` (`@Observable` view-models) · `Models/` (SwiftData + `@Generable` DTOs + node tree) · `Core/` (headless logic + shared utilities) · `DesignSystem/` (tokens + theme). Swift has no folder-namespacing — folders are organizational only.

Every output schema runs in one of **two lanes**:
- **Typed** (default) — compile-time `@Generable` structs. The canonical lane that ships to wiekant; keeps typed metrics. Add one: a `@Generable` struct (file scope, app target) wired into the Lab runner.
- **Dynamic** (prototyping, additive — never the default) — a UI-authored `SchemaDef` tree compiled at runtime to `DynamicGenerationSchema`. Run instantly, persist, or codegen back to a typed `@Generable` to promote it. See `docs/reference/foundation-models.md`.

### Graph tab — authoring (unifies the former single-shot + chat tabs)
Visual node-DAG editor: typed nodes (prompt groups; instruction/few-shot/history/current-turn blocks; input sources; native-API/hook processors; FM calls) wired into a graph, topologically executed.
- `Views/GraphView.swift` · `Views/GraphCanvas.swift` · `Views/NodeInspector.swift` — canvas + inspector UI.
- `Engines/GraphEngine.swift` — `@Observable` view-model (graph state, transform, selection, mutation API).
- `Models/GraphCore.swift` — `GraphDef`/`GraphNode`/`GraphEdge` + node kinds; `Storage.swift` persists `GraphModel`.
- `Core/GraphExecutor.swift` (topo-sort + per-node dispatch + live FM calls) · `Core/GraphValidator.swift` (pre-run checks) · `Core/GraphMigration.swift` (legacy-format migration).

### Datasets tab — curation
- `Views/DatasetsView.swift` — master–detail manager over the shared store: list datasets (both tasks), CRUD `ExampleModel`s, create/rename/duplicate/delete `DatasetModel`s. `ExampleEditorSheet` switches form on task (`GlossInput`/`RoleplayInput`/`GenericInput`). Reference-free — examples carry inputs only (expected outputs = roadmap).

### Lab tab — batch eval — ⚠ tab label only; code is still `Pipeline*`
LangSmith-style layer that fans a prompt variant over a dataset and scores it.
- `Core/Pipeline.swift` — `ExperimentRunner` (fan a variant over a dataset; persist; progress+cancel).
- `Views/PipelineView.swift` — configure/run experiments, leaderboard, scorecard, manual ratings, judge, export.
- `Core/Runners.swift` — headless `GlossRunner` (one-shot) + `RoleplayRunner` (scripted multi-turn, auto-advances on `suggestions[0]`) + `GenericRunner`.
- `Core/Metrics.swift` — objective evaluators, `RunMetrics`, composite `Scoring`, `VariantStats`, `GoldenThresholds` (ship gates). `GenericEvaluator` scores dynamic-lane runs (no typed bundle).
- `Core/Judge.swift` — on-device LLM-as-judge (`JudgeScore` 1–5) + judge-vs-human `Agreement`.
- `Core/GoldenExport.swift` — export winner → `Documents/golden/*.json` to bundle into wiekant.
- `Models/GlossPlayground.swift` / `Models/RoleplayPlayground.swift` — the gloss + role-play **typed schemas + pipelines** the Lab runs headlessly (`GlossPipeline`, `GlossResultGen`, `RoleplayTurnGen`, `defaultRoleplayInstructions`). No interactive tab — eval-lane definitions only (the file names are historical; see Naming).

> **Naming:** the **Lab** tab was formerly "Pipeline" — only the tab label changed. Files (`Pipeline.swift`, `PipelineView.swift`) and the `PipelineView` type keep the `Pipeline` name in code. `*Playground.swift` likewise keep their names though they're no longer interactive playgrounds.

### Shared layers
- `Core/PlaygroundCore.swift` — `TaskKind`; `GenConfig` (Codable mirror of `GenerationOptions`); `TokenEstimator` (**Apple exposes NO token API** — ESTIMATED: CJK≈1 tok/char else ≈1 tok/4 chars; 4096 window per Apple TN3193); `LanguageTools` (NaturalLanguage); shared `prettyJSON`; `ModelAvailability`.
- `Models/Storage.swift` — SwiftData models: `PromptTemplateModel` + `SchemaModel` (both versioned), `DatasetModel`→`ExampleModel`, `ExperimentModel`→`RunModel`, `GraphModel`, + `GlossInput`/`RoleplayInput`/`GenericInput`; plus `JSONCoder`.
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
