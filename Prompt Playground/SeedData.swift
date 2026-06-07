//
//  SeedData.swift
//  Prompt Playground
//
//  First-launch seed: a canonical prompt template per task plus starter datasets (varied
//  languages for gloss; scripted scenes incl. the Starbucks barista for role-play). Runs once
//  when the store is empty so there's something to run an experiment against immediately.
//

import Foundation
import SwiftData

@MainActor
enum SeedData {
    /// Canonical gloss prompt using the {{learning}}/{{native}} convention (replaces the legacy
    /// {{source}}/{{target}} of the single-shot tab — those still resolve via runner aliases).
    static let glossTemplate = """
    You are a language-learning assistant helping someone learn {{learning}}. Their native language is {{native}}. \
    Given a {{learning}} sentence, break it into its meaningful words. For each word give the dictionary (lemma) \
    form, its part of speech, and a {{native}} translation. Then translate the whole sentence into {{native}} and \
    add one or two short grammar notes in {{native}}. Only analyze words that actually appear; do not invent words.
    """

    static func seedIfNeeded(_ context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<PromptTemplateModel>())) ?? 0
        guard count == 0 else { return }
        context.insert(PromptTemplateModel(task: .gloss, name: "Gloss baseline", version: 1,
            instructions: glossTemplate, notes: "Canonical {{learning}}/{{native}} gloss prompt."))
        context.insert(PromptTemplateModel(task: .roleplay, name: "Role-play baseline", version: 1,
            instructions: RoleplayModel.defaultInstructions, notes: "Mirrors wiekant's role-play scaffold."))
        context.insert(glossDataset())
        context.insert(roleplayDataset())
        try? context.save()
    }

    // MARK: Gloss

    private static func glossExample(_ label: String, _ sentence: String,
                                     learning: String, native: String = "English") -> ExampleModel {
        let input = GlossInput(sentence: sentence, learning: learning, native: native)
        return ExampleModel(task: .gloss, label: label, inputJSON: JSONCoder.encode(input))
    }

    private static func glossDataset() -> DatasetModel {
        DatasetModel(task: .gloss, name: "Starter gloss", examples: [
            glossExample("DE · simple", "Der Hund schläft.", learning: "German"),
            glossExample("DE · café order", "Ich möchte einen Kaffee bestellen.", learning: "German"),
            glossExample("KO · café order", "저는 커피를 주문하고 싶어요.", learning: "Korean"),
            glossExample("ES · polite request", "Me gustaría pedir un café, por favor.", learning: "Spanish"),
            glossExample("FR · directions", "Où est la gare la plus proche ?", learning: "French"),
            glossExample("JA · please give", "コーヒーを一杯ください。", learning: "Japanese"),
        ])
    }

    // MARK: Role-play

    private static func roleplayExample(_ label: String, learning: String, native: String = "English",
                                        situation: String, you: String, ai: String,
                                        script: [String], maxTurns: Int = 4) -> ExampleModel {
        let input = RoleplayInput(learning: learning, native: native, situation: situation,
                                  youRole: you, aiRole: ai, scriptedUserTurns: script, maxTurns: maxTurns)
        return ExampleModel(task: .roleplay, label: label, inputJSON: JSONCoder.encode(input))
    }

    private static func roleplayDataset() -> DatasetModel {
        DatasetModel(task: .roleplay, name: "Starter role-play", examples: [
            roleplayExample("Starbucks barista (DE)", learning: "German",
                situation: "Ordering at a Starbucks counter during the morning rush",
                you: "a customer who wants to buy coffee", ai: "a friendly barista",
                script: ["Ich hätte gern einen großen Cappuccino.", "Haben Sie auch Hafermilch?", "Das ist alles, danke."]),
            roleplayExample("Restaurant order (KO)", learning: "Korean",
                situation: "Ordering dinner at a casual Korean restaurant",
                you: "a hungry customer", ai: "a server taking the order",
                script: ["불고기 일 인분 주세요.", "물도 한 병 주시겠어요?"]),
            roleplayExample("Asking directions (FR)", learning: "French",
                situation: "Lost near the train station and asking a passerby for help",
                you: "a tourist", ai: "a helpful local",
                script: ["Excusez-moi, où est la gare ?", "Merci beaucoup !"], maxTurns: 3),
        ])
    }
}
