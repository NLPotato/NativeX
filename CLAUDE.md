# NativeX Desktop (codebase: Prompt Playground)

Native **macOS SwiftUI** developer workbench for Apple **Foundation Models** — prompt design, schema modeling, batch eval, and execution tracing. Finalized prompts and `@Generable` schemas export into client iOS apps with behavioral parity: a prompt that passes evaluation here runs identically on-device. Canonical client is **wiekant** (`/Users/lwj/workspace/wiekant`), a language-learning iOS app that *consumes* prompts built here (not a NativeX product).

**Read first:**
- [docs/prd.md](docs/prd.md) — product spec: features, persona, principles, OS/API-availability matrix. Section refs (§5.x) below point here.
- [design.md](design.md) — design-system SSOT: tokens, node identity, component specs. No view hand-picks a font/padding/radius. Machine form: `DesignSystem/DesignTokens.swift`.
- [docs/REGISTRY.yml](docs/REGISTRY.yml) — canonical-doc index per domain + code-path→owning-doc map. The Foundation Models API reference (truths + gotchas) is `docs/reference/foundation-models.md`.

## Hard rules
- **macOS ↔ iOS parity (two faces of one product).** The iOS port (`/Users/lwj/workspace/nativeX`, Expo/RN) runs the *same* native frameworks as this app — FoundationModels, NaturalLanguage, Vision are API-identical on macOS 26 / iOS 26. A native-API change here — a new/edited `HookOp`, an availability gate, catalog `since`/`fallback`/`status` metadata, the `ModelAvailability` shape — must be mirrored in the iOS repo in the **same** change, and vice-versa. Only platform-inherent differences diverge: `script` (`/bin/zsh`) is macOS-only; UI is SwiftUI here vs RN/`@expo/ui` there. iOS counterpart files: `lib/graph/hooks.ts` (op metadata), `modules/foundation-models/ios/NativeOps.swift` (op impls), `modules/foundation-models/ios/NativeXFMModule.swift` (`getAvailability`). Distinct from prompt-export-to-**wiekant** below (a consumer, not a port).
- **Never** add `#Playground { }` auto-run blocks — Xcode auto-runs them and crashes/re-instantiates the model. Test via the SwiftUI app; run destination **My Mac**.
- **Never** invoke `expo-libs` (or any Expo/JS skill) — pure native Swift, no JS bridge. For live FM usage read `Core/GraphExecutor.swift`; for runtime `DynamicGenerationSchema` read `Tasks/Gloss.swift`; for API truths read `docs/reference/foundation-models.md`.

## Orientation
- **Shell** (`App/ContentView.swift`): `NavigationSplitView` — left `GraphListSidebar` (saved graphs, pinned-first), right `WorkspaceTabs`, a 4-tab `TabView`: **Playground** (graph authoring, tag 0) · **Datasets** (tag 1) · **Lab** (tag 2) · **Run History** (tag 3). All share one SwiftData store + one core layer. (§5.1)
- **Layering:** `App/` entry+tabs · `Views/` screens · `Engines/` `@Observable` view-models · `Models/` SwiftData + node tree · `Core/` task-agnostic headless logic + utilities · `Tasks/` built-in test tasks · `DesignSystem/` tokens. Folders are organizational only — Swift has no folder namespaces.
- **Two output lanes** (§5.3): **Typed** (default; ships to wiekant) — compile-time `@Generable` structs wired into the Lab runner. **Dynamic** (prototyping, additive — never the default) — a UI-authored `SchemaDef` compiled at runtime to `DynamicGenerationSchema`; run, persist, or codegen back to a typed struct to promote it.

## Key files
The load-bearing files only — start here, then follow the folder layout above for the rest (paths relative to `Prompt Playground/`).

| File | Why it's a starting point |
|---|---|
| `Core/GraphExecutor.swift` | Execution heart: topo-sort + per-node dispatch + live FM calls. The canonical in-repo Foundation Models usage. |
| `Models/Storage.swift` | The shared SwiftData store every tab reads/writes — all persisted model types live here. |
| `Models/GraphCore.swift` | The graph data model: `GraphDef`/`GraphNode`/`GraphEdge` + node kinds. |
| `Engines/GraphEngine.swift` | `@Observable` graph view-model — state + the mutation API the canvas/inspector drive. |
| `Core/PlaygroundCore.swift` | Shared primitives: `TaskKind`, `GenConfig`, `TokenEstimator`, `LanguageTools`, `ModelAvailability`. |
| `Core/APICatalog.swift` | node/op → Apple API registry; drives the op picker and every node's "API mapping" inspector section. Paired with the add-an-op flow (Gotchas). |
| `Core/HookEngine.swift` | Native-op + script hook pipeline, shared by the executor and the Lab. |
| `Core/Pipeline.swift` | `ExperimentRunner` — the Lab/eval spine (fan a variant over a dataset). |
| `Tasks/Gloss.swift` | Reference built-in task and the in-repo runtime `DynamicGenerationSchema` example. |

## Gotchas & conventions
- **Add a native op** = a `HookOp` case (with `returnShape` + `paramKeys`) + an `APICatalog` entry + a `HookEngine.apply` branch + the op name in `NodeInspector`'s per-node-kind `candidates` list. Only the last is hardcoded — the one step the build won't catch. Inspector fields are declaration-driven; version-gate via `since`/`fallback` on the catalog entry. (See [[native-api-node-direction]].)
- **Node naming = two families, opposite priorities** (ADR-20260615). **API-mirror nodes** (Native API / Hook): card leads with the faithful Apple symbol at the API's granularity — one-shot→**method**; stateful type→**type** (one node per type, so duplicates merge with the arg as an inspector control); distinct task recipe→**type** task node with the scheme disclosed in the inspector. **Structural nodes** (Prompt + its blocks): card leads with the **friendly LLM name, NO API caption** — the Apple type is a "Compiles to" inspector row; the Guided node is dual-lane (Registered `@Generable`→`GenerationSchema` | Custom→`DynamicGenerationSchema`). Default vars = official arg/return names; doc link = the captioned symbol's exact page. Plumbing: `APICatalogEntry.member`→`cardCaption` (API-mirror); `GraphNode.apiName` (structural). Full rule, examples & why: PRD §4.2 · `ADR-20260615` · [[native-api-faithful-display]] · [[structural-node-naming]].
- **Lab naming:** the **Lab** tab was formerly "Pipeline" — only the label changed; files/types keep `Pipeline*`. The generic `TaskKind.custom` lane persists as rawValue `"generic"` (pinned for back-compat).
- **Placeholders:** canonical `{{learning}}/{{native}}`; legacy templates emit `{{source}}/{{target}}` (runners accept both; saving to the Lab canonicalizes).

## Prompt export to wiekant (on request)
wiekant's prompts live on the **`feat/prompting`** branch — read with `git -C /Users/lwj/workspace/wiekant show feat/prompting:<path>` or `git grep <term> feat/prompting`, **not** the working tree. To port a final prompt/config: grep for the matching `@Generable`/prompt, confirm with the user, then edit. Record the resolved path here after the first sync.

## Requirements
macOS 26+, Apple Silicon, Apple Intelligence enabled (Siri language must match device language). API availability by OS version: §6.3.
