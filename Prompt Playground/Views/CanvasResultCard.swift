//
//  CanvasResultCard.swift
//  Prompt Playground
//
//  The single-run result, floating beside the terminal FM node — same dark surface language as the
//  nodes, with JSON output rendered as a structured key-value outline (JSONOutlineView) instead of raw
//  indented JSON. It is a VIEW-ONLY overlay — never a graph node (no ports, not in GraphDef, ignored by
//  topo/exec). It lives in the canvas's scaled layer so it pans/zooms with the board; drag adds a free
//  offset (divided by scale to track the cursor 1:1), and the X dismisses it until the next run.
//

import SwiftUI
import AppKit

struct CanvasResultCard: View {
    @Bindable var engine: GraphEngine
    let text: String
    @State private var dragStart: CGSize? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "sparkles").font(.dsMicro).foregroundStyle(.secondary)
                Text("Result").font(.dsCaption.weight(.bold)).foregroundStyle(.primary)
                Spacer(minLength: DS.Space.md)
                Button { copy() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Copy")
                Button { engine.resultCardDismissed = true } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
            }
            .font(.dsMicro)
            Divider()
            ScrollView {
                Group {
                    if let node = JSONOutline.parse(text), node.isContainer {
                        JSONOutlineView(node: node)   // structured outline, schema key order preserved
                    } else {
                        Text(text).font(.dsBody).foregroundStyle(.primary)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
        }
        .padding(DS.Space.md)
        .frame(width: 340, alignment: .leading)
        .background(.dsSurface, in: RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous).strokeBorder(.dsHairline))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)   // floats above the board as a distinct artifact
        .gesture(
            DragGesture(coordinateSpace: .named(graphBoardSpace))
                .onChanged { v in
                    if dragStart == nil { dragStart = engine.resultCardOffset }
                    let s = dragStart ?? .zero
                    engine.resultCardOffset = CGSize(width: s.width + v.translation.width / engine.scale,
                                                     height: s.height + v.translation.height / engine.scale)
                }
                .onEnded { _ in dragStart = nil }
        )
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
