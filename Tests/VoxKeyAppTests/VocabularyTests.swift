import AppKit
import AVFoundation
import CryptoKit
import Testing
@testable import VoxKeyApp
import VoxKeyCore

private func temporaryVocabularyDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxkey-vocabulary-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func packageData(
    terms: [VocabularyTerm] = [VocabularyTerm(canonical: "Quasar Ledger")],
    identifier: String = "org.example.words", version: String = "1", locale: String = "en",
    path: String = "terms.json", checksum: String? = nil, schemaVersion: Int = 1
) throws -> (manifest: Data, terms: Data) {
    let entries = try JSONSerialization.jsonObject(with: JSONEncoder().encode(terms))
    let content = try JSONSerialization.data(withJSONObject: ["schemaVersion": schemaVersion, "locale": locale, "terms": entries])
    let hash = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
    let manifest = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": schemaVersion, "identifier": identifier, "displayName": "Example Vocabulary",
        "version": version, "classification": "personal", "locales": [locale],
        "content": ["path": path, "sha256": checksum ?? hash]
    ])
    return (manifest, content)
}

private func examplePackage(terms: [VocabularyTerm] = [VocabularyTerm(canonical: "Quasar Ledger")], version: String = "1") throws -> VocabularyPackage {
    let data = try packageData(terms: terms, version: version)
    return try VocabularyPackage(manifestData: data.manifest, termsData: data.terms)
}

@MainActor @Test
func vocabularyPersistsPersonalTermsAndExplicitPackageActivation() throws {
    let directory = try temporaryVocabularyDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try VocabularyStore(directory: directory)
    try store.savePersonalTerms(" Quasar Ledger \n\nAtlas\nquasar ledger")
    try store.importPackage(examplePackage(terms: [
        VocabularyTerm(canonical: "Atlas", priority: 100),
        VocabularyTerm(canonical: "Lower", priority: 10),
        VocabularyTerm(canonical: "Higher", priority: 90, spokenForms: ["High er"])
    ]))
    #expect(store.personalTerms == ["Quasar Ledger", "Atlas"])
    #expect(store.recognitionTerms.map(\.canonical) == ["Quasar Ledger", "Atlas"])
    try store.setActive(true, identifier: "org.example.words")
    let restored = try VocabularyStore(directory: directory)
    #expect(restored.recognitionTerms.map(\.canonical) == ["Quasar Ledger", "Atlas", "Higher", "Lower"])
    #expect(restored.recognitionTerms[2].recognitionHint == "Higher (High er)")
    let frozenTerms = restored.recognitionTerms
    try restored.setActive(false, identifier: "org.example.words")
    #expect(restored.recognitionTerms.count == 2)
    #expect(frozenTerms.count == 4)
    try restored.setActive(true, identifier: "org.example.words")
    try restored.importPackage(examplePackage(version: "2"))
    let replaced = try VocabularyStore(directory: directory)
    #expect(replaced.packages.count == 1)
    #expect(replaced.packages.first?.package.manifest.version == "2")
    #expect(replaced.packages.first?.active == false)
    try replaced.removePackage(identifier: "org.example.words")
    #expect(try VocabularyStore(directory: directory).packages.isEmpty)
    #expect(try VocabularyStore(directory: directory).personalTerms == ["Quasar Ledger", "Atlas"])
}

@Test(arguments: ["\u{0000}", "Hello\tthere", "<|startoftranscript|>", String(repeating: "a", count: 81)])
func invalidVocabularyTermsAreRejected(_ term: String) throws {
    #expect(throws: VocabularyError.self) { try VocabularyRules.personalTerms(from: term) }
    #expect(throws: VocabularyError.self) { try examplePackage(terms: [VocabularyTerm(canonical: term)]) }
}

@Test
func vocabularyRejectsDuplicateAndInvalidPackageEntries() throws {
    for terms in [
        [VocabularyTerm(canonical: "Atlas"), VocabularyTerm(canonical: "atlas")],
        [VocabularyTerm(canonical: "Atlas", priority: -1)],
        [VocabularyTerm(canonical: "Atlas", spokenForms: ["<|nospeech|>"])],
        Array(repeating: VocabularyTerm(canonical: "Atlas"), count: 501)
    ] {
        #expect(throws: VocabularyError.self) { try examplePackage(terms: terms) }
    }
    #expect(throws: VocabularyError.self) {
        try VocabularyRules.personalTerms(from: (0..<201).map { "Term \($0)" }.joined(separator: "\n"))
    }
}

@MainActor @Test
func vocabularyPreviewRejectsTamperingTraversalSymlinksAndWrongFormats() throws {
    let directory = try temporaryVocabularyDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manifestURL = directory.appendingPathComponent("manifest.json")
    let termsURL = directory.appendingPathComponent("terms.json")
    for data in [
        try packageData(locale: "es"), try packageData(path: "../terms.json"),
        try packageData(checksum: String(repeating: "0", count: 64)), try packageData(schemaVersion: 2)
    ] {
        try data.manifest.write(to: manifestURL)
        try data.terms.write(to: termsURL)
        #expect(throws: VocabularyError.self) { try VocabularyStore.previewPackage(at: directory) }
    }
    let valid = try packageData()
    try valid.manifest.write(to: manifestURL)
    try valid.terms.write(to: termsURL)
    let preview = try VocabularyStore.previewPackage(at: manifestURL)
    #expect(preview.terms.count == 1)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("vocabulary.json").path))
    try FileManager.default.removeItem(at: termsURL)
    try FileManager.default.createSymbolicLink(at: termsURL, withDestinationURL: manifestURL)
    #expect(throws: VocabularyError.self) { try VocabularyStore.previewPackage(at: directory) }
}

@MainActor @Test
func vocabularySaveFailureLeavesMemoryAndExistingDataUntouched() throws {
    let directory = try temporaryVocabularyDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try VocabularyStore(directory: directory)
    try store.savePersonalTerms("Atlas")
    let file = directory.appendingPathComponent("vocabulary.json")
    let before = try Data(contentsOf: file)
    #expect(throws: VocabularyError.self) { try store.savePersonalTerms("<|bad|>") }
    #expect(try Data(contentsOf: file) == before)
    #expect(store.personalTerms == ["Atlas"])
    // A directory at the destination creates a real atomic-write failure without permission mocks.
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try store.savePersonalTerms("New term") }
    #expect(store.personalTerms == ["Atlas"])
    #expect(throws: VocabularyError.self) { try VocabularyStore(directory: directory) }
}

@MainActor @Test
func corruptSavedVocabularyIsNeverOverwrittenOnLoad() throws {
    let directory = try temporaryVocabularyDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("vocabulary.json")
    let corrupt = Data("{broken".utf8)
    try corrupt.write(to: file)
    #expect(throws: VocabularyError.self) { try VocabularyStore(directory: directory) }
    #expect(try Data(contentsOf: file) == corrupt)
}

@MainActor @Test
func vocabularyWindowSavesTermsAndControlsRealPackageState() throws {
    _ = NSApplication.shared
    let directory = try temporaryVocabularyDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try VocabularyStore(directory: directory)
    try store.importPackage(examplePackage())
    let controller = VocabularyWindowController(store: store)
    let root = try #require(controller.window?.contentView)
    root.layoutSubtreeIfNeeded()
    let views = root.vocabularyDescendants
    let editor = try #require(views.compactMap { $0 as? NSTextView }.first)
    editor.string = "Atlas\nQuasar Ledger"
    let buttons = views.compactMap { $0 as? NSButton }
    try #require(buttons.first { $0.title == "Save Terms" }).performClick(nil)
    #expect(try VocabularyStore(directory: directory).personalTerms == ["Atlas", "Quasar Ledger"])
    let active = try #require(buttons.first { $0.title == "Use this package" })
    #expect(active.state == .off)
    active.performClick(nil)
    #expect(try VocabularyStore(directory: directory).packages.first?.active == true)
    for view in views where (view is NSTextField || view is NSButton) && !view.isHiddenOrHasHiddenAncestor {
        #expect(root.bounds.insetBy(dx: -1, dy: -1).contains(root.convert(view.bounds, from: view)))
    }
    try #require(buttons.first { $0.title == "Remove" }).performClick(nil)
    #expect(try VocabularyStore(directory: directory).packages.isEmpty)
    #expect(!active.isEnabled)
}

private extension NSView {
    var vocabularyDescendants: [NSView] { [self] + subviews.flatMap(\.vocabularyDescendants) }
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_VOCABULARY_TEST_PACKAGE"] != nil))
func suppliedLocalVocabularyPackageImportsWithoutBundlingItsContents() throws {
    let path = try #require(ProcessInfo.processInfo.environment["VOXKEY_VOCABULARY_TEST_PACKAGE"])
    let directory = try temporaryVocabularyDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let package = try VocabularyStore.previewPackage(at: URL(fileURLWithPath: path))
    let store = try VocabularyStore(directory: directory)
    try store.importPackage(package)
    #expect(store.recognitionTerms.isEmpty)
    try store.setActive(true, identifier: package.manifest.identifier)
    #expect(try VocabularyStore(directory: directory).recognitionTerms.count == package.terms.count)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_VOCABULARY_TEST_AUDIO"] != nil))
@MainActor
func installedLocalModelTranscribesWithBoundedVocabularyHints() async throws {
    let transcriber = WhisperTranscriber()
    try await transcriber.prepare(download: false)
    let terms = [VocabularyTerm(canonical: "Quasar Ledger")] + (0..<200).map { VocabularyTerm(canonical: "Astral term \($0)") }
    let tokens = try await transcriber.vocabularyPromptTokens(terms)
    #expect(!tokens.isEmpty)
    #expect(tokens.count <= TranscriptionVocabulary.tokenBudget)
    let first = try await transcriber.vocabularyPromptTokens(Array(terms.prefix(1)))
    #expect(Array(tokens.prefix(first.count)) == first)
    #expect(try await transcriber.vocabularyPromptTokens([]).isEmpty)
    let path = try #require(ProcessInfo.processInfo.environment["VOXKEY_VOCABULARY_TEST_AUDIO"])
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    try #require(file.length > 0, "The synthetic audio fixture must contain speech frames")
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let samples = Array(UnsafeBufferPointer(start: try #require(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
    #expect(SpeechActivityGate.startStatus(in: samples, sampleRate: Int(file.processingFormat.sampleRate)) == .speech)
    let capture = CapturedAudio(samples: samples, sampleRate: file.processingFormat.sampleRate, overflowed: false)
    let baseline = try await transcriber.transcribe(capture)
    guard case .final = baseline else { Issue.record("Synthetic speech failed even without vocabulary hints"); return }
    let outcome = try await transcriber.transcribe(capture, vocabulary: Array(terms.prefix(1)))
    guard case let .final(text) = outcome else { Issue.record("Synthetic speech produced no final transcription"); return }
    #expect(text.lowercased().contains("quasar"))
    #expect(text.lowercased().contains("ledger"))
    // Exercise the upstream decoder with the entire bounded prompt, not only one hint.
    // The former prefill bug returned an empty transcript before decoding any speech.
    let fullPromptOutcome = try await transcriber.transcribe(capture, vocabulary: terms)
    guard case let .final(fullPromptText) = fullPromptOutcome else {
        Issue.record("A full vocabulary prompt suppressed synthetic speech")
        return
    }
    #expect(fullPromptText.lowercased().contains("quasar"))
    #expect(fullPromptText.lowercased().contains("ledger"))
    if let packagePath = ProcessInfo.processInfo.environment["VOXKEY_VOCABULARY_TEST_PACKAGE"] {
        let package = try VocabularyStore.previewPackage(at: URL(fileURLWithPath: packagePath))
        let combined = VocabularyRules.orderedTerms(personal: ["Quasar Ledger"], packages: [package])
        let combinedTokens = try await transcriber.vocabularyPromptTokens(combined)
        #expect(combinedTokens.count <= TranscriptionVocabulary.tokenBudget)
        let combinedOutcome = try await transcriber.transcribe(capture, vocabulary: combined)
        guard case let .final(combinedText) = combinedOutcome else { Issue.record("Package hints suppressed synthetic speech"); return }
        #expect(combinedText.lowercased().contains("quasar"))
        #expect(combinedText.lowercased().contains("ledger"))
    }
    let silence = CapturedAudio(samples: Array(repeating: 0, count: 16_000), sampleRate: 16_000, overflowed: false)
    #expect(try await transcriber.transcribe(silence, vocabulary: terms) == .noSpeech)
}
