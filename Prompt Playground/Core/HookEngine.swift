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
import Vision
import os

@MainActor
enum HookEngine {
    enum HookError: LocalizedError {
        case invalidRegex(String)
        case emptyCommand
        case fileNotFound(String)
        var errorDescription: String? {
            switch self {
            case .invalidRegex(let p): return "Invalid regular expression: \(p)"
            case .emptyCommand:        return "Script hook has no command."
            case .fileNotFound(let p): return "No file at path: \(p)"
            }
        }
    }

    /// What an op's API call returns, typed by `HookOp.returnShape` — the single seam between the
    /// native call and the string variable lane. `render` is the ONLY serializer: lists go through
    /// the node's shared OutputProjection; objects emit canonical JSON; ops never pre-format.
    enum HookValue {
        case text(String)
        case list([String])
        case number(Int)
        case object(json: String)

        func render(projection: OutputProjection) -> String {
            switch self {
            case .text(let s):        return s
            case .number(let n):      return String(n)
            case .object(let json):   return json
            case .list(let items):    return projection.render(items)
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
                .render(projection: hook.projection)
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

    /// The API call itself — returns the typed value (per `HookOp.returnShape`); serialization is
    /// `HookValue.render`'s job. An op here reads ONLY its declared `paramKeys`.
    private static func apply(_ op: HookOp, input: String, params: [String: String], context: [String: String]) async throws -> HookValue {
        switch op {
        case .tokenizeWords:
            // Merged tokenizer (ADR-20260615): one NLTokenizer node, unit selected in the inspector.
            let unit: NLTokenUnit = params[HookParam.unit.rawValue] == "sentence" ? .sentence : .word
            var toks = tokenize(input, unit: unit, language: params[HookParam.language.rawValue])
            if unit == .sentence { toks = toks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
            return .list(toks)
        case .sentenceSplit:   // legacy op, kept for back-compat decode; merged into .tokenizeWords (unit: .sentence)
            return .list(tokenize(input, unit: .sentence, language: nil)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        case .enrichGloss:
            return .list(enrich(input, language: params[HookParam.language.rawValue] ?? ""))
        case .namedEntities:
            return .list(LanguageTools.namedEntities(input, language: params[HookParam.language.rawValue] ?? ""))
        case .sentiment:
            let s = LanguageTools.sentiment(input)
            return .object(json: #"{"score": \#(String(format: "%.2f", s.score)), "label": "\#(s.label)"}"#)
        case .textStats:
            let st = LanguageTools.textStats(input)
            return .object(json: #"{"characters": \#(st.characters), "words": \#(st.words), "sentences": \#(st.sentences), "lines": \#(st.lines)}"#)
        case .chunkText:
            let size = Int(params[HookParam.chunkSize.rawValue] ?? "") ?? 1000
            let overlap = Int(params[HookParam.overlap.rawValue] ?? "") ?? 0
            return .list(chunkText(input, size: size, overlap: overlap))
        case .ocrText:
            return .list(try await recognizeText(imagePath: input))
        case .readBarcode:
            return .list(try await readBarcodes(imagePath: input))
        case .detectLanguage:
            return .text(LanguageTools.detect(input)?.rawValue ?? "und")
        case .countTokens:
            // Heuristic estimate. TODO(Xcode 26.4 SDK): route through SystemLanguageModel
            // .tokenCount(for:) behind #available(macOS 26.4, *) — neither that symbol nor
            // contextSize exists in the 26.2 SDK (verified; see the TokenEstimator note).
            let count = TokenEstimator.estimate(input)
            let pct = Double(count) / Double(TokenEstimator.contextWindow) * 100
            return .object(json: #"{"tokens": \#(count), "contextWindow": \#(TokenEstimator.contextWindow), "percentOfWindow": \#(String(format: "%.1f", pct))}"#)
        case .regexExtract:
            return .text(try regexExtract(input, pattern: params[HookParam.pattern.rawValue] ?? "",
                                          group: Int(params[HookParam.group.rawValue] ?? "0") ?? 0))
        case .regexReplace:
            return .text(try regexReplace(input, pattern: params[HookParam.pattern.rawValue] ?? "",
                                          with: params[HookParam.replacement.rawValue] ?? ""))
        case .jsonExtract:
            return .text(jsonExtract(input, path: params[HookParam.path.rawValue] ?? ""))
        case .textTransform:
            return .text(textTransform(input, mode: params[HookParam.mode.rawValue] ?? "trim"))
        case .script:
            let command = params[HookParam.command.rawValue] ?? ""
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HookError.emptyCommand }
            let seconds = Int(params[HookParam.timeout.rawValue] ?? "") ?? 30
            return .text(try await runHookProcess(command: command, stdin: input, env: context,
                                                  timeout: TimeInterval(max(1, seconds))))
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

    // MARK: - Vision ops (image path in → text out; universal iOS · macOS)
    //
    // The input wire carries an image FILE PATH (a string — same lane as every other op); Vision
    // recognizes/decodes it and the result re-enters the string pipeline. `nonisolated` + `async` so
    // the Vision work runs off the main actor (§6.1), like model inference.

    /// Resolve a non-empty image path to a readable URL, or nil for empty input (→ empty result).
    nonisolated private static func imageURL(from path: String) throws -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(filePath: trimmed)
        guard FileManager.default.fileExists(atPath: url.path) else { throw HookError.fileNotFound(trimmed) }
        return url
    }

    /// Vision OCR — recognized text, one list item per text observation (top candidate).
    nonisolated private static func recognizeText(imagePath: String) async throws -> [String] {
        guard let url = try imageURL(from: imagePath) else { return [] }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        let observations = try await request.perform(on: url)
        return observations.compactMap { $0.topCandidates(1).first?.string }
    }

    /// Vision barcode / QR decode — one decoded payload string per detected symbol.
    nonisolated private static func readBarcodes(imagePath: String) async throws -> [String] {
        guard let url = try imageURL(from: imagePath) else { return [] }
        let request = DetectBarcodesRequest()
        let results = try await request.perform(on: url)
        return results.compactMap { $0.payloadString }
    }

    // MARK: - NaturalLanguage ops (reuse LanguageTools where it already owns the logic)

    private static func tokenize(_ text: String, unit: NLTokenUnit, language: String?) -> [String] {
        let tok = NLTokenizer(unit: unit)
        if let language, let lang = LanguageTools.language(named: language) { tok.setLanguage(lang) }
        tok.string = text
        return tok.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]) }
    }

    /// Deterministic per-word enrichment (surface · POS · lemma · [reading]) via the shared
    /// pipeline — one list item per word; numbering/joining is the projection's job.
    private static func enrich(_ text: String, language: String) -> [String] {
        LanguageTools.enrich(text, language: language).map { t in
            var parts = [t.surface]
            if let p = t.pos { parts.append(p) }
            if let l = t.lemma, l.lowercased() != t.surface.lowercased() { parts.append("lemma: \(l)") }
            if let r = t.romanization { parts.append("[\(r)]") }
            return parts.joined(separator: "  ·  ")
        }
    }

    // MARK: - Text / JSON ops

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
        case "fold":      return input.folding(options: .diacriticInsensitive, locale: nil)
        case "collapse":  return input.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                                       .trimmingCharacters(in: .whitespacesAndNewlines)
        default:          return input.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Split into windows of `size` characters (grapheme clusters) advancing by `size - overlap`, so
    /// consecutive chunks share `overlap` characters; the trailing partial window is kept. The
    /// canonical "prep a long doc for the context window / few-shot" op — deterministic, no NL model.
    private static func chunkText(_ input: String, size: Int, overlap: Int) -> [String] {
        let chars = Array(input)
        guard size > 0, !chars.isEmpty else { return chars.isEmpty ? [] : [input] }
        let step = max(1, size - max(0, overlap))
        var chunks: [String] = []
        var i = 0
        while i < chars.count {
            chunks.append(String(chars[i..<min(i + size, chars.count)]))
            if i + size >= chars.count { break }
            i += step
        }
        return chunks
    }
}
