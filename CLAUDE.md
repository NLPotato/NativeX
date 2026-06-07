# Prompt Playground

Native **macOS SwiftUI** bench (pure Swift, no Expo/JS bridge) to iterate on Apple **Foundation Models** prompts, `@Generable` schemas, and configs that ship to the **wiekant** Expo app (`/Users/lwj/workspace/wiekant`, same on-device model on iOS — asset parity means a prompt tuned here behaves the same on iPhone). This Mac is just the faster iteration surface.

**Docs index:** `docs/REGISTRY.yml` — per-domain canonical references (read first).

## Hard rule
Never add `#Playground { }` auto-run blocks — Xcode auto-runs them and crashes/re-instantiates the model. Test via the SwiftUI app; run destination **My Mac**.

**Never invoke the `expo-libs` skill (or any Expo/JS-oriented skill) here.** This is a pure native Swift macOS app — no Expo, no JS bridge. That skill is irrelevant. For Foundation Models, `GlossPlayground.swift` is the canonical in-repo usage example; `docs/reference/foundation-models.md` is the API-truths + gotchas reference.

## Architecture
- `Prompt Playground/GlossPlayground.swift` — single-turn gloss: `@Generable` schemas + `PromptPreset` registry (`presets`) + `PlaygroundModel` engine (fresh session per run, `{{source}}`/`{{target}}` substitution, availability check).
- `Prompt Playground/RoleplayPlayground.swift` — multi-turn role-play: nested `@Generable` (`RoleplayLineGen`/`RoleplayTurnGen`) + `RoleplayModel` engine (ONE persistent `LanguageModelSession` across turns, `[Turn]` log, `start()`/`send()`, 5-field `{{learning}}/{{native}}/{{situation}}/{{you}}/{{ai}}` substitution).
- `Prompt Playground/ContentView.swift` — `TabView` shell over `GlossView`, `RoleplayView`, and `PipelineView`; seeds the store on first launch.
- `Prompt Playground/RoleplayView.swift` — role-play surface: 5-field scene setup + live transcript (reply + 2 tappable suggestions + translations per turn) + composer.
- To test a new schema: add a `@Generable` struct (file scope, app target) + a `PromptPreset` entry. Nothing else changes.

## LLMOps pipeline (Pipeline tab)
Batch-eval layer over the two engines. New files in `Prompt Playground/`:
- `PlaygroundCore.swift` — `TaskKind`; `GenConfig` (Codable mirror of `GenerationOptions`); `TokenEstimator` (**Apple exposes NO token API** — usage is ESTIMATED: CJK≈1 tok/char else ≈1 tok/4 chars; 4096 window per Apple TN3193); `LanguageTools` (NaturalLanguage); shared `prettyJSON`; `ModelAvailability`.
- `Metrics.swift` — objective evaluators, `RunMetrics`, composite `Scoring`, `VariantStats`, `GoldenThresholds` (ship-ready gates).
- `Runners.swift` — headless `GlossRunner` (one-shot) + `RoleplayRunner` (scripted multi-turn, auto-advances on `suggestions[0]`).
- `Pipeline.swift` — `ExperimentRunner` (fan a variant over a dataset, persist, progress+cancel).
- `Storage.swift` — SwiftData models (`PromptTemplateModel` versioned, `DatasetModel`→`ExampleModel`, `ExperimentModel`→`RunModel`) + `GlossInput`/`RoleplayInput`.
- `SeedData.swift` — first-launch templates + starter datasets (incl. Starbucks barista).
- `Judge.swift` — on-device LLM-as-judge (`JudgeScore` 1–5) + judge-vs-human `Agreement`.
- `GoldenExport.swift` — export winner → `Documents/golden/*.json` to bundle into wiekant.
- `PipelineView.swift` — configure/run experiments, leaderboard, scorecard, manual ratings, judge, export.
- `SaveToPipeline.swift` — `SaveToPipelineSheet`: bridge from the Gloss/Role-play tabs into the store. Promotes the live prompt → versioned `PromptTemplateModel` (auto-bumps version per name) and/or the live input → `ExampleModel` in a chosen/new dataset. Role-play captures the transcript's user turns as the replay script; gloss canonicalizes `{{source}}/{{target}}`→`{{learning}}/{{native}}`.

Convention: pipeline + seeds use canonical `{{learning}}/{{native}}`; the single-shot **Gloss** tab still has legacy `{{source}}/{{target}}` (runners accept both; promoting to the pipeline canonicalizes them). Each playground tab has a **Save to pipeline…** button (see `SaveToPipeline.swift`).

## Sync to wiekant (on request)
The latest wiekant prompts live on its **`feat/prompting`** branch — read them with `git -C /Users/lwj/workspace/wiekant show feat/prompting:<path>` or `git grep <term> feat/prompting`, **NOT** the working tree (it may sit on an older branch). When the user says a prompt/config is final, port it into wiekant: locate the matching `@Generable`/prompt via a **targeted grep** (never a full read), confirm the file with the user, then edit. Record the resolved path here after the first sync.

## Requirements
macOS 26+, Apple silicon, Apple Intelligence enabled (Siri language must match device language).
