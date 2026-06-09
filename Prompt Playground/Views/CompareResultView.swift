//
//  CompareResultView.swift
//  Prompt Playground
//
//  Side-by-side result of a Compare run (GraphCompareRunner): one column per lane (a prompt group),
//  each showing its model output + core metrics (latency, estimated prompt/output tokens). The same run
//  is also saved as a Lab sweep, where VariantStats ranks the lanes — this view is the raw eyeball pass.
//

import SwiftUI

struct CompareResultView: View {
    let outcome: CompareOutcome
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.sm) {
                Text("Comparison").font(.dsTitle)
                Text("\(outcome.lanes.count) lanes").font(.dsCaption).foregroundStyle(.secondary)
                Spacer()
                Text("Saved to Lab as a sweep").font(.dsMicro).foregroundStyle(.tertiary)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(DS.Space.lg)
            Divider()

            if outcome.lanes.isEmpty {
                Text("No lanes ran — each lane needs a Prompt group feeding a Foundation Model.")
                    .font(.dsBody).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(DS.Space.xl)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: DS.Space.md) {
                        ForEach(outcome.lanes) { lane in laneColumn(lane) }
                    }
                    .padding(DS.Space.lg)
                }
            }
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    private func laneColumn(_ lane: CompareLaneResult) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: lane.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(lane.ok ? Color.dsSuccess : Color.dsDanger).font(.dsCaption)
                Text(lane.title).font(.dsLabel).lineLimit(1)
            }
            ScrollView {
                Text(lane.ok ? (lane.output.isEmpty ? "—" : lane.output) : (lane.error ?? "Failed"))
                    .font(.dsCode).textSelection(.enabled)
                    .foregroundStyle(lane.ok ? .primary : Color.dsDanger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Space.sm).codeSurface()
            }
            .frame(height: 280)
            HStack(spacing: DS.Space.md) {
                metric("\(lane.ms) ms")
                metric("~\(lane.promptTokens) prompt")
                metric("~\(lane.outputTokens) out")
            }
        }
        .frame(width: 300)
        .dsCard()
    }

    private func metric(_ s: String) -> some View {
        Text(s).font(.dsMicro.monospacedDigit()).foregroundStyle(.secondary)
    }
}
