# Prompt Playground — Design System

The **single source of truth** for every visual decision in the app: type, spacing, radius,
color, elevation, and the component specs built from them. No view may hand-pick a font size,
padding, or radius again — it pulls a token from here. This document is the contract; the Swift
in `DesignTokens.swift` (§7) is its machine-readable form.

> Scope: native macOS SwiftUI (`Prompt Playground/*.swift`). Tokens are platform-agnostic in
> intent so the visual language can carry to the wiekant iOS app, but the values below are tuned
> for a Mac desktop pro-tool (denser than iOS, looser than the macOS system default).

---

## 1. Why this exists (the current slop, measured)

A grep of the 25 view files on `dev`:

| Axis | Distinct values in use | Problem |
|---|---|---|
| Font | 77 of all `.font()` calls are `.caption`/`.caption2` | On macOS those are **~10–11pt**. The working surface is illegible-small; there is no scale, only "small." |
| Spacing | `0,1,2,4,5,6,8,10,12,14,16` (11 values) | Off-grid `5,7,14`; `6` used 23× and `8` 14× for the *same* role. No rhythm → "horrible margins." |
| Padding | `2,3,4,5,6,7,8,10,12,14,16` (11 values) | Same role padded 6 different ways. Text inputs especially inconsistent. |
| Radius | `4,5,6,8,10` (5 values) | Cards, chips, and fields each pick their own. |
| Text inputs | `.roundedBorder` TextFields **mixed with** bare `TextEditor` + `.overlay(stroke)` + `.glassCard` | Three different field chromes, four different heights (`40/56/84/240`), four widths (`40/44/160/200`). This is the "slop." |

The fix is not "bigger numbers." It is a **closed set of named tokens** and **one** component per role.

## 2. Principles

1. **Legibility floor.** Smallest text for anything a user reads or edits is **`caption` = 12pt**. `micro` = 11pt is for incidental chrome only (timestamps, badges). Nothing renders below 11.
2. **4pt grid.** Every gap, pad, and inset is a multiple of 4 drawn from the spacing scale. No raw literals in views.
3. **Explicit type, not macOS semantic styles.** Apple's macOS text styles run 2–3pt smaller than iOS (`.caption`≈10, `.body`≈13). We define explicit sizes so the app is legible and identical across contexts. (Trade-off: opts out of Dynamic Type — acceptable for a desktop pro-tool; revisit for the iOS port.)
4. **Semantic, not literal.** A view asks for `text.secondary` or `surface.card`, never `.primary.opacity(0.6)` or `.ultraThinMaterial` directly.
5. **One component per role.** One field, one card, one section header, one chip. Variants are parameters, not new code.
6. **Restraint.** Three radii, seven spaces, eight type roles, four surface levels. If a new value is "needed," first prove an existing token can't do the job.

---

## 3. Tokens

### 3.1 Type scale

Explicit sizes (pt) + weight. `regular` 400 · `medium` 500 · `semibold` 600.

| Token | Size / Weight | `lineSpacing` | Role | Replaces |
|---|---|---|---|---|
| `display` | 30 / semibold | 4 | Empty-state hero, hero metric | — |
| `title` | 22 / semibold | 3 | Pane title, sheet title | `.title3`(15), `.headline`-as-title |
| `heading` | 17 / semibold | 2 | Section & card headers, disclosure titles | `.callout`+`.semibold` headers |
| `body` | 15 / regular | 3 | Primary content: prompt, instructions, output, model text | `.body`(13), `.callout`(12) content |
| `label` | 14 / medium | 0 | Field labels, control labels | `.subheadline`, `.footnote`, `.caption` labels |
| `caption` | 13 / regular | 2 | Help text, secondary metadata — **the readable floor** | `.caption`(10) |
| `micro` | 12 / regular | 0 | Incidental chrome only: badges, timestamps, counts | `.caption2`(11) |
| `code` | 14 / mono | 2 | JSON / code / mono fields | `.system(.caption/.callout/.body, .monospaced)` |

Color pairs with type via §3.4 (e.g. `label` → `text.secondary`, `caption` help → `text.tertiary`).

### 3.2 Spacing scale (4pt grid)

| Token | Value | Use |
|---|---|---|
| `space.xxs` | 2 | Icon↔text inside a chip; hairline only |
| `space.xs` | 4 | Label↔control; tight intra-row gaps |
| `space.sm` | 8 | Intra-component; default row/HStack gap |
| `space.md` | 12 | Between related fields in a group |
| `space.lg` | 16 | Card padding; gap between groups |
| `space.xl` | 24 | Section separation |
| `space.xxl` | 32 | Major region / pane top inset |

**Migration map** (old → token): `1,2→xxs` · `3,4,5→xs` · `6,7,8→sm` · `10,12→md` · `14,16→lg`. (Yes, the 23 uses of `6` and 14 of `8` collapse onto `sm`. That is the point.)

### 3.3 Radius

| Token | Value | Use |
|---|---|---|
| `radius.sm` | 6 | Chips, inline fields, small controls |
| `radius.md` | 8 | Cards, surfaces, sheet-inner blocks |
| `radius.lg` | 12 | Top-level / window-scale cards |

Map: `4,5,6→sm` · `8,10→md` · `12→lg`.

### 3.4 Color (semantic)

Primitives live in `Theme.swift` (icon-derived P3 palette); this layer names their **roles**. Views consume roles, never primitives.

| Role | Source | Use |
|---|---|---|
| `surface.canvas` | `Theme.backdrop` | Pane background |
| `surface.card` | `.ultraThinMaterial` | Default raised block |
| `surface.raised` | material + `accent@0.14` wash | "Your"/selected/final block |
| `surface.field` | `.quaternary` fill | Text-input & code background |
| `text.primary` | `.primary` | Titles, values, body |
| `text.secondary` | `.secondary` | Labels, captions, secondary content |
| `text.tertiary` | `.tertiary` | Help text, placeholders, incidental |
| `accent` | `Theme.accent` (lime) | Primary action, focus, active tokens |
| `border.subtle` | `accent@0.12` | Resting card edge |
| `border.focus` | `accent@0.5` | Focused field / highlighted card edge |
| `border.field` | `.separator` | Resting field edge |
| `success` | `Theme.accent` | OK stage glyphs |
| `warning` | `Theme.gold` | Unused-output, caveats, portability |
| `danger` | `.red` | Errors, destructive, over-budget |

Rule: **delete every `.primary.opacity(0.6)`** and ad-hoc `.opacity()` on text — use the three text roles.

### 3.5 Elevation

| Token | Material | Border | Shadow |
|---|---|---|---|
| `elev.flat` | `surface.field` | `border.field` 1px | none |
| `elev.card` | `surface.card` | `border.subtle` 0.8px | `black@0.10` r5 y2 |
| `elev.raised` | `surface.raised` | `border.focus` 1.2px | `black@0.10` r5 y2 |

Never nest `elev.card` inside `elev.card` (the frost-on-frost that read as "crammed"). A nested block uses `elev.flat` + the accent rule for depth.

### 3.6 Layout rhythm

| Token | Value | Use |
|---|---|---|
| `layout.paneInset` | 24 (`xl`) | ScrollView content padding inside each pane |
| `layout.groupGap` | 16 (`lg`) | Between top-level groups in a pane |
| `layout.fieldGap` | 12 (`md`) | Between fields within a group |
| `layout.panelMinWidth` | 360 | Left authoring pane min |
| `layout.sheetMinWidth` | 560 | Editor sheets |

---

## 4. Component specs

### 4.1 Field — the input-slop fix

**One** component for every labeled input. Structure:

```
VStack(alignment: .leading, spacing: space.sm)        // 8 — air under the label
  Text(label)            → label / text.secondary
  <control>              → §4.2
  Text(help or error)    → caption / text.tertiary (or danger)   // only if present
```

- **Single-line control**: horizontal inset **12** (`md`), vertical inset **8** (`sm`), height = text + insets (no fixed height). A plain `TextField` has no internal text inset, so 12/8 visually matches the multi-line editor's effective inset (its `NSTextView` adds ~5 on top of the 8). `surface.field` fill, `border.field` 1px, `radius.sm`. Focus → `border.focus`.
- **Multi-line control** (TextEditor): same fill/border/radius, `.scrollContentBackground(.hidden)`, inset **8**, height in **line multiples** — `prompt` = 3 lines (88), `instructions` = 12 lines (260), `command` = 3 lines.
- **Mono variant**: `code` font; everything else identical.
- **No bespoke widths.** Inline mini-fields (array bounds, hook in/out) use a single `fieldMiniWidth = 88`; full-width fields use `maxWidth: .infinity`. Kill `40/44/160/200`.
- **Error state**: `border.danger` + `danger` help line. **Optional/disabled**: 0.5 opacity on the row, not the control.

This single spec replaces the `.roundedBorder` ⁄ `TextEditor+overlay` ⁄ `glassCard` mix.

### 4.2 Card

`elev.card`, padding `space.lg` (16), `radius.md`. `raised: true` → `elev.raised`. Depth ≥ 1 → `elev.flat`, never another card.

### 4.3 Section header

`micro`-uppercase, weight semibold, kerning 0.6, `text.secondary`, top pad `space.sm`. (One style — the current `PROMPT`/`PIPELINE` headers conform once promoted.)

### 4.4 Controls

| Control | Height | Notes |
|---|---|---|
| Default button / picker / toggle row | 28 (`control`) | `space.sm` gaps |
| Primary action (Run) | 32 (`controlLarge`) | full-width, prominent, accent |
| Chip / badge | intrinsic | `micro`, pad `xxs`/`sm`, `radius.sm`, `Capsule()` for pills |

---

## 5. Governance

- **No raw literals in views.** Font size, spacing, padding, radius, and text opacity come from tokens. A CI/grep guard (§8) flags `\.font\(\.(caption2?|footnote|callout|body)\)`, `spacing: \d`, `\.padding\(\d`, `cornerRadius: \d`, `\.opacity\(0\.` in `*.swift` views.
- **New views adopt tokens from line one.** No "match the surrounding ad-hoc style."
- **Changing a token is a deliberate edit here**, reviewed, then it propagates. Values do not get tuned per-call-site.

---

## 6. Migration / rollout (phased — each phase builds + visually verifies)

1. **Add `DesignTokens.swift`** (§7). `Theme.swift` keeps the P3 primitives; tokens reference them. No view changes yet → builds, zero visual diff.
2. **Promote `GlossView` (Single-shot)** — the worst offender and the tab under review. Replace every literal with a token; route all inputs through `DSField`. Verify on device.
3. **Sweep the shared editors** — `SchemaEditorView`, `GenConfigControls`, `HooksEditorView`, the sheets.
4. **Remaining tabs** — `RoleplayView`, `PipelineView`, `DatasetsView`, `StageCard`.
5. **Lint guard** (§8) wired into the build; fix stragglers.

Each phase is independently revertible. Do not big-bang all 25 files.

---

## 7. `DesignTokens.swift` (drop-in)

```swift
import SwiftUI

/// Design tokens — the ONLY source of sizes/spacing/radius in views. See design.md.
enum DS {
    enum Space {
        static let xxs: CGFloat = 2,  xs: CGFloat = 4,  sm: CGFloat = 8
        static let md:  CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
    }
    enum Radius { static let sm: CGFloat = 6, md: CGFloat = 8, lg: CGFloat = 12 }
    enum Size {
        static let control: CGFloat = 28, controlLarge: CGFloat = 32
        static let fieldMiniWidth: CGFloat = 88
        static let panelMinWidth: CGFloat = 360, sheetMinWidth: CGFloat = 560
    }
    enum Layout {
        static let paneInset = Space.xl, groupGap = Space.lg, fieldGap = Space.md
    }
}

// MARK: Type — explicit sizes (macOS semantic styles run 2–3pt smaller; see design.md §2.3)
extension Font {
    static let dsDisplay = Font.system(size: 30, weight: .semibold)
    static let dsTitle   = Font.system(size: 22, weight: .semibold)
    static let dsHeading = Font.system(size: 17, weight: .semibold)
    static let dsBody    = Font.system(size: 15, weight: .regular)
    static let dsLabel   = Font.system(size: 14, weight: .medium)
    static let dsCaption = Font.system(size: 13, weight: .regular)
    static let dsMicro   = Font.system(size: 12, weight: .regular)
    static let dsCode    = Font.system(size: 14, weight: .regular, design: .monospaced)
}

// MARK: Semantic color roles (primitives stay in Theme.swift)
extension Color {
    static let dsAccent  = Theme.accent
    static let dsWarning = Theme.gold
    static let dsDanger  = Color.red
    static let dsSuccess = Theme.accent
}

// MARK: Component modifiers
extension View {
    /// Single-line field control chrome: comfortable inner inset, consistent fill/border/radius.
    func dsTextField() -> some View {
        textFieldStyle(.plain).font(.dsBody)
            .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(.separator, lineWidth: 1))
    }

    /// Multi-line editor chrome: same surface, line-multiple height.
    func dsEditor(lines: Int) -> some View {
        font(.dsBody)
            .scrollContentBackground(.hidden).padding(DS.Space.sm)
            .frame(minHeight: CGFloat(lines) * 22 + DS.Space.sm * 2)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(.separator, lineWidth: 1))
    }

    /// Card surface. `raised` for "your"/selected blocks. Depth ≥ 1 → use `.dsFlat()` instead.
    func dsCard(raised: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
        return padding(DS.Space.lg).background {
            shape.fill(.ultraThinMaterial)
                .overlay { if raised { shape.fill(Theme.accent.opacity(0.14)) } }
                .overlay { shape.strokeBorder(Theme.accent.opacity(raised ? 0.5 : 0.12),
                                              lineWidth: raised ? 1.2 : 0.8) }
                .compositingGroup().shadow(color: .black.opacity(0.10), radius: 5, y: 2)
        }
    }

    /// Flat nested surface (no frost-on-frost) + accent depth rule.
    func dsFlat() -> some View {
        padding(DS.Space.md)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            .overlay(alignment: .leading) { Rectangle().fill(Theme.accent.opacity(0.25)).frame(width: 3) }
    }
}

/// Labeled field — the one input component. See design.md §4.1.
struct DSField<Control: View>: View {
    let label: String
    var help: String? = nil
    var error: String? = nil
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text(label).font(.dsLabel).foregroundStyle(.secondary)
            control()
            if let error { Text(error).font(.dsCaption).foregroundStyle(.dsDanger) }
            else if let help { Text(help).font(.dsCaption).foregroundStyle(.tertiary) }
        }
    }
}

/// Uppercase section divider. See design.md §4.3.
struct DSSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased())
            .font(.dsMicro.weight(.semibold)).kerning(0.6)
            .foregroundStyle(.secondary).padding(.top, DS.Space.sm)
    }
}
```

---

## 8. Lint guard (optional, Phase 5)

A pre-build run-script phase or `git grep` check that fails on raw visual literals in view files:

```sh
# flags ad-hoc font/spacing/padding/radius/opacity in views (allow DesignTokens.swift + Theme.swift)
git grep -nE '\.font\(\.(caption2?|footnote|callout|body)\)|spacing: ?[0-9]|\.padding\([^)]*[0-9]|cornerRadius: ?[0-9]|\.opacity\(0\.[0-9]' -- 'Prompt Playground/*.swift' \
  ':!Prompt Playground/DesignTokens.swift' ':!Prompt Playground/Theme.swift'
```

---

## Appendix — token quick-reference

```
type:    display 30sb · title 22sb · heading 17sb · body 15 · label 14m · caption 13 · micro 12 · code 14 mono
space:   xxs 2 · xs 4 · sm 8 · md 12 · lg 16 · xl 24 · xxl 32        (4pt grid)
radius:  sm 6 · md 8 · lg 12
size:    control 28 · controlLarge 32 · fieldMini 88 · panelMin 360 · sheetMin 560
text:    primary · secondary · tertiary          (no ad-hoc opacity)
surface: canvas · card · raised · field
border:  subtle .12 · focus .5 · field separator
state:   accent · success · warning(gold) · danger(red)
```
