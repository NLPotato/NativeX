//
//  Judge.swift
//  Prompt Playground
//
//  On-device LLM-as-judge: a SECOND model pass that scores a run's output against a rubric so
//  large batches get a cheap subjective signal. It's the same ~3B model, so it's noisy — treat
//  scores as directional and calibrate them against manual ratings (judge-vs-human agreement).
//

import Foundation
import FoundationModels

@Generable(description: "A 1–5 rubric rating of a language-learning output")
struct JudgeScore: Codable, Equatable {
    @Guide(description: "Language fluency/accuracy, integer 1 (poor) to 5 (excellent)")        var fluency: Int
    @Guide(description: "Naturalness — sounds like a native, integer 1 to 5")                  var naturalness: Int
    @Guide(description: "Pedagogical usefulness for a learner, integer 1 to 5")                var usefulness: Int
    @Guide(description: "Linguistic correctness (grammar, word choice), integer 1 to 5")       var correctness: Int
    @Guide(description: "One short sentence justifying the scores")                            var rationale: String

    var mean: Double {
        Double(clamp(fluency) + clamp(naturalness) + clamp(usefulness) + clamp(correctness)) / 4.0
    }
    private func clamp(_ v: Int) -> Int { min(5, max(1, v)) }
}

@MainActor
enum Judge {
    static func score(task: TaskKind, input: String, output: String) async -> JudgeScore? {
        let instructions: String
        switch task {
        case .gloss:
            instructions = """
            You are a strict evaluator of language-learning "gloss" output (word-by-word breakdown \
            plus a sentence translation). Judge the model's JSON against the source sentence. Rate each \
            dimension as an integer 1–5, being critical: penalize invented words, wrong lemmas/parts of \
            speech, and translations that are wrong or in the wrong language. Keep the rationale to one sentence.
            """
        case .roleplay:
            instructions = """
            You are a strict evaluator of a spoken-language role-play tutor. Judge the dialogue JSON for \
            the given scene. Rate each dimension as an integer 1–5, being critical: penalize unnatural or \
            incorrect language, replies that break character, and weak or non-distinct practice suggestions. \
            Keep the rationale to one sentence.
            """
        }
        let prompt = "Scene / input:\n\(input)\n\nModel output (JSON):\n\(output)"
        let session = LanguageModelSession(instructions: instructions)
        do {
            // Low temperature for steadier scoring; the judge is advisory, not ground truth.
            let response = try await session.respond(to: prompt, generating: JudgeScore.self,
                                                     includeSchemaInPrompt: true,
                                                     options: GenerationOptions(temperature: 0.2))
            return response.content
        } catch {
            return nil
        }
    }
}

// MARK: - Judge-vs-human agreement

enum Agreement {
    /// Mean absolute difference between the judge's mean score and the manual rating across runs
    /// that have both, and the share that agree within 1 point. nil when nothing is comparable.
    static func compute(judge: [Double], manual: [Int]) -> (meanAbsDiff: Double, within1: Double)? {
        let pairs = zip(judge, manual).map { ($0, Double($1)) }
        guard !pairs.isEmpty else { return nil }
        let diffs = pairs.map { abs($0.0 - $0.1) }
        let mad = diffs.reduce(0, +) / Double(diffs.count)
        let within = Double(diffs.filter { $0 <= 1.0 }.count) / Double(diffs.count)
        return (mad, within)
    }
}
