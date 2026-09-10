import CoreML
import Foundation

enum GrammarCorrectionError: Error { case invalidAssets, inputTooLong, invalidPrediction }

enum GrammarCorrectionState: Sendable, Equatable {
    case off, waiting, loading, ready, unavailable
    case downloadRequired, downloading(Double), preparing

    var message: String {
        switch self {
        case .off: "Off. No extra processing."
        case .waiting: "On. Prepares locally when recording starts."
        case .loading: "Preparing grammar correction…"
        case .ready: "On. English dictation is corrected locally."
        case .unavailable: "Correction unavailable. Original transcriptions are still delivered."
        case .downloadRequired: "Download the grammar model to enable correction."
        case let .downloading(fraction): "Downloading grammar model… \(Int(fraction * 100))%. Dictation continues without correction."
        case .preparing: "Preparing grammar correction… Dictation continues without correction."
        }
    }
}

/// Owns the optional model outside the main actor. No audio, surrounding field
/// context, network access, or transcript logging enters this component.
actor GrammarCorrector {
    static let tokenLimit = 80
    static let preferenceKey = "VoxKeyGrammarCorrectionEnabled"
    static var isAvailable: Bool { isAvailable(in: .main) }

    static func isAvailable(in bundle: Bundle) -> Bool {
        bundle.object(forInfoDictionaryKey: "VoxKeyGrammarAvailable") as? Bool == true
    }

    nonisolated let updates: AsyncStream<GrammarCorrectionState>
    private let continuation: AsyncStream<GrammarCorrectionState>.Continuation
    private let suppliedAssets: URL?
    private var assets: URL?
    private let store: GrammarModelStore
    private var installationTask: Task<Void, Never>?
    private var installationGeneration: Int?
    private let computeUnits: MLComputeUnits
    private var enabled = false
    private var generation = 0
    private var model: MLModel?
    private var tokenizer: GectorTokenizer?
    private var labels: [String: String] = [:]
    private var verbs: [String: String] = [:]
    var isLoaded: Bool { model != nil }

    init(assets: URL? = nil, computeUnits: MLComputeUnits = .cpuAndGPU, store: GrammarModelStore = GrammarModelStore()) {
        self.assets = assets
        suppliedAssets = assets
        self.store = store
        self.computeUnits = computeUnits
        let stream = AsyncStream.makeStream(of: GrammarCorrectionState.self, bufferingPolicy: .bufferingNewest(1))
        updates = stream.stream
        continuation = stream.continuation
        continuation.yield(.off)
    }

    deinit { installationTask?.cancel(); continuation.finish() }

    func setEnabled(_ value: Bool, download: Bool = false, repair: Bool = false) {
        guard value != enabled || download else { return }
        enabled = value
        generation += 1
        installationTask?.cancel()
        installationGeneration = nil
        if !value {
            model = nil
            tokenizer = nil
            labels = [:]
            verbs = [:]
            assets = suppliedAssets
        }
        continuation.yield(value ? .waiting : .off)
        guard value, suppliedAssets == nil else { return }
        model = nil
        assets = nil
        let requestGeneration = generation
        installationGeneration = requestGeneration
        let previous = installationTask
        installationTask = Task {
            _ = await previous?.result
            guard !Task.isCancelled, enabled, generation == requestGeneration else { return }
            do {
                let prepared = try await store.prepare(download: download, repair: repair) { [weak self] state in
                    Task { await self?.preparationProgress(state, generation: requestGeneration) }
                }
                guard !Task.isCancelled, enabled, generation == requestGeneration else { return }
                assets = prepared
                installationGeneration = nil
                continuation.yield(.waiting)
            } catch {
                guard !Task.isCancelled, enabled, generation == requestGeneration else { return }
                installationGeneration = nil
                continuation.yield(error as? GrammarInstallationError == .downloadRequired
                    ? .downloadRequired : .unavailable)
            }
        }
    }

    private func preparationProgress(_ state: GrammarCorrectionState, generation: Int) {
        guard enabled, installationGeneration == generation else { return }
        continuation.yield(state)
    }

    func correct(_ original: String, enabledForSession: Bool) async -> String {
        await correctUsingCache(original, enabledForSession: enabledForSession, cache: .init()).text
    }

    func warmUp(enabledForSession: Bool) async {
        guard enabledForSession, enabled, assets != nil, !Task.isCancelled else { return }
        let requestGeneration = generation
        let needsFirstPrediction = model == nil
        do {
            try loadAssets()
            if needsFirstPrediction {
                // Loading alone leaves first-prediction setup on the release
                // path. Prime the fixed-shape graph with non-user text while
                // recording; its output is never cached or delivered.
                _ = try await correctChunk("This is a sentence.", generation: requestGeneration)
            }
        } catch {
            if enabled, generation == requestGeneration, !Task.isCancelled { continuation.yield(.unavailable) }
        }
    }

    func correctUsingCache(_ original: String, enabledForSession: Bool,
                           cache: GrammarCorrectionCache,
                           preserveShortContext: Bool = true) async -> GrammarCorrectionResult {
        let unchanged = GrammarCorrectionResult(text: original, cache: .init())
        guard enabledForSession, enabled, assets != nil, !Task.isCancelled,
              !original.isEmpty,
              !["$START", "$DELETE", "$MERGE_", "<s>", "</s>", "<mask>", "<pad>", "<unk>"].contains(where: original.contains)
        else { return unchanged }
        let requestGeneration = generation
        do {
            try loadAssets()
            guard let tokenizer else { throw GrammarCorrectionError.invalidAssets }
            let ranges = try GrammarChunker.ranges(in: original, tokenizer: tokenizer,
                                                 preserveShortContext: preserveShortContext)
            var result = ""
            var nextCache = GrammarCorrectionCache(generation: requestGeneration)
            var cursor = original.startIndex
            for range in ranges {
                await Task.yield()
                guard enabled, generation == requestGeneration, !Task.isCancelled else { return unchanged }
                result += original[cursor..<range.lowerBound]
                let chunk = String(original[range])
                let corrected: String
                if cache.generation == requestGeneration, let previous = cache.chunks[chunk] {
                    corrected = previous
                } else {
                    do {
                        corrected = try await correctChunk(chunk, generation: requestGeneration)
                    } catch GrammarCorrectionError.inputTooLong {
                        // An edit can push a full chunk over the model's input size.
                        // Preserve that chunk while allowing the rest to be corrected.
                        corrected = chunk
                    }
                }
                result += corrected
                nextCache.chunks[chunk] = corrected
                cursor = range.upperBound
            }
            guard enabled, generation == requestGeneration, !Task.isCancelled else { return unchanged }
            result += original[cursor...]
            return GrammarCorrectionResult(text: result, cache: nextCache)
        } catch {
            if enabled, generation == requestGeneration, !Task.isCancelled { continuation.yield(.unavailable) }
            return unchanged
        }
    }

    private func correctChunk(_ original: String, generation requestGeneration: Int) async throws -> String {
        guard GrammarChunker.hasSupportedSpacing(original) else { return original }
        guard let model, let tokenizer else { throw GrammarCorrectionError.invalidAssets }
        var words = ["$START"] + original.components(separatedBy: " ")
        for _ in 0..<5 {
            // Keep Core ML's non-Sendable model and outputs on this actor.
            // Yield between bounded predictions so disabling can invalidate work.
            await Task.yield()
            guard enabled, generation == requestGeneration, !Task.isCancelled else { return original }
            let input = try Self.tokenize(words, with: tokenizer)
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": Self.array(input.ids + Array(repeating: 1, count: Self.tokenLimit - input.ids.count)),
                "attention_mask": Self.array((0..<Self.tokenLimit).map { $0 < input.ids.count ? 1 : 0 }),
                "word_masks": Self.array(input.masks + Array(repeating: 0, count: Self.tokenLimit - input.masks.count))
            ])
            let prediction = try predict(model, from: provider)
            guard enabled, generation == requestGeneration, !Task.isCancelled else { return original }
            guard let values = prediction.featureValue(for: "tags")?.multiArrayValue, values.count == Self.tokenLimit else {
                throw GrammarCorrectionError.invalidPrediction
            }
            let tags = try input.starts.map { index in
                guard let tag = labels[String(values[index].intValue)] else { throw GrammarCorrectionError.invalidPrediction }
                return tag
            }
            if tags.allSatisfy({ ["$KEEP", "<PAD>", "<OOV>"].contains($0) }) { break }
            let edited = zip(words, tags).map { Self.edit($0, tag: $1, verbs: verbs) }.joined(separator: " ")
                .replacingOccurrences(of: " $MERGE_HYPHEN ", with: "-")
                .replacingOccurrences(of: " $MERGE_SPACE ", with: "")
                .replacingOccurrences(of: " $DELETE", with: "")
                .replacingOccurrences(of: "$DELETE ", with: "")
            let next = edited.components(separatedBy: " ")
            if next == words { break }
            words = next
        }
        guard words.first == "$START" else { return original }
        let result = words.dropFirst().joined(separator: " ")
        guard !result.isEmpty, !result.contains("$MERGE_"), !result.contains("$DELETE") else { return original }
        return result
    }

    private func predict(_ model: MLModel, from input: MLFeatureProvider) throws -> MLFeatureProvider {
        try model.prediction(from: input)
    }

    private func loadAssets() throws {
        guard model == nil else { return }
        continuation.yield(.loading)
        guard let assets else { throw GrammarCorrectionError.invalidAssets }
        let newTokenizer = try GectorTokenizer(contentsOf: assets.appendingPathComponent("tokenizer.json"))
        struct Configuration: Decodable { let id2label: [String: String] }
        let configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: assets.appendingPathComponent("config.json")))
        var newVerbs: [String: String] = [:]
        for line in try String(contentsOf: assets.appendingPathComponent("verb-form-vocab.txt"), encoding: .utf8).split(separator: "\n") {
            let parts = line.split(separator: ":")
            guard parts.count == 2 else { throw GrammarCorrectionError.invalidAssets }
            let words = parts[0].split(separator: "_")
            let tags = parts[1].split(separator: "_")
            guard words.count == 2, tags.count == 2 else { throw GrammarCorrectionError.invalidAssets }
            let key = "\(words[0])_\(tags[0])_\(tags[1])"
            if newVerbs[key] == nil { newVerbs[key] = String(words[1]) }
        }
        let options = MLModelConfiguration()
        options.computeUnits = computeUnits
        let newModel = try MLModel(contentsOf: assets.appendingPathComponent("Gector.mlmodelc"), configuration: options)
        tokenizer = newTokenizer
        labels = configuration.id2label
        verbs = newVerbs
        model = newModel
        continuation.yield(.ready)
    }

    static func tokenize(_ words: [String], with tokenizer: GectorTokenizer) throws -> (ids: [Int], masks: [Int], starts: [Int]) {
        var ids = [0], masks = [0], starts: [Int] = []
        for (index, word) in words.enumerated() {
            starts.append(ids.count)
            let tokens = try tokenizer.encode(word: word)
            guard !tokens.isEmpty else { throw GrammarCorrectionError.invalidAssets }
            ids += tokens
            masks += tokens.indices.map { $0 == 0 && index > 0 ? 1 : 0 }
            guard ids.count < tokenLimit else { throw GrammarCorrectionError.inputTooLong }
        }
        ids.append(2)
        masks.append(0)
        return (ids, masks, starts)
    }

    private static func array(_ values: [Int]) throws -> MLMultiArray {
        let result = try MLMultiArray(shape: [1, NSNumber(value: tokenLimit)], dataType: .int32)
        for (index, value) in values.enumerated() { result[index] = NSNumber(value: value) }
        return result
    }

    private static func edit(_ token: String, tag: String, verbs: [String: String]) -> String {
        if tag.hasPrefix("$APPEND_") { return token + " " + tag.dropFirst(8) }
        if token == "$START" || ["$KEEP", "<PAD>", "<OOV>"].contains(tag) { return token }
        switch tag {
        case "$TRANSFORM_CASE_LOWER": return token.lowercased()
        case "$TRANSFORM_CASE_UPPER": return token.uppercased()
        case "$TRANSFORM_CASE_CAPITAL": return token.prefix(1).uppercased() + token.dropFirst().lowercased()
        case "$TRANSFORM_CASE_CAPITAL_1": return String(token.prefix(1)) + token.dropFirst().prefix(1).uppercased() + token.dropFirst(2).lowercased()
        case "$TRANSFORM_AGREEMENT_PLURAL": return token + "s"
        case "$TRANSFORM_AGREEMENT_SINGULAR": return String(token.dropLast())
        case "$TRANSFORM_SPLIT_HYPHEN": return token.replacingOccurrences(of: "-", with: " ")
        case "$DELETE": return tag
        default:
            if tag.hasPrefix("$TRANSFORM_VERB_") { return verbs[token + "_" + tag.dropFirst(16)] ?? token }
            if tag.hasPrefix("$REPLACE_") { return String(tag.dropFirst(9)) }
            if tag.hasPrefix("$MERGE_") { return token + " " + tag }
            return token
        }
    }
}
