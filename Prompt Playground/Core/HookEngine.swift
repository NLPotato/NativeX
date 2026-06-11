//
//  HookEngine.swift
//  Prompt Playground
//
//  Executes a HookPipelineDef around a model call. Pre-hooks run in order into one shared mutable
//  context ([String:String]); each reads context[inputVar], applies a native op, and writes
//  context[outputVar] — so the prompt's {{outputVar}} resolves to it and later hooks can chain off
//  earlier outputs. Hooks are substitution-free internally (inputVar/outputVar are context KEYS,
//  not {{tokens}}); only a hook's params are var-substituted against the live context, which avoids
//  any chicken-and-egg with the one prompt-substitution pass that happens after pre-hooks.
//
//  Shared by the Graph executor (GraphExecutor) and the headless Lab runners (TextRunner /
//  DynamicRunner) so a saved pipeline replays identically. All ops use NaturalLanguage / Foundation
//  — sandbox-safe and identical on macOS and iOS.
//

import Foundation
import NaturalLanguage
import os

@MainActor
enum HookEngine {
    enum HookError: LocalizedError {
        case invalidRegex(String)
        case emptyCommand
        var errorDescription: String? {
            switch self {
            case .invalidRegex(let p): return "Invalid regular expression: \(p)"
            case .emptyCommand:        return "Script hook has no command."
            }
        }
    }

    /// Run one hook against the context, returning its step result. Writes `outputVar` on success.
    /// Async because a `.script` hook shells out off the main actor; native ops resolve synchronously.
    static func runOne(_ hook: HookDef, context: inout [String: String], defaultInput: String? = nil) async -> HookStep {
        let start = Date()
        let input = context[hook.inputVar] ?? defaultInput ?? ""
        do {
            let params = resolveParams(hook.params, context)
            let out = try await apply(hook.op, input: input, params: params, context: context)
            if !hook.outputVar.isEmpty { context[hook.outputVar] = out }
            return HookStep(hookID: hook.id, displayName: hook.op.displayName,
                            outputVar: hook.outputVar, output: out, error: nil, ms: millis(since: start))
        } catch {
            return HookStep(hookID: hook.id, displayName: hook.op.displayName,
                            outputVar: hook.outputVar, output: nil,
                            error: error.localizedDescription, ms: millis(since: start))
        }
    }

    /// Pre-hooks: fold enabled hooks through the shared context in order.
    static func runPre(_ hooks: [HookDef], context: inout [String: String]) async -> [HookStep] {
        var steps: [HookStep] = []
        for hook in hooks where hook.enabled { steps.append(await runOne(hook, context: &context)) }
        return steps
    }

    /// Post-hooks: thread the model output through enabled hooks. Each defaults its input to the
    /// running output (also exposed as `{{output}}`); the last result is the final output.
    static func runPost(_ hooks: [HookDef], output: String, context: [String: String]) async -> (output: String, steps: [HookStep]) {
        var ctx = context
        ctx["output"] = output
        var current = output
        var steps: [HookStep] = []
        for hook in hooks where hook.enabled {
            let step = await runOne(hook, context: &ctx, defaultInput: current)
            if let o = step.output { current = o; ctx["output"] = o }
            steps.append(step)
        }
        return (current, steps)
    }

    // MARK: - Op dispatch

    private static func resolveParams(_ params: [String: String], _ context: [String: String]) -> [String: String] {
        params.mapValues { Vars.substitute($0, context) }
    }

    private static func apply(_ op: HookOp, input: String, params: [String: String], context: [String: String]) async throws -> String {
        switch op {
        case .tokenizeWords:
            let words = tokenize(input, unit: .word, language: params[HookParam.language.rawValue])
            return formatList(words, style: params[HookParam.format.rawValue] ?? "numbered")
        case .sentenceSplit:
            let sentences = tokenize(input, unit: .sentence, language: nil)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return formatList(sentences, style: params[HookParam.format.rawValue] ?? "numbered")
        case .enrichGloss:
            return enrich(input, language: params[HookParam.language.rawValue] ?? "")
        case .detectLanguage:
            return LanguageTools.detect(input)?.rawValue ?? "und"
        case .countTokens:
            // Heuristic estimate. TODO(Xcode 26.4 SDK): route through SystemLanguageModel
            // .tokenCount(for:) behind #available(macOS 26.4, *) — neither that symbol nor
            // contextSize exists in the 26.2 SDK (verified; see the TokenEstimator note).
            let count = TokenEstimator.estimate(input)
            if (params[HookParam.tokenFormat.rawValue] ?? "count") == "report" {
                let pct = Double(count) / Double(TokenEstimator.contextWindow) * 100
                return "≈\(count) tokens · \(String(format: "%.1f", pct))% of the \(TokenEstimator.contextWindow)-token window"
            }
            return String(count)
        case .regexExtract:
            return try regexExtract(input, pattern: params[HookParam.pattern.rawValue] ?? "",
                                    group: Int(params[HookParam.group.rawValue] ?? "0") ?? 0)
        case .regexReplace:
            return try regexReplace(input, pattern: params[HookParam.pattern.rawValue] ?? "",
                                    with: params[HookParam.replacement.rawValue] ?? "")
        case .jsonExtract:
            return jsonExtract(input, path: params[HookParam.path.rawValue] ?? "")
        case .textTransform:
            return textTransform(input, mode: params[HookParam.mode.rawValue] ?? "trim")
        case .script:
            let command = params[HookParam.command.rawValue] ?? ""
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HookError.emptyCommand }
            let seconds = Int(params[HookParam.timeout.rawValue] ?? "") ?? 30
            return try await runHookProcess(command: command, stdin: input, env: context,
                                            timeout: TimeInterval(max(1, seconds)))
        }
    }

    // MARK: - Script op (external process; macOS-only, requires the App Sandbox to be off)
    //
    // The hook's I/O contract — the boundary that keeps the prompt → (structured) output pipeline
    // clean: the resolved input is piped to the command's STDIN; trimmed STDOUT becomes the output
    // var; every context variable is exported as an env var `PP_<NAME>`; a non-zero exit (or the
    // timeout) surfaces STDERR as the stage error. One string in, one string out — to feed a script
    // result into a typed/structured run, chain a JSON-extract hook or write JSON the schema lane parses.

    /// Run a shell command as a hook, off the main actor so the UI stays live. `/bin/zsh -c command`.
    nonisolated static func runHookProcess(command: String, stdin: String,
                                           env: [String: String], timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try runProcessSync(command: command, stdin: stdin, env: env, timeout: timeout)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Blocking process run — only ever called from a background queue (see `runHookProcess`).
    nonisolated private static func runProcessSync(command: String, stdin: String,
                                                   env: [String: String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in env where key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil {
            environment["PP_" + key.uppercased()] = value
        }
        process.environment = environment

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        do { try process.run() } catch {
            throw NSError(domain: "HookScript", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't launch command: \(error.localizedDescription)"])
        }

        // Feed stdin, then close so the child sees EOF.
        if let data = stdin.data(using: .utf8), !data.isEmpty { inPipe.fileHandleForWriting.write(data) }
        try? inPipe.fileHandleForWriting.close()

        // Watchdog: terminate (and flag) a hook that overruns its timeout. Killing the child closes its
        // stdout, which unblocks the reads below — so even a pathological writer can't hang the pipeline.
        let timedOut = OSAllocatedUnfairLock(initialState: false)
        let watchdog = DispatchWorkItem { timedOut.withLock { $0 = true }; process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        if timedOut.withLock({ $0 }) {
            throw NSError(domain: "HookScript", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Script timed out after \(Int(timeout))s"])
        }
        if process.terminationStatus != 0 {
            let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(domain: "HookScript", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: stderr.isEmpty
                              ? "Script exited with code \(process.terminationStatus)"
                              : "Script failed (\(process.terminationStatus)): \(stderr)"])
        }
        return (String(data: outData, encoding: .utf8) ?? "").trimmingCharacters(in: .newlines)
    }

    // MARK: - NaturalLanguage ops (reuse LanguageTools where it already owns the logic)

    private static func tokenize(_ text: String, unit: NLTokenUnit, language: String?) -> [String] {
        let tok = NLTokenizer(unit: unit)
        if let language, let lang = LanguageTools.language(named: language) { tok.setLanguage(lang) }
        tok.string = text
        return tok.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]) }
    }

    /// Deterministic per-word enrichment (surface · POS · lemma · [reading]) via the shared pipeline.
    private static func enrich(_ text: String, language: String) -> String {
        LanguageTools.enrich(text, language: language).enumerated().map { i, t in
            var parts = ["\(i + 1). \(t.surface)"]
            if let p = t.pos { parts.append(p) }
            if let l = t.lemma, l.lowercased() != t.surface.lowercased() { parts.append("lemma: \(l)") }
            if let r = t.romanization { parts.append("[\(r)]") }
            return parts.joined(separator: "  ·  ")
        }.joined(separator: "\n")
    }

    // MARK: - Text / JSON ops

    private static func formatList(_ items: [String], style: String) -> String {
        switch style {
        case "comma": return items.joined(separator: ", ")
        case "lines": return items.joined(separator: "\n")
        default:      return items.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        }
    }

    private static func regexExtract(_ input: String, pattern: String, group: Int) throws -> String {
        guard !pattern.isEmpty else { return "" }
        guard let re = try? NSRegularExpression(pattern: pattern) else { throw HookError.invalidRegex(pattern) }
        let range = NSRange(input.startIndex..., in: input)
        guard let m = re.firstMatch(in: input, range: range) else { return "" }
        let gi = (group >= 0 && group < m.numberOfRanges) ? group : 0
        guard let r = Range(m.range(at: gi), in: input) else { return "" }
        return String(input[r])
    }

    private static func regexReplace(_ input: String, pattern: String, with replacement: String) throws -> String {
        guard !pattern.isEmpty else { return input }
        guard let re = try? NSRegularExpression(pattern: pattern) else { throw HookError.invalidRegex(pattern) }
        let range = NSRange(input.startIndex..., in: input)
        return re.stringByReplacingMatches(in: input, range: range, withTemplate: replacement)
    }

    /// Read a dotted key path (objects by name, arrays by index) out of a JSON string.
    private static func jsonExtract(_ input: String, path: String) -> String {
        guard let data = input.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return "" }
        var current: Any? = root
        for key in path.split(separator: ".") {
            if let idx = Int(key), let arr = current as? [Any] {
                current = idx >= 0 && idx < arr.count ? arr[idx] : nil
            } else if let dict = current as? [String: Any] {
                current = dict[String(key)]
            } else {
                current = nil
            }
        }
        switch current {
        case let s as String:   return s
        case let n as NSNumber: return n.stringValue
        case let v?:            return String(describing: v)
        default:                return ""
        }
    }

    private static func textTransform(_ input: String, mode: String) -> String {
        switch mode {
        case "upper":     return input.uppercased()
        case "lower":     return input.lowercased()
        case "trimlines": return input.split(separator: "\n", omittingEmptySubsequences: false)
                                       .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        default:          return input.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
