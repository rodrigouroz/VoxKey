import Foundation
import Testing
@testable import VoxKeyApp

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_TEST_ASSETS"] != nil))
func incrementalCorrectionUsesTheFinalChunkContextWithoutChangingItsOutput() async throws {
    let corrector = try sessionTestCorrector()
    await corrector.setEnabled(true)
    let sentences = ["Okay, make sense, thanks.", "The build is not ready.", "Do not deploy it.",
                     "These is the files I need.", "The new version work on my Mac."]
    let original = Array(repeating: sentences, count: 8).flatMap { $0 }.joined(separator: " ")
    var cache = GrammarCorrectionCache()
    var prefix = ""
    for sentence in original.split(separator: ".", omittingEmptySubsequences: true) {
        prefix += (prefix.isEmpty ? "" : " ") + sentence.trimmingCharacters(in: .whitespaces) + "."
        let result = await corrector.correctUsingCache(prefix, enabledForSession: true, cache: cache)
        #expect(result.text == (await corrector.correct(prefix, enabledForSession: true)))
        cache = result.cache
    }
    #expect(cache.chunks.count <= sentences.count)
    let final = await corrector.correctUsingCache(original, enabledForSession: true, cache: cache)
    #expect(final.text == (await corrector.correct(original, enabledForSession: true)))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_TEST_ASSETS"] != nil))
func disablingCorrectionInvalidatesAnAlreadyCorrectedSession() async throws {
    let corrector = try sessionTestCorrector()
    await corrector.setEnabled(true)
    let original = "Okay, make sense, thanks."
    let cached = await corrector.correctUsingCache(original, enabledForSession: true, cache: .init())
    #expect(cached.text == "Okay, makes sense, thanks.")
    let session = GrammarCorrectionSession(corrector: corrector, enabled: true)
    session.observe(original)
    await corrector.setEnabled(false)
    #expect(await session.finish(original) == original)
    let disabled = await corrector.correctUsingCache(original, enabledForSession: true, cache: cached.cache)
    #expect(disabled.text == original)
    #expect(disabled.cache.chunks.isEmpty)
    await corrector.setEnabled(true)
    let next = await corrector.correctUsingCache(original, enabledForSession: true, cache: cached.cache)
    #expect(next.cache.generation != cached.cache.generation)
    #expect(next.text == cached.text)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_TEST_ASSETS"] != nil))
func coalescedCorrectionAlwaysFinishesTheLatestTranscriptAndCancellationPreservesIt() async throws {
    let corrector = try sessionTestCorrector()
    await corrector.setEnabled(true)
    let session = GrammarCorrectionSession(corrector: corrector, enabled: true)
    for count in 1...90 {
        session.observe(Array(repeating: "Okay, make sense, thanks.", count: count).joined(separator: " "))
    }
    let final = "These is the files I need."
    #expect(await session.finish(final) == (await corrector.correct(final, enabledForSession: true)))
    let cancelled = GrammarCorrectionSession(corrector: corrector, enabled: true)
    cancelled.observe(final)
    cancelled.cancel()
    #expect(await cancelled.finish(final) == final)
}

@Test func correctionSessionWithoutAssetsOrOptInPreservesTheFinalText() async {
    let corrector = GrammarCorrector(assets: URL(fileURLWithPath: "/missing-voxkey-grammar-model"))
    for enabled in [false, true] {
        await corrector.setEnabled(enabled)
        let session = GrammarCorrectionSession(corrector: corrector, enabled: enabled)
        session.observe("An earlier phrase.")
        let final = "Okay, make sense, thanks."
        #expect(await session.finish(final) == final)
    }
    #expect(await !corrector.isLoaded)
}

private func sessionTestCorrector() throws -> GrammarCorrector {
    let path = try #require(ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_TEST_ASSETS"])
    return GrammarCorrector(assets: URL(fileURLWithPath: path))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_TEST_ASSETS"] != nil))
func prospectiveSentenceCorrectionsSurviveTheTransitionToLongText() async throws {
    let corrector = try sessionTestCorrector()
    await corrector.setEnabled(true)
    let short = "Okay, make sense, thanks. These is the files I need."
    let prepared = await corrector.correctUsingCache(short, enabledForSession: true, cache: .init(), preserveShortContext: false)
    #expect(prepared.cache.chunks["Okay, make sense, thanks."] == "Okay, makes sense, thanks.")
    #expect(prepared.cache.chunks["These is the files I need."] == "These are the files I need.")
    let shortFinal = await corrector.correctUsingCache(short, enabledForSession: true, cache: prepared.cache)
    #expect(shortFinal.text == (await corrector.correct(short, enabledForSession: true)))
    #expect(shortFinal.cache.chunks.count == 1)
    let long = Array(repeating: short, count: 15).joined(separator: " ")
    let longFinal = await corrector.correctUsingCache(long, enabledForSession: true, cache: prepared.cache)
    #expect(longFinal.cache.chunks == prepared.cache.chunks)
    #expect(longFinal.text == (await corrector.correct(long, enabledForSession: true)))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_TEST_ASSETS"] != nil))
func grammarWarmupRequiresOptInAndNeverBecomesTheDictationResult() async throws {
    let corrector = try sessionTestCorrector()
    await corrector.warmUp(enabledForSession: true)
    #expect(await !corrector.isLoaded)
    await corrector.setEnabled(true)
    await corrector.warmUp(enabledForSession: false)
    #expect(await !corrector.isLoaded)
    await corrector.warmUp(enabledForSession: true)
    #expect(await corrector.isLoaded)
    let session = GrammarCorrectionSession(corrector: corrector, enabled: true)
    #expect(await session.finish("Okay, make sense, thanks.") == "Okay, makes sense, thanks.")
    await corrector.setEnabled(false)
    #expect(await !corrector.isLoaded)
}
