import AppKit
import CryptoKit
import Foundation
import Testing
@testable import VoxKeyApp

@Test func packagedGrammarResourcesNeverFallBackToTheDeveloperCheckout() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("grammar-bundle-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for present in [false, true] {
        let appURL = root.appendingPathComponent("Candidate-\(present).app")
        let contents = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.voxkey.grammar.\(present)", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = contents.appendingPathComponent("Resources/VoxKey_VoxKeyApp.bundle")
        if present { try FileManager.default.createDirectory(at: bundle.appendingPathComponent("GrammarPreparation"), withIntermediateDirectories: true) }
        let app = try #require(Bundle(url: appURL))
        let resolved = GrammarModelStore.preparationResources(in: app)
        if present { #expect(resolved?.path.hasPrefix(appURL.path) == true) }
        else { #expect(resolved == nil) }
    }
}

@Test func grammarInstallationRequiresAnExplicitDownloadAndCreatesNothingWhenDisabled() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("grammar-no-download-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = GrammarModelStore(root: root)
    await #expect(throws: GrammarInstallationError.downloadRequired) { try await store.prepare(download: false) }
    #expect(!FileManager.default.fileExists(atPath: root.path))
    let corrector = GrammarCorrector(store: store)
    #expect(await corrector.correct("Okay, make sense, thanks.", enabledForSession: true) == "Okay, make sense, thanks.")
    #expect(!FileManager.default.fileExists(atPath: root.path))
    await corrector.setEnabled(true)
    for await state in corrector.updates {
        if state == .downloadRequired { break }
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
    await corrector.setEnabled(false)
}

@Test func nativeFP16PreparationWritesTheExpectedLayoutAndRejectsInvalidSource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("grammar-convert-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let output = root.appendingPathComponent("weights")
    // Fixed little-endian IEEE 754 bytes: 1.0, -2.0, 0.0, preceded by a header.
    try Data([0xff, 0xff, 0xff, 0xff, 0, 0, 0x80, 0x3f, 0, 0, 0, 0xc0, 0, 0, 0, 0]).write(to: source)
    let expected = Data([0xab, 0xcd, 0, 0, 0, 0x3c, 0, 0xc0, 0, 0, 0, 0x3c, 0, 0xc0, 0, 0])
    let hash = SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined()
    let recipe = GrammarModelRecipe(identifier: "fixture", modelBytes: 0, modelSHA256: "", files: [], outputBytes: expected.count, outputSHA256: hash,
                                    constants: [.init(offset: 0, data: Data([0xab, 0xcd]))],
                                    conversions: [.init(sourceOffset: 4, count: 3, destinationOffset: 4, repetitions: 2)])
    try await GrammarModelStore.convert(source: source, destination: output, recipe: recipe)
    #expect(try Data(contentsOf: output) == expected)
    #expect(try GrammarModelStore.matches(output, bytes: expected.count, sha256: hash))
    #expect(try !GrammarModelStore.matches(output, bytes: expected.count, sha256: String(repeating: "0", count: 64)))
    #expect(try !GrammarModelStore.matches(output, bytes: expected.count + 1, sha256: hash))
    try Data([0]).write(to: source)
    await #expect(throws: GrammarInstallationError.invalidAsset) {
        try await GrammarModelStore.convert(source: source, destination: output, recipe: recipe)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_INSTALL_TEST_ROOT"] != nil))
func authorDownloadPreparesExactFP16WeightsAndWorksOffline() async throws {
    struct Fixture: Decodable { let input: String; let output: String }
    let path = try #require(ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_INSTALL_TEST_ROOT"])
    let root = URL(fileURLWithPath: path)
    if FileManager.default.fileExists(atPath: root.path) {
        try #require(FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
                     "Use an empty directory to exercise the actual download-to-correction transition.")
    }
    let store = GrammarModelStore(root: root)
    let corrector = GrammarCorrector(store: store)
    var fractions: [Double] = []
    await corrector.setEnabled(true, download: true)
    // Use the same enabled corrector before and after installation. Completion
    // must activate correction without restarting or toggling the preference.
    for await state in corrector.updates {
        if case let .downloading(value) = state {
            fractions.append(value)
            print("Grammar test download: \(Int(value * 100))%")
        }
        try #require(state != .unavailable)
        if state == .waiting, !fractions.isEmpty { break }
    }
    let installed = try await store.prepare(download: false)
    #expect(fractions.contains { $0 > 0 && $0 < 0.9 })
    #expect(try await store.prepare(download: false) == installed)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(installed.lastPathComponent + "-downloads").path))
    let url = try #require(Bundle.module.url(forResource: "coreml-fp16", withExtension: "json", subdirectory: "Grammar"))
    let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
    for fixture in fixtures {
        #expect(await corrector.correct(fixture.input, enabledForSession: true) == fixture.output, "Prepared output: \(fixture.input)")
    }
    #expect(await corrector.isLoaded)
    await corrector.setEnabled(false)
    #expect(await !corrector.isLoaded)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_APP"] != nil))
@MainActor
func packagedGrammarControlsAreVisibleAndOffByDefault() throws {
    let appPath = try #require(ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_APP"])
    let application = try #require(Bundle(url: URL(fileURLWithPath: appPath)))
    let available = GrammarCorrector.isAvailable(in: application)
    #expect(available)
    let terms = application.bundleURL.appendingPathComponent("Contents/Resources/Licenses/Grammar/TERMS.md")
    #expect(try String(contentsOf: terms, encoding: .utf8).contains("Only non-commercial purposes."))
    _ = NSApplication.shared
    let setup = OnboardingWindowController(grammarAvailable: available)
    #expect(!setup.setupGrammarCheckbox.isHiddenOrHasHiddenAncestor)
    #expect(setup.setupGrammarCheckbox.state == .off)
    let settings = SettingsWindowController(grammarAvailable: available)
    settings.selectPane(.dictation)
    #expect(!settings.grammarCheckbox.isHiddenOrHasHiddenAncestor)
    #expect(settings.grammarCheckbox.state == .off)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_APP"] != nil
               && ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_TEST_ASSETS"] != nil))
func packagedAppResourcesReuseTheVerifiedOfflineInstallation() async throws {
    let appPath = try #require(ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_APP"])
    let assetsPath = try #require(ProcessInfo.processInfo.environment["VOXKEY_GRAMMAR_TEST_ASSETS"])
    let application = try #require(Bundle(url: URL(fileURLWithPath: appPath)))
    #expect(GrammarCorrector.isAvailable(in: application))
    let resources = try #require(GrammarModelStore.preparationResources(in: application))
    #expect(resources.path.hasPrefix(application.bundleURL.path))
    let store = GrammarModelStore(root: URL(fileURLWithPath: assetsPath).deletingLastPathComponent(), resources: resources)
    let installed = try await store.prepare(download: false)
    let corrector = GrammarCorrector(assets: installed)
    await corrector.setEnabled(true)
    #expect(await corrector.correct("Okay, make sense, thanks.", enabledForSession: true) == "Okay, makes sense, thanks.")
    #expect(await corrector.correct("The build is not ready. Do not deploy it.", enabledForSession: true) == "The build is not ready. Do not deploy it.")
}
