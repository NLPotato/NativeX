//
//  RoleplayPlayground.swift
//  Prompt Playground
//
//  The typed role-play schema + its system-prompt scaffold. Formerly home to the Role-play tab's
//  engine; that tab is now the "Language role-play" preset of the generic Chat tab (ChatPlayground),
//  so the live engine moved there. These types remain the canonical shipping shape — still used by
//  the Chat role-play preset, the headless RoleplayRunner (Runners.swift), the Lab, and Metrics.
//  NO #Playground block.
//

import Foundation
import FoundationModels

// MARK: - @Generable schema
// The typed shipping schema. (Runtime DynamicGenerationSchema CAN express nested objects /
// arrays-of-objects too — see docs/reference/foundation-models.md — but the typed lane keeps the
// tappable suggestions + typed metrics, so it stays the default.) File scope, app target.

@Generable(description: "One spoken line of dialogue, with a translation")
struct RoleplayLineGen: Codable {
    @Guide(description: "What is said, written in the language the user is learning")        var text: String
    @Guide(description: "A natural translation of the line into the user's native language") var translation: String
}

@Generable(description: "The character's reply plus suggested things the user could say next")
struct RoleplayTurnGen: Codable {
    // Grounded field first (declaration order biases generation).
    @Guide(description: "What you (the character the user is talking to) say now — in the learning language, staying in role and moving the scene forward") var reply: RoleplayLineGen
    // Soft-targeted at two via the description (not a hard `.count(2)`, which would fail a
    // whole turn on a stray 1 or 3) — matches what ships to wiekant.
    @Guide(description: "Exactly two natural things the user could say next, in the learning language, fitting their role")                                  var suggestions: [RoleplayLineGen]
}

// MARK: - Default scaffold

/// Mirrors wiekant's buildRoleplayInstructions. Placeholders map to the Chat role-play preset's
/// scene Inputs ({{learning}}/{{native}}/{{situation}}/{{you}}/{{ai}}). Also seeds the Lab's
/// "Role-play baseline" template (SeedData).
let defaultRoleplayInstructions = """
You are running a spoken role-play to help someone practice {{learning}}. Their native language is {{native}}.
Scene: {{situation}}.
You always play: {{ai}}. The user always plays: {{you}}.
Stay in character. Speak only in {{learning}}, naturally and briefly — one short turn at a time, suited to a learner.
Each turn, give what you say (in {{learning}}) with a {{native}} translation, plus two short, natural things the user could say next (in {{learning}}) each with a {{native}} translation.
"""
