# Prompt Playground

Native **macOS SwiftUI** bench (pure Swift, no Expo/JS bridge) to iterate on Apple **Foundation Models** prompts, `@Generable` schemas, and configs that ship to the **wiekant** Expo app (`/Users/lwj/workspace/wiekant`, same on-device model on iOS — asset parity means a prompt tuned here behaves the same on iPhone). This Mac is just the faster iteration surface.

**Docs index:** `docs/REGISTRY.yml` — per-domain canonical references (read first).

## Hard rule
Never add `#Playground { }` auto-run blocks — Xcode auto-runs them and crashes/re-instantiates the model. Test via the SwiftUI app; run destination **My Mac**.

**Never invoke the `expo-libs` skill (or any Expo/JS-oriented skill) here.** This is a pure native Swift macOS app — no Expo, no JS bridge. That skill is irrelevant. For Foundation Models, `GlossPlayground.swift` is the canonical in-repo usage example; `docs/reference/foundation-models.md` is the API-truths + gotchas reference.

## Structure (orientation for coding agents)
`ContentView.swift` is a 4-tab `TabView` (seeds the store on first launch): three engine-backed **flows** (Gloss, Role-play, Lab) — each an input view + `@Observable` engine — plus a **Datasets** CRUD manager. All share one SwiftData store (`Storage.swift`) and one core layer (`PlaygroundCore.swift`).

Every output schema runs in one of **two lanes**:
- **Typed** (default) — compile-time `@Generable` structs. The canonical lane that ships to wiekant; keeps typed metrics + tappable UI. Add one: a `@Generable` struct (file scope, app target) + a `PromptPreset` entry; nothing else changes.
- **Dynamic** (prototyping, additive — never the default) — a UI-authored `SchemaDef` tree compiled at runtime to `DynamicGenerationSchema`. Run instantly, persist, or codegen back to a typed `@Generable` to promote it. See `docs/reference/foundation-models.md`.

### Flow 1 — Gloss (single-shot)
- `GlossPlayground.swift` — `@Generable` schemas + `PromptPreset` registry (`presets`) + `PlaygroundModel` engine (fresh session per run, availability check).
- `GlossView` (in `ContentView.swift`) — input/output surface.

### Flow 2 — Role-play (multi-turn)
- `RoleplayPlayground.swift` — nested `@Generable` (`RoleplayLineGen`/`RoleplayTurnGen`) + `RoleplayModel` engine (ONE persistent `LanguageModelSession` across turns, `[Turn]` log, `start()`/`send()`, 5-field `{{learning}}/{{native}}/{{situation}}/{{you}}/{{ai}}` substitution).
- `RoleplayView.swift` — 5-field scene setup + live transcript (reply + 2 tappable suggestions + translations per turn) + composer.

### Datasets (curation) — tab between Role-play and Lab
- `DatasetsView.swift` — master–detail manager: list datasets (both tasks), view/add/edit/delete `ExampleModel`s, and create/rename/duplicate/delete `DatasetModel`s over the shared store. `ExampleEditorSheet` switches form on task (`GlossInput`/`RoleplayInput`); writes mirror `SaveToPipeline`. Reference-free — examples carry inputs only (expected outputs = roadmap).

### Flow 3 — Lab (batch eval) — ⚠ tab label only; code is still `Pipeline*`
LangSmith-style layer that fans a prompt variant over a dataset and scores it.
- `Pipeline.swift` — `ExperimentRunner` (fan a variant over a dataset; persist; progress+cancel).
- `PipelineView.swift` — configure/run experiments, leaderboard, scorecard, manual ratings, judge, export.
- `Runners.swift` — headless `GlossRunner` (one-shot) + `RoleplayRunner` (scripted multi-turn, auto-advances on `suggestions[0]`).
- `Metrics.swift` — objective evaluators, `RunMetrics`, composite `Scoring`, `VariantStats`, `GoldenThresholds` (ship gates). `GenericEvaluator` scores dynamic-lane runs (no typed bundle).
- `Judge.swift` — on-device LLM-as-judge (`JudgeScore` 1–5) + judge-vs-human `Agreement`.
- `GoldenExport.swift` — export winner → `Documents/golden/*.json` to bundle into wiekant.
- `SaveToPipeline.swift` — `SaveToPipelineSheet`: bridges Gloss/Role-play → the store (prompt → versioned `PromptTemplateModel`; input → `ExampleModel`; custom schema → `SchemaModel` + Swift codegen). Reached via each tab's **Save to pipeline…** button.

> **Naming:** the **Lab** tab was formerly "Pipeline" — only the tab label changed. Files (`Pipeline.swift`, `PipelineView.swift`, `SaveToPipeline.swift`), types (`PipelineView`, `SaveToPipelineSheet`), and the "Save to pipeline…" buttons keep the `Pipeline` name in code.

### Shared layers
- `PlaygroundCore.swift` — `TaskKind`; `GenConfig` (Codable mirror of `GenerationOptions`); `TokenEstimator` (**Apple exposes NO token API** — ESTIMATED: CJK≈1 tok/char else ≈1 tok/4 chars; 4096 window per Apple TN3193); `LanguageTools` (NaturalLanguage); shared `prettyJSON`; `ModelAvailability`.
- `Storage.swift` — SwiftData models: `PromptTemplateModel` + `SchemaModel` (both versioned), `DatasetModel`→`ExampleModel`, `ExperimentModel`→`RunModel`, + `GlossInput`/`RoleplayInput`.
- `SeedData.swift` — first-launch templates + starter datasets (incl. Starbucks barista).
- **Dynamic-schema lane:** `SchemaDef.swift` (Codable node-tree + walker/validation, `maxDepth=3`) · `SchemaBuilder.swift` (`SchemaDef`→`GenerationSchema`; `DynamicRun.respond`) · `SwiftCodegen.swift` (`SchemaDef`→`@Generable` source) · `DynamicRunner.swift` (headless dynamic runs) · `SchemaEditorView.swift` (recursive editor) · `GenConfigControls.swift` (shared config UI).

### Placeholders
Lab + seeds use canonical `{{learning}}/{{native}}`; the Gloss tab still emits legacy `{{source}}/{{target}}` (runners accept both; saving to the Lab canonicalizes them).

## Sync to wiekant (on request)
The latest wiekant prompts live on its **`feat/prompting`** branch — read them with `git -C /Users/lwj/workspace/wiekant show feat/prompting:<path>` or `git grep <term> feat/prompting`, **NOT** the working tree (it may sit on an older branch). When the user says a prompt/config is final, port it into wiekant: locate the matching `@Generable`/prompt via a **targeted grep** (never a full read), confirm the file with the user, then edit. Record the resolved path here after the first sync.

## Requirements
macOS 26+, Apple silicon, Apple Intelligence enabled (Siri language must match device language).
