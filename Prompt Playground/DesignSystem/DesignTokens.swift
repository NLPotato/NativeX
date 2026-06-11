//
//  DesignTokens.swift
//  Prompt Playground
//
//  The ONLY source of font sizes, spacing, radius, and component chrome in views.
//  See design.md (repo root) for the rationale and the full token table. Views pull tokens
//  from here; they never hand-pick a literal. Primitives (the P3 palette) stay in Theme.swift —
//  this layer names their roles and assembles the component modifiers.
//

import SwiftUI

enum DS {
    /// 4pt grid. See design.md §3.2.
    enum Space {
        static let xxs: CGFloat = 2,  xs: CGFloat = 4,  sm: CGFloat = 8
        static let md:  CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
    }
    enum Radius { static let sm: CGFloat = 6, md: CGFloat = 8, lg: CGFloat = 12 }
    enum Size {
        static let control: CGFloat = 28, controlLarge: CGFloat = 32
        static let fieldMiniWidth: CGFloat = 88, fieldWideWidth: CGFloat = 220
        static let panelMinWidth: CGFloat = 360, panelIdealWidth: CGFloat = 420
        static let sheetMinWidth: CGFloat = 560, sheetIdealWidth: CGFloat = 620
    }
    enum Layout {
        static let paneInset = Space.xl, groupGap = Space.lg, fieldGap = Space.md
    }
    /// One editor line's height at `body` size — `dsEditor(lines:)` multiplies this.
    static let lineHeight: CGFloat = 22
}

// MARK: - Type (explicit sizes; macOS semantic styles run 2–3pt smaller — see design.md §2.3)

extension Font {
    static let dsDisplay = Font.system(size: 30, weight: .semibold)
    static let dsTitle   = Font.system(size: 22, weight: .semibold)
    static let dsHeading = Font.system(size: 17, weight: .semibold)
    static let dsBody    = Font.system(size: 15, weight: .regular)
    static let dsLabel   = Font.system(size: 14, weight: .medium)
    static let dsCaption = Font.system(size: 13, weight: .regular)
    static let dsMicro   = Font.system(size: 12, weight: .regular)
    static let dsCode    = Font.system(size: 14, weight: .regular, design: .monospaced)
    /// Mono at the micro (12pt) floor — port variable chips, API name chips, inline code badges.
    static let dsCodeMicro = Font.system(size: 12, weight: .regular, design: .monospaced)
}

// MARK: - Semantic state colors (primitives live in Theme.swift)
// Declared on `ShapeStyle where Self == Color` so they resolve with leading-dot syntax in
// `foregroundStyle(.dsDanger)` / `.fill(.dsAccent)` etc.

extension ShapeStyle where Self == Color {
    static var dsAccent:  Color { Theme.accent }
    static var dsWarning: Color { Theme.gold }
    static var dsDanger:  Color { .red }
    static var dsSuccess: Color { Theme.accent }
    static var dsInfo:    Color { Theme.cyan }   // neutral category accent (e.g. task badges)
    /// The ONE neutral hairline border (chips, fields, unselected node cards). One role, one value.
    static var dsHairline: Color { .white.opacity(0.10) }
}

// MARK: - Liquid Glass (floating chrome — see design.md §3.5/§4.5)

extension Glass {
    /// Accent-tinted glass for "active" floating chrome (the executing-node pill). §4.5.
    static var dsActive: Glass { .regular.tint(Theme.accent.opacity(0.15)) }
}

// MARK: - Component chrome

extension View {
    /// Single-line field control: one fill/border/radius + comfortable inner inset that matches the
    /// multi-line editor (a plain TextField has no internal text inset, so it needs more than 8). §4.1.
    func dsTextField() -> some View {
        textFieldStyle(.plain)
            .font(.dsBody)
            .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(.dsHairline, lineWidth: 1))
    }

    /// Multi-line editor chrome — same surface, height in line multiples. Caller sets the font
    /// (`.dsBody` or `.dsCode`).
    func dsEditor(lines: Int) -> some View {
        scrollContentBackground(.hidden)
            .padding(DS.Space.sm)
            .frame(minHeight: CGFloat(lines) * DS.lineHeight + DS.Space.sm * 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.sm).strokeBorder(.dsHairline, lineWidth: 1))
    }

    /// The one chip/badge: `.dsMicro` text in a tinted capsule (§4.4). Status tags, task badges,
    /// portability chips — every small capsule label routes through here.
    func dsBadge(_ color: Color) -> some View {
        font(.dsMicro.weight(.medium))
            .padding(.horizontal, DS.Space.sm).padding(.vertical, DS.Space.xxs)
            .background(color.opacity(0.22), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.5))
            .foregroundStyle(color)
    }

    /// Card surface. `raised` for "your"/selected/final blocks. Depth ≥ 1 → use `.dsFlat()`.
    /// `radius` defaults to md; floating top-level panels pass `DS.Radius.lg` (§3.3).
    func dsCard(raised: Bool = false, radius: CGFloat = DS.Radius.md) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return padding(DS.Space.lg).background {
            shape.fill(.ultraThinMaterial)
                .overlay { if raised { shape.fill(Theme.accent.opacity(0.14)) } }
                .overlay { shape.strokeBorder(Theme.accent.opacity(raised ? 0.5 : 0.12),
                                              lineWidth: raised ? 1.2 : 0.8) }
                .compositingGroup().shadow(color: .black.opacity(0.10), radius: 5, y: 2)
        }
    }

    /// Flat nested surface (no frost-on-frost) + accent depth rule. See design.md §3.5.
    func dsFlat() -> some View {
        padding(DS.Space.md)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: DS.Radius.sm))
            .overlay(alignment: .leading) { Rectangle().fill(Theme.accent.opacity(0.25)).frame(width: 3) }
    }
}

/// The one labeled-field component: label + control + (help | error). See design.md §4.1.
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
            .foregroundStyle(.secondary)
            .padding(.top, DS.Space.sm)
    }
}

// MARK: Running radiance — neon-green edge glow shown while a run is in flight.

/// Frames the four edges with a neon-green bloom while a generation is running. A bright lime
/// hot-spot sweeps the perimeter (life), the whole frame breathes (intensity). See `runningRadiance`.
private struct RunningRadiance: View {
    var corner: CGFloat
    @State private var sweep = false
    @State private var breathe = false

    var body: some View {
        // Bright lime concentrated, fading to faint accent — two hot-spots so every edge stays lit
        // while they travel around the frame.
        let gradient = AngularGradient(
            gradient: Gradient(stops: [
                .init(color: Theme.accent.opacity(0.30), location: 0.00),
                .init(color: Theme.lime,                 location: 0.12),
                .init(color: Theme.accent.opacity(0.30), location: 0.25),
                .init(color: Theme.accent.opacity(0.30), location: 0.50),
                .init(color: Theme.lime,                 location: 0.62),
                .init(color: Theme.accent.opacity(0.30), location: 0.75),
                .init(color: Theme.accent.opacity(0.30), location: 1.00),
            ]),
            center: .center,
            angle: .degrees(sweep ? 360 : 0))
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)

        ZStack {
            shape.strokeBorder(gradient, lineWidth: 6).blur(radius: 18)   // outer bloom, bleeds inward
            shape.strokeBorder(gradient, lineWidth: 3).blur(radius: 6)    // mid glow
            shape.strokeBorder(gradient, lineWidth: 1.5)                  // crisp neon edge
        }
        .opacity(breathe ? 1.0 : 0.55)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) { sweep = true }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { breathe = true }
        }
    }
}

extension View {
    /// Neon-green radiance framing the view's four edges while `active` (a run in flight). Tasteful
    /// "it's working" cue; non-interactive and fades in/out with the run.
    func runningRadiance(active: Bool, corner: CGFloat = DS.Radius.lg) -> some View {
        overlay { if active { RunningRadiance(corner: corner).transition(.opacity) } }
            .animation(.easeInOut(duration: 0.45), value: active)
    }
}
