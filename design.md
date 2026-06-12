# NativeX Desktop — Design System

The **single source of truth** for every visual decision: type, spacing, radius, color, surface, node identity, and the component specs built from them. No view may hand-pick a font size, padding, or radius — it pulls a token from here. This document is the contract; `DesignSystem/DesignTokens.swift` is its machine-readable form.

> **Scope:** native macOS SwiftUI (dark-mode-only, macOS 26+). Tokens are tuned for a Mac desktop pro-tool — denser than iOS, looser than the macOS system default. Client iOS apps (e.g. wiekant, a language learning app) consume exported prompts from NativeX Desktop; they have their own design. Product spec: `docs/prd.md`.

---

## 1. Why this exists (the baseline, measured)

A grep of the 25 view files at the start of the token project:

| Axis | Distinct values in use | Problem |
|---|---|---|
| Font | 77 of all `.font()` calls were `.caption`/`.caption2` | On macOS those are ~10–11pt. Illegible-small; no scale, only "small." |
| Spacing | `0,1,2,4,5,6,8,10,12,14,16` (11 values) | Off-grid `5,7,14`; `6` used 23× and `8` 14× for the same role. No rhythm. |
| Padding | `2,3,4,5,6,7,8,10,12,14,16` (11 values) | Same role padded 6 different ways. Text inputs especially inconsistent. |
| Radius | `4,5,6,8,10` (5 values) | Cards, chips, and fields each pick their own. |
| Text inputs | `.roundedBorder` TextFields mixed with bare `TextEditor` + `.overlay(stroke)` + `.glassCard` | Three field chromes, four heights, four widths. |

The fix is a **closed set of named tokens** and **one component per role**.

---

## 2. Principles

### 2.1 Design principles

1. **Legibility floor.** Smallest readable text is `caption` = 13pt. `micro` = 12pt is for incidental chrome only (timestamps, badges). Nothing below 12.
2. **4pt grid.** Every gap, pad, and inset is a multiple of 4 from the spacing scale. No raw literals in views.
3. **Explicit type, not macOS semantic styles.** Apple's macOS text styles run 2–3pt smaller than iOS (`.caption`≈10, `.body`≈13). We define explicit sizes so the app is legible and consistent. See §3.1.
4. **Semantic, not literal.** A view asks for `text.secondary` or `surface.card` — never `.primary.opacity(0.6)` or `.ultraThinMaterial` directly.
5. **One component per role.** One field, one card, one section header. Variants are parameters, not new code.
6. **Restraint.** Three radii, seven spaces, eight type roles, four surface levels. If a new value feels necessary, first prove an existing token can't do the job.

### 2.2 Product principles → visual implications

See `docs/prd.md §4` for the full rationale.

| Principle | Visual rule |
|---|---|
| **Platform Superset** | macOS-only features carry a `dsWarning` (gold) portability badge. iOS-portable features carry a `dsInfo` (cyan) badge. |
| **UX-First** | Official Apple API names appear as a secondary `.dsCode` chip on every node header. Node families have a distinct color identity. Execution state lives on the canvas, not in a separate tab. |
| **Native-First** | Liquid Glass for chrome surfaces. Opaque cards for content. SF Symbols throughout — no custom icons where a system symbol fits. |

### 2.3 60-30-10 color rule

- **60% — neutral base.** `Theme.backdrop`, `.secondary`, `.tertiary`, system backgrounds. The dominant tone of every surface.
- **30% — category color.** One color per node family (cyan family for prompt blocks, gold for macOS-only, pink for Compare). Prompt blocks differentiate further with quiet-but-separate hues inside the family (see §5.2). Applied as a tinted border, icon color, or subtle fill. Never a solid color wash.
- **10% — accent (`Theme.accent`, neon green).** Reserved strictly for: the primary Run button, active/selected states, FM node radiance, and run success. An **idle FM node is neutral** — no green border or icon; green appears on it only while running (radiance) or selected. If a surface "feels too green," it is using more than 10%.
- **Variables & wiring are cyan, not accent.** Port chips, `{{var}}` highlights, port dots, pending wires, and the group out-port all use `Theme.cyan` (the prompt-data hue). Sidebar selection and navigation chrome stay neutral (`.quaternary`). Accent never marks "wired/configured" — only "running/selected/succeeded/primary action".

---

## 3. Tokens

### 3.1 Type scale

All font tokens live in `DesignTokens.swift`. Use them exclusively.

| Token | Size / Weight | Role |
|---|---|---|
| `.dsDisplay` | 30 / semibold | Empty-state hero, hero metric |
| `.dsTitle` | 22 / semibold | Pane title, sheet title |
| `.dsHeading` | 17 / semibold | Section & card headers, disclosure titles |
| `.dsBody` | 15 / regular | Primary content: prompts, instructions, output |
| `.dsLabel` | 14 / medium | Field labels, control labels, node primary labels |
| `.dsCaption` | 13 / regular | Help text, secondary metadata — **the readable floor** |
| `.dsMicro` | 12 / regular | Incidental chrome only: badges, timestamps, counts |
| `.dsCode` | 14 / mono | JSON, code blocks, inspector API names |
| `.dsCodeMicro` | 12 / mono | Port variable chips, canvas API name chips — mono at the micro floor |

Color pairs with type via §3.4 (e.g. `.dsLabel` → `.secondary`, `.dsCaption` help → `.tertiary`).

### 3.2 Spacing scale (4pt grid)

| Token | Value | Use |
|---|---|---|
| `DS.Space.xxs` | 2 | Icon↔text inside a chip; hairline only |
| `DS.Space.xs` | 4 | Label↔control; tight intra-row gaps |
| `DS.Space.sm` | 8 | Intra-component; default row/HStack gap |
| `DS.Space.md` | 12 | Between related fields in a group |
| `DS.Space.lg` | 16 | Card padding; gap between groups |
| `DS.Space.xl` | 24 | Section separation; pane inset |
| `DS.Space.xxl` | 32 | Major region / pane top inset |

**Migration map** (old → token): `1,2→xxs` · `3,4,5→xs` · `6,7,8→sm` · `10,12→md` · `14,16→lg`.

### 3.3 Radius

| Token | Value | Use |
|---|---|---|
| `DS.Radius.sm` | 6 | Chips, badges, inline fields |
| `DS.Radius.md` | 8 | Node cards, surfaces, sheet-inner blocks |
| `DS.Radius.lg` | 12 | Floating pills, panels, top-level cards |

Map: `4,5,6→sm` · `8,10→md` · `12→lg`.

### 3.4 Color (semantic roles)

Primitives live in `Theme.swift` (P3 palette, icon-derived). Views consume roles, never primitives.

| Role token | Source | Use |
|---|---|---|
| `dsAccent` | `Theme.accent` (neon green) | Primary action, focus, active — **10% budget** |
| `dsWarning` | `Theme.gold` | macOS-only badge, `Hook` node identity, caution |
| `dsDanger` | `.red` | Errors, destructive actions, over-budget |
| `dsSuccess` | `Theme.accent` | Completion states (same hue as accent) |
| `dsInfo` | `Theme.cyan` | iOS·macOS badge, prompt block identity, neutral info |

Palette reference (all `Theme.swift` P3):

| Name | Approx hex | 30% role |
|---|---|---|
| `Theme.accent` | #75FB00 | Run button, FM node radiance, selected state |
| `Theme.gold` | #EDCF4A | `Hook` border, macOS-only badge |
| `Theme.pink` | #FF68D4 | `Compare` node identity |
| `Theme.cyan` | #70FFEF | Prompt block identity, iOS·macOS badge |
| `Theme.lime` | #8ADC2E | Radiance hot-spot only — never used as a fill |
| `Theme.backdrop` | Dark charcoal gradient | App-wide window background — never override |

Text roles: `.primary` / `.secondary` / `.tertiary` / `.quaternary`. Never use `.opacity()` on text to fake vibrancy — use the semantic foreground styles.

### 3.5 Surface hierarchy (Liquid Glass model)

macOS 26 Liquid Glass is **lensing**, not blurring. It bends and concentrates background light rather than diffusing it. The governing rule:

> **Glass belongs on the chrome layer. It must never enter the content layer.**

| Layer | What goes here | Material |
|---|---|---|
| **System chrome** | Sidebar, toolbar, tab bar | System-managed Liquid Glass — do not re-apply |
| **Floating chrome** | Run controls pill, executing-node pill, error toast, inspector panel, sheets | `.glassEffect(.regular, in: shape)` via `GlassEffectContainer` |
| **Non-content-heavy nodes** | Compact node headers: `Input`, `Native API`, `Hook`, `Compare` header chip, `Foundation Model` header chip | `.glassEffect(.regular, in: RoundedRectangle(cornerRadius: DS.Radius.md))` |
| **Content-heavy nodes** | Nodes with text editors: `Prompt Group`, `Instruction`, `Few-shot`, `History`, `Current Turn`, `Guided Output` | Opaque — `.dsCard()` / `.dsFlat()` |
| **Panel cards** | Inspector row groups, sheet content blocks | `.dsCard()` (`.ultraThinMaterial` — pending `.glassEffect` migration; see §8) |

**Glass-on-glass rule:** Never stack two `.glassEffect` surfaces directly. When multiple glass elements coexist in the same region (e.g. toolbar + executing pill), wrap them in `GlassEffectContainer` so the system merges them into one optical piece.

**Old `elev.*` token reference (still used in existing code):**

| Token | Material | Border | Shadow |
|---|---|---|---|
| `elev.flat` (→ `.dsFlat()`) | `.quaternary` | — | none |
| `elev.card` (→ `.dsCard()`) | `.ultraThinMaterial` | `accent@0.12` 0.8px | `black@0.10` r5 y2 |
| `elev.raised` (→ `.dsCard(raised: true)`) | material + `accent@0.14` | `accent@0.5` 1.2px | `black@0.10` r5 y2 |

Never nest `elev.card` inside `elev.card` (frost-on-frost). A nested block uses `elev.flat` + accent rule for depth.

### 3.6 Layout rhythm

| Token | Value | Use |
|---|---|---|
| `DS.Layout.paneInset` | 24 (`xl`) | ScrollView content padding inside each pane |
| `DS.Layout.groupGap` | 16 (`lg`) | Between top-level groups in a pane |
| `DS.Layout.fieldGap` | 12 (`md`) | Between fields within a group |
| `DS.Size.panelMinWidth` | 360 | Inspector panel min width |
| `DS.Size.sheetMinWidth` | 560 | Editor sheets min width |

---

## 4. Components

### 4.1 Field — `DSField`

**One** component for every labeled input. Structure:

```
VStack(alignment: .leading, spacing: DS.Space.sm)
  Text(label)          → .dsLabel, .secondary
  <control>            → single-line or multi-line
  Text(error or help)  → .dsCaption, .dsDanger or .tertiary
```

- **Single-line:** horizontal inset `DS.Space.md`, vertical `DS.Space.sm`. `.quaternary` fill, subtle separator border, `DS.Radius.sm`. Focus → `accent@0.5` border.
- **Multi-line:** same fill/border/radius, `.scrollContentBackground(.hidden)`, height in line multiples using `DS.lineHeight` (22pt).
- **Mono variant:** `.dsCode` font; everything else identical.
- **No bespoke widths.** Mini inline fields use `DS.Size.fieldMiniWidth` (88pt); full-width fields use `.infinity`.

**`api:` parameter — inline API annotation.** `DSField` accepts an optional `api:` string that appends a `.dsCodeMicro` tertiary mono suffix on the label line naming the exact official Apple API symbol/argument the control feeds (e.g. `"NLTokenizer.setLanguage : NLLanguage"`, `"@Generable struct Name"`). These strings come exclusively from `Core/APICatalog.swift` structured data (`APIArgument.param` / `.fromInput`) — never hand-written prose. Placement rule: inline on the label line for full-width rows only. In narrow or half-width rows the caption must not middle-truncate into unreadability — stack the field full-width instead, or drop the `api:` caption. The caption must never visually outweigh its label; long explanations belong in `help:`, not `api:`.

### 4.2 Cards

- `.dsCard(raised: Bool)` — frosted `.ultraThinMaterial` + accent border. `raised: true` adds accent tint fill and brighter border for selected/active state.
- `.dsFlat()` — flat nested surface (no frost, no shadow). `.quaternary` background + 3pt left accent stripe. Use at depth ≥ 1 inside a card.
- `.dsGroup()` — quiet grouping container (white@0.04 fill + hairline, radius `md`, pad `md`). Clusters related rows/blocks into one visual unit (inspector sections, Run History stages inside a step card). No frost — nests safely anywhere (§3.5).

### 4.3 Section divider — `DSSectionHeader`

`.dsMicro` uppercase, weight semibold, kerning 0.6, `.secondary`, top padding `DS.Space.sm`. Never use inside a list row or node body.

### 4.4 Controls

| Control | Height | Notes |
|---|---|---|
| Default button / picker / toggle row | 28pt (`DS.Size.control`) | `DS.Space.sm` gaps |
| Primary action (Run button) | 32pt (`DS.Size.controlLarge`) | Full-width, prominent, `dsAccent` fill |
| Chip / badge | Intrinsic | `.dsBadge(color)` — `.dsMicro` medium in a tinted capsule (`color@0.22` fill, `color@0.45` 0.5px stroke, pad `sm`/`xxs`). One modifier for every status/task/portability tag. |

### 4.5 Glass chrome components

These are floating chrome — they live above the content layer and use `.glassEffect`.

| Component | Shape | Notes |
|---|---|---|
| Run controls pill (canvas, bottom-left) | `Capsule` | `.glassEffect(.regular, in: Capsule())` |
| Executing-node pill (canvas, top-center) | `Capsule` | `.glassEffect(.regular.tint(Theme.accent.opacity(0.15)), in: Capsule())` — accent tint signals "active" |
| Error toast (canvas, top-right, dismissible) | `RoundedRectangle(cornerRadius: DS.Radius.lg)` | `.glassEffect(.regular)`, `dsDanger` icon, `.dsCaption` message |
| Compare config sheet chrome | `.sheet` | Sheet container = glass; inner content area = `.dsCard()` |
| Inspector panel | `.inspector(isPresented:)` | System-managed; do not apply `.glassEffect` manually |

When multiple glass components coexist (pill + toast + toolbar), use `GlassEffectContainer` to merge them.

---

## 5. Node Visual Taxonomy

### 5.1 Canvas layer rule

The graph canvas is the content layer. Node **bodies** containing text editors are opaque (`.dsCard()` / `.dsFlat()`). Node **header chips and compact variants** — those with only a title, icon, port dots, and badge — use `.glassEffect` because they carry no heavy content. This follows the macOS 26 HIG exactly.

### 5.2 Color identity by node family

Category color = the 30% budget. Applied as a tinted border, icon color, or accent stripe — never a solid fill.

| Node | Family | Category color | Body surface |
|---|---|---|---|
| `Foundation Model` | Execution | Neutral at idle (hairline border, secondary icon); `dsAccent` radiance while running, accent border/glow when selected | Glass header, opaque body |
| `Prompt Group` | Container | `dsAccent` @ 40% tint on selected state | Opaque `.dsCard()` |
| `Instruction`, `Few-shot`, `History`, `Current Turn` | Prompt block | Quiet-but-separate hues in the cyan family — Instruction `Theme.cyan`, Few-shot `Theme.teal`, History `Theme.violet`, Current Turn `Theme.blue` — as left stripe + icon + header wash | `.dsFlat()` nested inside Prompt Group |
| `Guided Output`, `Tool` | Schema / tool block | `dsInfo` @ 60% | `.dsFlat()` |
| `Input` | Data source | Neutral — no category color | Glass header chip |
| `Native API` | Utility | `dsInfo` portability badge only | Glass header chip |
| `Hook (Script)` | Developer / power | `dsWarning` (gold) border + badge | Glass header chip + gold accent border |
| `Compare` | Analysis | `Theme.pink` border | Glass header chip, opaque body |

### 5.3 Running radiance

Defined in `DesignTokens.swift` as `.runningRadiance(active:)`. Applies **only** to `Foundation Model` nodes while a generation is in flight.

Effect: `Theme.lime` hot-spot sweeps the perimeter over a `Theme.accent`-tinted border glow with a breathing opacity animation (4s sweep, 1.4s breathe). Fades in/out with `.easeInOut(0.45)`.

Never apply to other node types. This is the single use of `Theme.lime` in the entire app.

---

## 6. UX-First Patterns

### 6.1 Friendly label + official Apple API name (node level)

Every node exposes two labels: a friendly primary label and the underlying Apple API name. The friendly label is `.dsLabel`; the API name is a quiet neutral chip (`.tertiary` foreground, no border) — `.dsCodeMicro` on the compact canvas header (with `layoutPriority` so it survives the squeeze over the kind label), `.dsCode` on its own full-width row in the inspector header (never truncated).

For per-argument API annotation inside a node's inspector, see the `api:` parameter on `DSField` (§4.1). This is the UX-First principle applied at interaction granularity: a developer learns the Foundation Models / NaturalLanguage API by using the GUI and can predict the code their settings produce — annotation at the point of interaction, not in a separate reference panel.

```
Node canvas header:   Foundation Model  ·  LanguageModelSession
Inspector top row:    Foundation Model     (LanguageModelSession)
```

Full mapping:

| Node | Friendly label | Apple API name |
|---|---|---|
| Foundation Model | Foundation Model | `LanguageModelSession` |
| Instruction block | Instruction | `Instructions` |
| Few-shot block | Few-shot | `Transcript` |
| Current turn block | Current turn | `Prompt` |
| Guided Output block | Guided Output | `DynamicGenerationSchema` |
| History block | History | `Transcript.Entry` |
| Tool block | Tool | `Tool` |
| Hook — script | Hook · Script | `/bin/zsh` |
| Hook — regex extract/replace | Regex … | `Regex` |
| Hook — JSON extract | JSON extract | `JSONSerialization` |
| Hook — text transform | Text transform | `Foundation` |
| Native API — tokenize / split sentences | Tokenize Words / Split sentences | `NLTokenizer` |
| Native API — enrich tokens | Enrich tokens | `NLTagger` |
| Native API — detect language | Detect Language | `NLLanguageRecognizer` |
| Native API — evaluate *(planned)* | Evaluate | `ModelJudgeEvaluator` |
| Native API — OCR *(planned)* | OCR | `OCRTool` |
| Native API — barcode *(planned)* | Barcode | `BarcodeReaderTool` |
| Native API — spotlight *(planned)* | Spotlight Search | Spotlight |
| Prompt Group | Prompt Group | `LanguageModelSession` (the request it builds) |
| Compare | Compare | `ComparePayload` |
| Input | Input | — (plain data source, no chip) |

### 6.2 Portability badges

Portability lives in the **inspector only** — a labeled `.dsBadge` capsule below the title. Canvas node headers stay minimal (title · kind · API name · status dot); per-node platform icons on the board read as noise at graph scale.

| Badge | SF Symbol | Color | Meaning |
|---|---|---|---|
| iOS · macOS | `laptopcomputer.and.iphone` | `dsInfo` (cyan) | Runs sandboxed on both platforms |
| macOS only | `laptopcomputer` | `dsWarning` (gold) | Requires sandbox off; client apps cannot use this |

For a node that contains children of mixed tiers (e.g. a Prompt Group with a Script Hook child wired to it), the group badge shows the most restrictive tier of its subgraph.

### 6.3 Canvas execution feedback

All execution feedback lives on the canvas. No navigation to Run History is required to understand what just happened.

| Event | Component | Design details |
|---|---|---|
| Node currently executing | Top-center capsule pill | Glass capsule, `"Running: [node name]"`, `.dsLabel`, `dsAccent` tint (`Theme.accent.opacity(0.15)`) |
| FM node generation complete | Radiance fades out | `.runningRadiance(active: false)` → `.easeInOut(0.45)` |
| Run error | Top-right toast (tap to dismiss) | Glass rounded rect, `exclamationmark.circle` SF Symbol in `dsDanger`, error message `.dsCaption` |
| Single-run result | Inline card beneath the FM node | Opaque `.dsCard()`, output text `.dsBody`, token count `.dsMicro .tertiary` |

### 6.4 Prompt group = managed stack

A Prompt group's members are auto-laid-out as one tidy left-aligned column (`GraphEngine.autoLayoutGroup`): blocks stack top→bottom in assembly order, the frame shrink-wraps the stack (16pt pad, 12pt gap). Dragging a block above/below a sibling re-orders the prompt — the stack snaps tidy on drop; the inspector's block list offers the same via up/down arrows. Free-form placement inside a group is intentionally NOT preserved: position **is** order, so the layout always shows the truth.

### 6.5 Declaration-driven op editors

Node/op editors are **generated from the op's declaration** — never hand-built per op. This is required for scalability: adding a new native API op must require zero new UI code.

- **`HookOp.paramKeys`** lists only the real API arguments for that op. The inspector iterates this list; unlisted arguments never appear.
- **`HookParam.control`** declares the widget: `.text` renders a free-text field (supports `{{vars}}`); `.choice([...])` renders a picker — closed sets are never typed as magic strings in text fields.
- **`HookOp.returnShape`** (`text | list | number | object`) drives the single shared **"Output as" `OutputProjection` control** (visible only for list shapes; object shapes emit canonical JSON). One control handles every op — no per-op output UI.
- **Catalog pickers** (op/API picker): at rest, a combo-box row showing the current selection; on expand, a framework-grouped searchable list. Planned (non-selectable) entries live in a folded disclosure — never occupying resting space.

---

## 7. Governance

- **No raw literals in views.** Font size, spacing, padding, radius, and text opacity come from tokens. A CI grep guard (§10) flags violations.
- **New views adopt tokens from line one.** No "match the surrounding ad-hoc style."
- **Changing a token is a deliberate edit here**, reviewed, then it propagates. Values are not tuned per call-site.
- **Glass-on-glass is never acceptable.** Use `GlassEffectContainer` when multiple glass surfaces share a region.
- **10% accent budget is a hard cap.** Before adding any new green element, check the existing accent usage in the view.

---

## 8. Migration / rollout

Each phase builds + visually verifies before the next starts. Each is independently revertible.

1. **Token foundation** (`DesignTokens.swift`) ✅ — Zero visual diff. No view changes.
2. **Promote Graph/Playground views** — Replace literals with tokens; route all inputs through `DSField`. Verify on device.
3. **Sweep shared editors** — `SchemaEditorView`, `GenConfigControls`, `HooksEditorView`, sheets.
4. **Remaining tabs** — `PipelineView`, `DatasetsView`, `RunHistoryView`, `StageCard`.
5. **Liquid Glass chrome** — Migrate floating chrome components (pills, toasts, inspector wrapper) from `.dsCard()` / `.ultraThinMaterial` to `.glassEffect(.regular)`. Wrap co-located glass in `GlassEffectContainer`. Content-heavy node bodies stay on `.dsCard()` permanently.
6. **Node taxonomy** — Apply category color identity per §5.2. Migrate compact node headers to `.glassEffect`.
7. **Lint guard** (§10) — Wire into build; fix any stragglers.

Do not big-bang all files. Phase 5 (Liquid Glass) must come after token cleanup or the migration surface is too noisy.

---

## 9. `DesignTokens.swift` reference

Current implementation is in `DesignSystem/DesignTokens.swift`. Key public surface:

```swift
// Spacing
DS.Space.xxs / xs / sm / md / lg / xl / xxl

// Radius
DS.Radius.sm / md / lg

// Size
DS.Size.control / controlLarge / fieldMiniWidth / fieldWideWidth
DS.Size.panelMinWidth / panelIdealWidth / sheetMinWidth / sheetIdealWidth

// Layout
DS.Layout.paneInset / groupGap / fieldGap
DS.lineHeight    // 22pt — used by dsEditor(lines:)

// Fonts (extension on Font)
.dsDisplay / .dsTitle / .dsHeading / .dsBody
.dsLabel / .dsCaption / .dsMicro / .dsCode / .dsCodeMicro

// Semantic colors (extension on ShapeStyle where Self == Color)
.dsAccent / .dsWarning / .dsDanger / .dsSuccess / .dsInfo / .dsHairline

// View modifiers
.dsTextField()
.dsEditor(lines: Int)
.dsCard(raised: Bool, radius: CGFloat = DS.Radius.md)
.dsFlat()
.dsGroup()
.dsBadge(_ color: Color)
.runningRadiance(active: Bool, corner: CGFloat)

// Components
DSField<Control: View>(label:, help:?, error:?)
DSSectionHeader(_ title: String)
```

---

## 10. Lint guard

Pre-build run-script or `git grep` check. Fails on raw visual literals in view files:

```sh
git grep -nE '\.font\(\.(largeTitle|title2?|title3|headline|subheadline|body|callout|footnote|caption2?)\)|\.system\(size:|spacing: ?[1-9]|\.padding\([^)]*[0-9]|cornerRadius: ?[0-9]|\.(primary|secondary|tertiary|quaternary)\.opacity\(|foregroundStyle\(\.[a-zA-Z]+\.opacity|\.ultraThinMaterial' \
  -- 'Prompt Playground/*.swift' \
  ':!Prompt Playground/DesignSystem/DesignTokens.swift' \
  ':!Prompt Playground/DesignSystem/Theme.swift'
```

What it catches — and what it deliberately allows:

- **Catches** macOS semantic text styles (`.body`, `.caption`, …), raw font sizes (`.system(size:)` — including `Font.system(size:)`), off-grid spacing/padding/radius literals, **text-vibrancy opacity** (`.primary.opacity(…)`, `foregroundStyle(.x.opacity(…))` — §3.4 says use semantic roles), and raw `.ultraThinMaterial` in views (chrome → `.glassEffect`, content → `.dsCard()`).
- **Allows** `spacing: 0` (a "no gap" declaration, trivially on the 4pt grid) and opacity on *shape* paints (borders, fills, shadows, canvas wires): §3.4/§5.2 themselves mandate category-color tints like `accent@0.12` and "dsInfo @ 60%", so a blanket `.opacity(` ban would contradict the spec. Repeated tint patterns still belong behind a DS modifier (`.dsBadge`, `.dsHairline`) — the grep just doesn't police one-off sanctioned tints.

---

## Appendix — token quick-reference

```
type:    display 30sb · title 22sb · heading 17sb · body 15 · label 14m · caption 13 · micro 12 · code 14 mono · codeMicro 12 mono
space:   xxs 2 · xs 4 · sm 8 · md 12 · lg 16 · xl 24 · xxl 32        (4pt grid)
radius:  sm 6 · md 8 · lg 12
size:    control 28 · controlLarge 32 · fieldMini 88 · panelMin 360 · sheetMin 560
text:    primary · secondary · tertiary · quaternary      (no ad-hoc opacity)
surface: backdrop · card (.ultraThinMaterial) · raised (card + accent tint) · flat (.quaternary)
glass:   floating chrome → .glassEffect(.regular) · content nodes → opaque · never glass-on-glass
accent:  dsAccent (green, 10%) · dsInfo/cyan (30% prompt) · dsWarning/gold (30% macOS-only) · Theme.pink (30% Compare)
state:   accent · success · warning(gold) · danger(red)
```
