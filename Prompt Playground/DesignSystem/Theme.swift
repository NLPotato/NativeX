//
//  Theme.swift
//  Prompt Playground
//
//  Visual theme derived from the app icon (jelly heart + gummy bear, rendered in Liquid Glass).
//  Colors use display-P3 so they match the icon's gradients exactly. The hero accent is the
//  gummy bear's neon green; the heart's pink/cyan and the gummy's gold are kept as supporting hues.
//

import SwiftUI

enum Theme {
    // Icon palette (display-P3, lifted straight from AppIcon.icon/icon.json).
    static let lime = Color(.displayP3, red: 0.541, green: 0.860, blue: 0.181) // gummy bear base
    static let gold = Color(.displayP3, red: 0.930, green: 0.815, blue: 0.291) // gummy bear highlight
    static let pink = Color(.displayP3, red: 1.000, green: 0.407, blue: 0.828) // jelly heart base
    static let cyan = Color(.displayP3, red: 0.441, green: 1.000, blue: 0.968) // jelly heart highlight

    /// Neon-green hero accent — vivid like the gummy bear but deep enough to stay legible
    /// under white control labels. Keep this in sync with Assets.xcassets/AccentColor.
    static let accent = Color(.displayP3, red: 0.457, green: 0.985, blue: 0.298) // #0FFF50

    // Prompt-block sub-hues (design.md §5.2): quiet-but-separate identities WITHIN the prompt family,
    // so a stacked Prompt group reads as distinct block kinds at a glance. Desaturated neighbors of the
    // cyan family anchor — never as loud as accent, never used for variables/wiring (that stays cyan).
    static let teal   = Color(.displayP3, red: 0.380, green: 0.870, blue: 0.760) // few-shot
    static let violet = Color(.displayP3, red: 0.730, green: 0.640, blue: 1.000) // history
    static let blue   = Color(.displayP3, red: 0.470, green: 0.730, blue: 1.000) // current turn

    /// Soft charcoal backdrop — dark enough that the neon-green accent pops, but not pure black.
    /// A subtle green→cool shift across the gradient ties it back to the icon's hues.
    static let backdrop = LinearGradient(
        colors: [
            Color(.displayP3, red: 0.14, green: 0.17, blue: 0.15),
            Color(.displayP3, red: 0.11, green: 0.12, blue: 0.14),
            Color(.displayP3, red: 0.12, green: 0.14, blue: 0.17)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let cardRadius: CGFloat = 12
}

extension View {
    /// App-wide tinted backdrop behind a pane.
    func playgroundBackground() -> some View {
        background(Theme.backdrop.ignoresSafeArea())
    }

    /// A frosted "Liquid Glass" card: translucent material, hairline accent edge, soft lift.
    /// `highlighted` adds a green wash + brighter edge for selected / "your" surfaces.
    func glassCard(radius: CGFloat = Theme.cardRadius, highlighted: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background {
            shape.fill(.ultraThinMaterial)
                .overlay { if highlighted { shape.fill(Theme.accent.opacity(0.14)) } }
                .overlay { shape.strokeBorder(Theme.accent.opacity(highlighted ? 0.50 : 0.12),
                                              lineWidth: highlighted ? 1.2 : 0.8) }
                .compositingGroup()
                .shadow(color: .black.opacity(0.10), radius: 5, x: 0, y: 2)
        }
    }

    /// Subtle translucent surface for inline code / JSON blocks (no shadow — kept quiet so it
    /// doesn't compete with the glass cards it often sits inside).
    func codeSurface(radius: CGFloat = 8) -> some View {
        background(.quaternary, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
