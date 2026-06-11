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
    @State private var showSamplingInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.xs) {
                Text("Sampling").font(.dsLabel)
                Button { showSamplingInfo.toggle() } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("What do these sampling modes mean?")
                .popover(isPresented: $showSamplingInfo, arrowEdge: .bottom) { samplingInfo }
                Spacer(minLength: 0)
            }
            Picker("Sampling", selection: $config.sampling) {
                Text("Default").tag(GenConfig.Sampling.default)
                Text("Greedy").tag(GenConfig.Sampling.greedy)
                Text("Top-k").tag(GenConfig.Sampling.topK)
                Text("Nucleus").tag(GenConfig.Sampling.nucleus)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if config.sampling == .topK {
                Stepper(value: topK, in: 1...100) {
                    HStack { Text("Top-k").font(.dsLabel); Text("\(config.topK ?? 50)").font(.dsMicro).foregroundStyle(.secondary) }
                }
            }
            if config.sampling == .nucleus {
                HStack {
                    Text("Threshold p").font(.dsLabel)
                    Text(String(format: "%.2f", config.probabilityThreshold ?? 0.9)).font(.dsMicro).foregroundStyle(.secondary)
                }
                Slider(value: probabilityThreshold, in: 0.05...1.0, step: 0.05)
            }
            if config.sampling == .topK || config.sampling == .nucleus {
                Toggle(isOn: seedOn) {
                    HStack {
                        Text("Seed (reproducible)").font(.dsLabel)
                        if let s = config.seed { Text("\(s)").font(.dsMicro.monospacedDigit()).foregroundStyle(.secondary) }
                    }
                }
                if config.seed != nil {
                    HStack(spacing: DS.Space.sm) {
                        TextField("seed", value: seedValue, format: .number).dsTextField().frame(width: DS.Size.fieldMiniWidth)
                        Button { config.seed = UInt64.random(in: 0...UInt64(UInt32.max)) } label: {
                            Image(systemName: "shuffle")
                        }
                        .buttonStyle(.borderless)
                        .help("Randomize the seed")
                    }
                }
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

    // Plain-language explainer for the four sampling modes — shown from the ⓘ next to "Sampling".
    private var samplingInfo: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Text("How the model picks each next word").font(.dsLabel)
            infoRow("Default", "The model's built-in strategy — a balanced choice for everyday runs when you're not tuning for determinism or variety.")
            infoRow("Greedy", "Always takes the single most likely word. Fully deterministic: the same input gives the same output every time. Best for reproducible evals and structured extraction.")
            infoRow("Top-k", "Chooses from the k most likely words. Controlled variety — a lower k stays safe and on-topic, a higher k explores more.")
            infoRow("Nucleus", "Chooses from the smallest set of words whose probabilities add up to p (also called top-p). It widens or narrows the options to match the model's confidence — usually more natural than Top-k.")
            Divider().padding(.vertical, DS.Space.xxs)
            Text("Temperature sharpens (low) or flattens (high) those odds. Set a Seed to make Top-k and Nucleus reproducible.")
                .font(.dsCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.md)
        .frame(width: 320)
    }

    private func infoRow(_ name: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(name).font(.dsCaption).fontWeight(.semibold)
            Text(desc).font(.dsCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // GenConfig <-> toggle/value bindings.
    private var topK: Binding<Int> {
        Binding(get: { config.topK ?? 50 }, set: { config.topK = $0 })
    }
    private var probabilityThreshold: Binding<Double> {
        Binding(get: { config.probabilityThreshold ?? 0.9 }, set: { config.probabilityThreshold = $0 })
    }
    private var seedOn: Binding<Bool> {
        Binding(get: { config.seed != nil }, set: { config.seed = $0 ? (config.seed ?? 42) : nil })
    }
    private var seedValue: Binding<UInt64> {
        Binding(get: { config.seed ?? 42 }, set: { config.seed = $0 })
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
