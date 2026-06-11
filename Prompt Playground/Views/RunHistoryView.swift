//
//  RunHistoryView.swift
//  Prompt Playground
//
//  The "Run History" page (LangSmith-style observability). Master list of executions (each TraceModel
//  is one grouped run of consecutive steps) + a detail pane that logs every step: each LLM call as a
//  record (final prompt in blocks · token estimates · output · sampling · error), each native-API /
//  hook step as op · input · output. Reuses StageCardView (RunTrace.swift) to render every block.
//

import SwiftUI
import SwiftData

struct RunHistoryView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TraceModel.createdAt, order: .reverse) private var traces: [TraceModel]
    @State private var selectedID: UUID? = nil

    private var selected: TraceModel? { traces.first { $0.id == selectedID } }

    var body: some View {
        HSplitView {
            master
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            detail
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selectedID == nil { selectedID = traces.first?.id } }
    }

    // MARK: Master list

    private var master: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Run History").font(.dsLabel)
                Spacer()
                if !traces.isEmpty {
                    Text("\(traces.count)").font(.dsMicro).foregroundStyle(.secondary).monospacedDigit()
                    Button(role: .destructive) { clearAll() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Clear all runs")
                }
            }
            .padding(.horizontal, DS.Space.md).padding(.vertical, DS.Space.sm)
            Divider()

            if traces.isEmpty {
                emptyList
            } else {
                List(traces, selection: $selectedID) { trace in
                    TraceRow(trace: trace).tag(trace.id)
                        .contextMenu {
                            Button(role: .destructive) { delete(trace) } label: { Label("Delete", systemImage: "trash") }
                        }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var emptyList: some View {
        VStack(spacing: DS.Space.sm) {
            Image(systemName: "clock.arrow.circlepath").font(.dsDisplay).foregroundStyle(.tertiary)
            Text("No runs yet").font(.dsBody).foregroundStyle(.secondary)
            Text("Run a graph to log it here.").font(.dsCaption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(DS.Space.lg)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let trace = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    TraceHeader(trace: trace)
                    ForEach(Array(trace.steps.enumerated()), id: \.element.id) { idx, step in
                        StepView(step: step, index: idx)
                    }
                }
                .padding(DS.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: DS.Space.md) {
                Image(systemName: "list.bullet.rectangle.portrait").font(.dsDisplay).foregroundStyle(.tertiary)
                Text("Select a run to inspect it").font(.dsBody).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Mutations

    private func delete(_ trace: TraceModel) {
        if selectedID == trace.id { selectedID = nil }
        context.delete(trace)
        try? context.save()
    }

    private func clearAll() {
        for t in traces { context.delete(t) }
        selectedID = nil
        try? context.save()
    }
}

// MARK: - Master row

private struct TraceRow: View {
    let trace: TraceModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.sm) {
                StatusDot(ok: trace.status == "ok", subtle: true)
                Text(trace.sourceName).font(.dsLabel).lineLimit(1)
                Spacer()
                Text(trace.createdAt, format: .dateTime.hour().minute().second())
                    .font(.dsMicro).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: DS.Space.sm) {
                Label("\(trace.llmRunCount)", systemImage: "brain")
                Text("·")
                Text("\(trace.totalMs) ms").monospacedDigit()
                Spacer()
                Text(trace.createdAt, format: .dateTime.month().day())
            }
            .font(.dsMicro).foregroundStyle(.tertiary)
        }
        .padding(.vertical, DS.Space.xxs)
    }
}

// MARK: - Detail header

private struct TraceHeader: View {
    let trace: TraceModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                StatusDot(ok: trace.status == "ok")
                Text(trace.sourceName).font(.dsTitle)
                Spacer()
                Text(trace.id.uuidString.prefix(8)).font(.dsCode).foregroundStyle(.tertiary).textSelection(.enabled)
            }
            HStack(spacing: DS.Space.md) {
                stat("Time", trace.createdAt.formatted(date: .abbreviated, time: .standard))
                stat("Duration", "\(trace.totalMs) ms")
                stat("LLM runs", "\(trace.llmRunCount)")
                stat("Steps", "\(trace.steps.count)")
            }
        }
        .padding(DS.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(label.uppercased()).font(.dsMicro).foregroundStyle(.tertiary)
            Text(value).font(.dsCaption.monospacedDigit())
        }
    }
}

// MARK: - One step (LLM record / native-API / hook)

private struct StepView: View {
    let step: ExecStep
    let index: Int

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.sm) {
                Text("\(index + 1)").font(.dsMicro.monospacedDigit())
                    .foregroundStyle(.tertiary).frame(minWidth: 16)
                TypeChip(type: step.type)
                Text(step.title).font(.dsLabel)
                Spacer()
                Text(step.id.uuidString.prefix(8)).font(.dsMicro).foregroundStyle(.tertiary)
            }

            Group {
                if step.type == "llm" { llmBlocks } else { processBlocks }
            }
            .padding(.leading, DS.Space.md)
        }
        .padding(.vertical, DS.Space.xs)
    }

    // The final prompt, in blocks → model output (or the failure + its reason).
    @ViewBuilder private var llmBlocks: some View {
        if let instr = step.instructions, !instr.isEmpty {
            StageCardView(title: "Instructions", status: .ok, text: instr)
        }
        if let turns = step.history, !turns.isEmpty {
            StageCardView(title: "History", status: .ok,
                          text: turns.map { "\($0.role.uppercased()): \($0.text)" }.joined(separator: "\n\n"))
        }
        if let cur = step.currentTurn, !cur.isEmpty {
            StageCardView(title: "Current turn", status: .ok, text: cur)
        }
        if step.ok {
            StageCardView(title: "Output", status: .ok, text: step.output ?? "",
                          ms: step.ms, note: tokenNote, raised: true)
        } else {
            StageCardView(title: "Error", status: .error, text: "", ms: step.ms,
                          note: step.errorReason ?? "Generation failed")
        }
    }

    @ViewBuilder private var processBlocks: some View {
        if let input = step.input, !input.isEmpty {
            StageCardView(title: "Input", status: .ok, text: input)
        }
        if step.ok {
            StageCardView(title: "Output", status: .ok, text: step.stepOutput ?? "",
                          ms: step.ms, note: step.op, raised: true)
        } else {
            StageCardView(title: "Error", status: .error, text: "", ms: step.ms,
                          note: step.errorReason ?? "Step failed")
        }
    }

    /// Token + sampling + schema summary, shown under the model output.
    private var tokenNote: String {
        var parts: [String] = []
        if let p = step.promptTokens, let o = step.outputTokens, let c = step.contextTokens {
            parts.append("~\(p) prompt · ~\(o) output · ~\(c) context tok")
        }
        if let cfg = step.configLabel, !cfg.isEmpty { parts.append(cfg) }
        if let schema = step.schemaName, !schema.isEmpty { parts.append("schema \(schema)") }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - Bits

private struct StatusDot: View {
    let ok: Bool
    var subtle: Bool = false   // list rows: a quiet dot, not a column of filled glyphs (60-30-10)
    var body: some View {
        if subtle {
            Circle().fill(ok ? Color.dsSuccess.opacity(0.8) : Color.dsDanger)
                .frame(width: 7, height: 7)
        } else {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.dsCaption).foregroundStyle(ok ? Color.dsSuccess : Color.dsDanger)
        }
    }
}

private struct TypeChip: View {
    let type: String
    private var label: String { type == "llm" ? "LLM" : type == "api" ? "API" : "HOOK" }
    private var color: Color { type == "llm" ? .dsAccent : .secondary }
    var body: some View {
        Text(label).dsBadge(color)
    }
}
