import AppKit
import Foundation
import Testing
@testable import VoxKeyApp

@Test func grammarCorrectionStartsOffAndLeavesTextUntouchedWithoutAssets() async {
    let corrector = GrammarCorrector(assets: URL(fileURLWithPath: "/missing-voxkey-grammar-model"))
    let input = "Okay, make sense, thanks."
    #expect(await corrector.correct(input, enabledForSession: true) == input)
    #expect(await !corrector.isLoaded)
    await corrector.setEnabled(true)
    #expect(await corrector.correct(input, enabledForSession: false) == input)
    #expect(await !corrector.isLoaded)
}

@Test func unavailableGrammarModelFallsBackToTheOriginalTranscript() async {
    let corrector = GrammarCorrector(assets: URL(fileURLWithPath: "/missing-voxkey-grammar-model"))
    await corrector.setEnabled(true)
    let input = "Don't change the $125.50 total."
    #expect(await corrector.correct(input, enabledForSession: true) == input)
    var updates = corrector.updates.makeAsyncIterator()
    #expect(await updates.next() == .unavailable)
    await corrector.setEnabled(false)
    #expect(await updates.next() == .off)
}

@MainActor @Test(arguments: [NSAppearance.Name.aqua, .darkAqua],
                 [GrammarCorrectionState.waiting, .downloading(0.42), .preparing, .downloadRequired, .unavailable])
func optionalGrammarControlsFitAndStayInSync(_ appearance: NSAppearance.Name, _ state: GrammarCorrectionState) throws {
    _ = NSApplication.shared
    // Setup and Settings each own a grammar card. AppController mirrors a change in
    // one to the other; here both receive the same state and must render it.
    let setup = OnboardingWindowController(grammarAvailable: true)
    let settings = SettingsWindowController(grammarAvailable: true)
    settings.selectPane(.dictation)
    #expect(setup.setupGrammarCheckbox.state == .off)
    #expect(settings.grammarCheckbox.state == .off)
    var requested: [Bool] = []
    setup.onGrammarCorrectionChanged = { requested.append($0) }
    settings.onGrammarCorrectionChanged = { requested.append($0) }
    setup.setupGrammarCheckbox.performClick(nil)
    #expect(requested == [true])
    setup.updateGrammarCorrection(enabled: true, state: state)
    settings.updateGrammarCorrection(enabled: true, state: state)
    #expect(settings.grammarCheckbox.state == .on)
    for (page, controller) in [("setup", setup as NSWindowController), ("settings", settings)] {
        controller.window?.appearance = NSAppearance(named: appearance)
        let root = try #require(controller.window?.contentView)
        root.layoutSubtreeIfNeeded()
        func check(_ view: NSView) {
            if view is NSControl, !view.isHiddenOrHasHiddenAncestor {
                #expect(root.bounds.insetBy(dx: -1, dy: -1).contains(root.convert(view.bounds, from: view)))
            }
            view.subviews.forEach(check)
        }
        check(root)
        if let directory = ProcessInfo.processInfo.environment["VOXKEY_SETTINGS_PREVIEW_DIR"] {
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("grammar-\(page)-\(appearance.rawValue)-\(state).png"))
        }
    }
    settings.grammarCheckbox.performClick(nil)
    #expect(requested == [true, false])
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_TEST_ASSETS"] != nil))
func longGrammarCorrectionPreservesParagraphsAndCorrectsEverySentence() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_TEST_ASSETS"])
    let corrector = GrammarCorrector(assets: URL(fileURLWithPath: path))
    await corrector.setEnabled(true)
    let sentences = Array(repeating: "Okay, make sense, thanks.", count: 90)
    let expected = Array(repeating: "Okay, makes sense, thanks.", count: 90)
    for separator in [" ", "\n\n"] {
        let original = sentences.joined(separator: separator)
        #expect(original.utf8.count > 2_000)
        #expect(await corrector.correct(original, enabledForSession: true) == expected.joined(separator: separator))
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_TEST_ASSETS"] != nil))
func anOversizedWordDoesNotPreventCorrectionOfTheRestOfTheDictation() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_TEST_ASSETS"])
    let corrector = GrammarCorrector(assets: URL(fileURLWithPath: path))
    await corrector.setEnabled(true)
    let oversized = String(repeating: "z", count: 2_400)
    let original = "Okay, make sense, thanks.\n\n\(oversized)\n\nOkay, make sense, thanks."
    let expected = "Okay, makes sense, thanks.\n\n\(oversized)\n\nOkay, makes sense, thanks."
    #expect(await corrector.correct(original, enabledForSession: true) == expected)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_TEST_ASSETS"] != nil))
func preparedGrammarModelMatchesTheQualifiedNativeCorpusAndUnloadsWhenDisabled() async throws {
    struct Fixture: Decodable { let input: String; let output: String; let initialTokens: [Int] }
    let directory = try #require(ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_TEST_ASSETS"])
    let assets = URL(fileURLWithPath: directory)
    let fixturesURL = try #require(Bundle.module.url(forResource: "coreml-fp16", withExtension: "json", subdirectory: "Grammar"))
    let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: fixturesURL))
    #expect(fixtures.count == 64)
    let tokenizer = try GectorTokenizer(contentsOf: assets.appendingPathComponent("tokenizer.json"))
    let corrector = GrammarCorrector(assets: assets)
    await corrector.setEnabled(true)
    for fixture in fixtures {
        let tokens = try GrammarCorrector.tokenize(["$START"] + fixture.input.components(separatedBy: " "), with: tokenizer)
        #expect(tokens.ids == fixture.initialTokens, "Tokenizer parity: \(fixture.input)")
        #expect(await corrector.correct(fixture.input, enabledForSession: true) == fixture.output, "Native output parity: \(fixture.input)")
    }
    #expect(await corrector.isLoaded)
    // Long inputs are now corrected; only the remaining formatting/marker
    // preservation cases belong in this former oversized-input bypass check.
    for input in ["Okay,  make sense, thanks.", "First line.\nSecond line.", "Say $START literally."] {
        let output = await corrector.correct(input, enabledForSession: true)
        #expect(output == input)
    }
    await corrector.setEnabled(false)
    #expect(await !corrector.isLoaded)
    #expect(await corrector.correct("Okay, make sense, thanks.", enabledForSession: true) == "Okay, make sense, thanks.")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_TEST_ASSETS"] != nil))
func oversizedSentencesSplitOnWordsWithinTheActualTokenBudget() throws {
    let path = try #require(ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_TEST_ASSETS"])
    let tokenizer = try GectorTokenizer(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("tokenizer.json"))
    let original = Array(repeating: "extraordinarily", count: 200).joined(separator: " ")
    let ranges = try GrammarChunker.ranges(in: original, tokenizer: tokenizer)
    #expect(ranges.count > 1)
    #expect(ranges.map { String(original[$0]) }.joined(separator: " ") == original)
    for range in ranges {
        let input = try GrammarCorrector.tokenize(["$START"] + original[range].components(separatedBy: " "), with: tokenizer)
        #expect(input.ids.count <= GrammarCorrector.tokenLimit)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_TEST_ASSETS"] != nil), .timeLimit(.minutes(1)))
func disablingDuringLongCorrectionReturnsTheWholeOriginalTranscript() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_TEST_ASSETS"])
    let corrector = GrammarCorrector(assets: URL(fileURLWithPath: path))
    await corrector.setEnabled(true)
    let original = Array(repeating: "Okay, make sense, thanks.", count: 90).joined(separator: " ")
    let correction = Task { await corrector.correct(original, enabledForSession: true) }
    defer { correction.cancel() }
    for await state in corrector.updates {
        try #require(state != .unavailable)
        if state == .ready { break }
    }
    await corrector.setEnabled(false)
    #expect(await correction.value == original)
    #expect(await !corrector.isLoaded)
}
