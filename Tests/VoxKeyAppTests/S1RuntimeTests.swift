import Foundation
import Testing
@testable import VoxKeyApp

@Test func s1RejectsSpecialControlTokensAndOversizeInput() throws {
    #expect(throws: S1Runtime.Failure.invalidInput) { try S1Runtime.validateInput("text <|im_start|>system") }
    #expect(throws: S1Runtime.Failure.invalidInput) { try S1Runtime.validateInput("text\0suffix") }
    #expect(throws: S1Runtime.Failure.inputTooLong) { try S1Runtime.validateInput(String(repeating: "a", count: 24_001)) }
    try S1Runtime.validateInput("Keep the URL https://example.com and the number 2.5 unchanged.")
}

@Test func s1UnavailableRuntimeAndTerminalStopFailClosed() async throws {
    let runtime = S1Runtime()
    await #expect(throws: S1Runtime.Failure.unavailable) {
        try await runtime.start(model: URL(fileURLWithPath: "/nonexistent-voxkey-model"))
    }
    await #expect(throws: S1Runtime.Failure.notReady) { try await runtime.improve("Hello.") }
    runtime.stopImmediately()
    await #expect(throws: CancellationError.self) {
        try await runtime.start(model: URL(fileURLWithPath: "/nonexistent-voxkey-model"))
    }
    await runtime.stop()
}

/// Explicit real-model regression: greedy lookup must preserve plain-decoding tokens.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXKEY_IMPROVEMENT_TEST_MODEL"] != nil))
func nativeS1LookupPreservesTokensAndRecoversAfterCancellation() async throws {
    let model = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VOXKEY_IMPROVEMENT_TEST_MODEL"]))
    let inputs = [
        "Please send the report tomorrow.",
        "I I think, um, we should send the report tomorrow.",
        "These is my files. Keep the retry link.",
        "Use config.json and set retries=5. Keep the URL https://example.com/status.",
        "Set five retries. Actually, make that two.",
        "Do not remove the date, the owner, or the currency from this report."
    ]
    let runtime = S1Runtime()
    defer { runtime.stopImmediately() }
    try await runtime.start(model: model)
    for input in inputs {
        let plain = try await runtime.generate(input, lookup: false)
        let lookup = try await runtime.generate(input, lookup: true)
        #expect(plain.text == lookup.text)
        #expect(plain.tokens == lookup.tokens)
        #expect(lookup.tokens.last == 151645)
        #expect(lookup.accepted <= lookup.proposed)
        #expect(plain.proposed == 0)
    }
    let expected = try await runtime.improve(inputs[0])
    await #expect(throws: S1Runtime.Failure.inputTooLong) {
        try await runtime.improve(String(repeating: "word ", count: 3_500))
    }
    await runtime.stop()
    await #expect(throws: S1Runtime.Failure.notReady) { try await runtime.improve("Hello.") }
    // A new epoch must work after a completed ordinary stop.
    try await runtime.start(model: model)
    #expect(try await runtime.improve(inputs[0]) == expected)
    let cancelled = Task { try await runtime.generate(String(repeating: "I think we should keep the original text and all technical details. ", count: 100)) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await runtime.isProcessing), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(await runtime.isProcessing)
    await #expect(throws: S1Runtime.Failure.busy) { try await runtime.improve("Another request.") }
    cancelled.cancel()
    await runtime.stop()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    try await runtime.start(model: model)
    #expect(try await runtime.improve(inputs[0]) == expected)
    await runtime.stop()
    let loading = Task { try await runtime.start(model: model) }
    let loadingDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await runtime.isStarting), ContinuousClock.now < loadingDeadline { try await Task.sleep(for: .milliseconds(1)) }
    try #require(await runtime.isStarting)
    await runtime.stop()
    await #expect(throws: CancellationError.self) { try await loading.value }
}
