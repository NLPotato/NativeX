//
//  GenConfigControls.swift
//  Prompt Playground
//
//  Reusable generation-config editor bound to a `GenConfig` — the conditional-toggle idiom (a
//  Toggle gates the control beneath it) extracted from the Pipeline tab so the Gloss, Role-play,
//  and Pipeline surfaces all share one implementation.
//

import SwiftUI

struct GenConfigControls: View {
    @Binding var config: GenConfig

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Toggle(isOn: greedy) {
                Text("Greedy (deterministic)").font(.dsLabel)
            }
            Toggle(isOn: temperatureOn) {
                HStack {
                    Text("Temperature").font(.dsLabel)
                    if let t = config.temperature { Text(String(format: "%.2f", t)).font(.dsMicro).foregroundStyle(.secondary) }
                }
            }
            if config.temperature != nil {
                Slider(value: temperature, in: 0...2, step: 0.05)
            }
            Toggle(isOn: maxTokensOn) {
                HStack {
                    Text("Max response tokens").font(.dsLabel)
                    if let m = config.maximumResponseTokens { Text("\(m)").font(.dsMicro).foregroundStyle(.secondary) }
                }
            }
            if config.maximumResponseTokens != nil {
                Stepper(value: maxTokens, in: 64...4096, step: 64) {
                    Text("\(config.maximumResponseTokens ?? 512)").font(.dsMicro)
                }
            }
        }
        .font(.dsBody)
    }

    // GenConfig <-> toggle/value bindings.
    private var greedy: Binding<Bool> {
        Binding(get: { config.sampling == .greedy }, set: { config.sampling = $0 ? .greedy : .default })
    }
    private var temperatureOn: Binding<Bool> {
        Binding(get: { config.temperature != nil },
                set: { config.temperature = $0 ? (config.temperature ?? 0.7) : nil })
    }
    private var temperature: Binding<Double> {
        Binding(get: { config.temperature ?? 0.7 }, set: { config.temperature = $0 })
    }
    private var maxTokensOn: Binding<Bool> {
        Binding(get: { config.maximumResponseTokens != nil },
                set: { config.maximumResponseTokens = $0 ? (config.maximumResponseTokens ?? 512) : nil })
    }
    private var maxTokens: Binding<Int> {
        Binding(get: { config.maximumResponseTokens ?? 512 }, set: { config.maximumResponseTokens = $0 })
    }
}
