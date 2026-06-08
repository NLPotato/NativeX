//
//  CJKDrilldown.swift
//  Prompt Playground
//
//  Stage-2 CJK morphology drill-down (Variant A — per-word fan-out), interactive surface.
//  After a stage-1 CJK gloss run, the Single-shot tab shows the segmented words as tappable
//  chips; tapping one (or "Analyze all") runs ONE focused full-morphology call per word — the
//  decompose-and-drill-down answer to the 4096-token one-shot's residual lemma errors. The
//  `CJKMorphology.analyze` atom is shared with the headless Lab runner (Phase 4).
//  NO #Playground block — drive everything from the SwiftUI app.
//

import SwiftUI
import Observation
import FoundationModels

// MARK: - The per-word analysis atom (shared with the headless runner)

@MainActor
enum CJKMorphology {
    /// One focused full-morphology call for a SINGLE word, in the context of its sentence. Builds the
    /// `.morphologyWord` dynamic schema and returns pretty JSON + elapsed ms. Errors propagate (callers
    /// map them via `classify`). The few-shot targets the proven Korean failures (만나서, 봤어요).
    static func analyze(word: String, reading: String, context: String,
                        learning: String, native: String, proficiency: String,
                        config: GenConfig) async throws -> (json: String, ms: Int) {
        let instructions = """
        You are a \(learning) morphology tutor; the learner's native language is \(native). Learner level: \(proficiency).
        Decompose the given word into morphemes and give its dictionary form. \(learning) verbs and adjectives are heavily
        conjugated and nouns carry particles — split the SURFACE into a stem plus every ending/particle, and ALWAYS give the
        dictionary form in \(learning)'s OWN script (the plain 다 form for verbs/adjectives), NEVER the romanized reading.
        Copy the reading exactly as given — do not re-romanize.

        Worked examples (different words — do not copy them into your answer):
          • 만나서 → dictionaryForm 만나다 (verb). morphemes: 만나- [stem, "to meet"] + -아서 [ending, "connective 'and so'"].
          • 봤어요 → dictionaryForm 보다 (verb). morphemes: 보- [stem, "to see"] + -았- [ending, "past"] + -어요 [ending, "polite informal 해요체"]. note: 보았어요 contracts to 봤어요. register: "polite informal (해요체)".
        Rule shown by these: strip EVERY ending back to the bare 다 form (만나서→만나다 NOT 만나서다; 봤어요→보다 NOT 봤다).
        """
        let readingTag = reading.isEmpty ? "" : " [\(reading)]"
        let prompt = "Full sentence (for context): \(context)\n\nAnalyze ONLY this word: \(word)\(readingTag)"
        let session = LanguageModelSession(instructions: instructions)
        let start = Date()
        let content = try await DynamicRun.respond(session: session, prompt: prompt,
                                                   def: .morphologyWord, options: config.toOptions())
        return (prettyJSONString(content.jsonString), millis(since: start))
    }

    /// The drill-down chips: the DETERMINISTIC segmentation of the input sentence (NLTokenizer +
    /// CFStringTokenizer reading via `LanguageTools.enrich`), kept ONLY when non-Latin (CJK). Sourced
    /// from the input — NOT the model's gloss output, whose surfaces can be corrupted (e.g. 만나서→나아서),
    /// which would otherwise make the chip analyze a non-word.
    static func segment(_ sentence: String, learning: String) -> [CJKWord] {
        let tokens = LanguageTools.enrich(sentence, language: learning)
        let chips: [CJKWord] = tokens.compactMap { t in
            let s = t.surface.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty, s.unicodeScalars.contains(where: { $0.value >= 0x3000 }) else { return nil }
            return CJKWord(surface: s, reading: t.romanization ?? "")
        }
        return chips
    }
}

/// One segmented word offered as a drill-down chip.
struct CJKWord: Identifiable {
    let id = UUID()
    let surface: String
    let reading: String
}

// MARK: - Interactive engine (mirrors RoleplayModel: @Observable, append-on-await, serialized)

@MainActor
@Observable
final class CJKDrilldownModel {
    /// One per-word result card, appended on tap and filled in when its focused call returns.
    struct WordCard: Identifiable {
        let id = UUID()
        let surface: String
        let reading: String
        var json: String = ""
        var ms: Int = 0
        var errorText: String? = nil
        var isRunning: Bool = true
    }

    var cards: [WordCard] = []
    var isRunning = false   // one focused call at a time (the on-device model serves one session)

    /// Run a focused analysis for one word, appending a live card. No-op if a call is already in flight.
    func analyzeWord(_ surface: String, reading: String, context: String,
                     learning: String, native: String, proficiency: String, config: GenConfig) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        cards.append(WordCard(surface: surface, reading: reading))
        let i = cards.count - 1
        do {
            let (json, ms) = try await CJKMorphology.analyze(word: surface, reading: reading, context: context,
                                                             learning: learning, native: native,
                                                             proficiency: proficiency, config: config)
            cards[i].json = json
            cards[i].ms = ms
        } catch {
            cards[i].errorText = classify(error).text
        }
        cards[i].isRunning = false
    }

    /// Fan over every word sequentially (the batch "Analyze all").
    func analyzeAll(words: [CJKWord], context: String,
                    learning: String, native: String, proficiency: String, config: GenConfig) async {
        for w in words {
            await analyzeWord(w.surface, reading: w.reading, context: context,
                              learning: learning, native: native, proficiency: proficiency, config: config)
        }
    }

    func reset() { cards = [] }
}

// MARK: - Drill-down section (attached under the Single-shot output stages)

struct CJKDrilldownSection: View {
    let model: CJKDrilldownModel
    let words: [CJKWord]
    let context: String
    let learning: String
    let native: String
    let proficiency: String
    let config: GenConfig

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeader("Morphology drill-down")

            HStack(alignment: .firstTextBaseline) {
                Text("Tap a word for a focused full-morphology pass (one model call per word).")
                    .font(.dsCaption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    Task { await model.analyzeAll(words: words, context: context, learning: learning,
                                                  native: native, proficiency: proficiency, config: config) }
                } label: {
                    if model.isRunning { ProgressView().controlSize(.small) } else { Text("Analyze all") }
                }
                .font(.dsCaption)
                .disabled(model.isRunning || words.isEmpty)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: DS.Space.xs)],
                      alignment: .leading, spacing: DS.Space.xs) {
                ForEach(words) { w in
                    Button {
                        Task { await model.analyzeWord(w.surface, reading: w.reading, context: context,
                                                       learning: learning, native: native,
                                                       proficiency: proficiency, config: config) }
                    } label: {
                        Text(w.surface).font(.dsBody)
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isRunning)
                }
            }

            ForEach(model.cards) { cardView($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cardView(_ card: CJKDrilldownModel.WordCard) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.sm) {
                Text(card.surface).font(.dsBody).fontWeight(.medium)
                if !card.reading.isEmpty {
                    Text("[\(card.reading)]").font(.dsCaption).foregroundStyle(.secondary)
                }
                Spacer()
                if card.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(card.ms) ms").font(.dsMicro.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let err = card.errorText {
                Text(err).font(.dsCaption).foregroundStyle(.dsDanger).textSelection(.enabled)
            } else if !card.json.isEmpty {
                Text(card.json).font(.dsCode).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).dsFlat()
            }
        }
        .dsCard()
    }
}
