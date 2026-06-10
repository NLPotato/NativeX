//
//  CanvasResultCard.swift
//  Prompt Playground
//
//  The single-run result, rendered as a white, full-opacity card floating beside the terminal FM node.
//  It is a VIEW-ONLY overlay — never a graph node (no ports, not in GraphDef, ignored by topo/exec). It
//  lives in the canvas's scaled layer so it pans/zooms with the board; drag adds a free offset (divided
//  by scale to track the cursor 1:1), and the X dismisses it until the next run. (Phase 4.)
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
                Image(systemName: "sparkles").font(.dsMicro).foregroundStyle(.black.opacity(0.6))
                Text("Result").font(.dsCaption.weight(.bold)).foregroundStyle(.black.opacity(0.8))
                Spacer(minLength: DS.Space.md)
                Button { copy() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).foregroundStyle(.black.opacity(0.55)).help("Copy")
                Button { engine.resultCardDismissed = true } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.black.opacity(0.55)).help("Dismiss")
            }
            .font(.dsMicro)
            Divider().overlay(Color.black.opacity(0.1))
            ScrollView {
                Text(text).font(.dsBody).foregroundStyle(.black)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
        .padding(DS.Space.md)
        .frame(width: 320, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).strokeBorder(.black.opacity(0.12)))
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
