import AppKit
import Testing
@testable import VoxKeyApp
import VoxKeyCore

@MainActor
@Test(arguments: [false, true])
func completedPhrasesPublishOnlyForTheActiveDictation(_ finalizing: Bool) async {
    let id = DictationSessionID()
    let coordinator = SessionCoordinator(accessibility: DesktopFixture().service,
        initialState: .init(phase: finalizing ? .finalizing(id) : .capturing(id)))
    await coordinator.receiveTranscriptionProgress(progress("A completed phrase."), sessionID: id)
    #expect(await coordinator.currentSnapshot().transcriptPreview == "A completed phrase.")
    await coordinator.receiveTranscriptionProgress(progress("An old recording."), sessionID: DictationSessionID())
    #expect(await coordinator.currentSnapshot().transcriptPreview == "A completed phrase.")
    await coordinator.receiveTranscriptionProgress(progress("A completed phrase. Another sentence."), sessionID: id)
    #expect(await coordinator.currentSnapshot().transcriptPreview == "A completed phrase. Another sentence.")
    #expect(await coordinator.lastResult() == nil)
    await coordinator.prepareForTermination()
    #expect(await coordinator.currentSnapshot().transcriptPreview == nil)
    await coordinator.receiveTranscriptionProgress(progress("Late callback."), sessionID: id)
    #expect(await coordinator.currentSnapshot().transcriptPreview == nil)
}

@MainActor @Test
func cancellationDiscardsCaptionsAndRejectsLateProgress() async {
    let id = DictationSessionID()
    let coordinator = SessionCoordinator(accessibility: DesktopFixture().service,
        initialState: .init(phase: .capturing(id)))
    await coordinator.receiveTranscriptionProgress(progress("A private phrase."), sessionID: id)
    await coordinator.cancel(expectedSessionID: id)
    #expect(await coordinator.currentSnapshot().phase == .ready)
    #expect(await coordinator.currentSnapshot().transcriptPreview == nil)
    await coordinator.receiveTranscriptionProgress(progress("A late phrase."), sessionID: id)
    #expect(await coordinator.currentSnapshot().transcriptPreview == nil)
    #expect(await coordinator.lastResult() == nil)
}

@MainActor @Test
func longCaptionSnapshotsAreBoundedWithoutSplittingCharacters() async {
    let id = DictationSessionID()
    let coordinator = SessionCoordinator(accessibility: DesktopFixture().service,
        initialState: .init(phase: .capturing(id)))
    let text = String(repeating: "Un café 👨‍👩‍👧‍👦. ", count: 300) + "Última frase."
    await coordinator.receiveTranscriptionProgress(progress(text), sessionID: id)
    let preview = await coordinator.currentSnapshot().transcriptPreview
    #expect(preview == String(text.suffix(1_200)).trimmingCharacters(in: .whitespacesAndNewlines))
    #expect(preview?.hasSuffix("Última frase.") == true)
    await coordinator.cancel()
}

@MainActor
@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
func liveCaptionsShowTheLatestThreeLinesThroughInsertion(_ appearance: NSAppearance.Name) throws {
    _ = NSApplication.shared
    let overlay = StatusOverlayController(animationsEnabled: false)
    let id = DictationSessionID()
    let window = try #require(overlay.window)
    window.appearance = NSAppearance(named: appearance)
    defer { window.orderOut(nil) }
    let first = "Let's make a little room for good ideas."
    overlay.update(.init(phase: .capturing(id), lastResult: nil, inputLevel: 0.7, transcriptPreview: first))
    let root = try #require(window.contentView)
    root.layoutSubtreeIfNeeded()
    let preview = try #require(root.captionDescendants.compactMap { $0 as? TranscriptPreviewView }.first)
    let text = try #require(preview.captionDescendants.compactMap { $0 as? NSTextView }.first)
    #expect(text.string == first)
    #expect(!text.isEditable && !text.isSelectable)
    #expect(window.frame.width == 360)
    #expect(root.bounds.contains(root.convert(preview.bounds, from: preview)))
    try saveCaptionPreview(root, name: "caption-short-\(appearance.rawValue)")

    let longer = first + " We can collect our thoughts as we speak, take a breath, and watch the next sentence appear. Everything stays on this Mac. Ahora seguimos en español."
    overlay.update(.init(phase: .capturing(id), lastResult: nil, inputLevel: 0.8, transcriptPreview: longer))
    root.layoutSubtreeIfNeeded()
    let clip = try #require(preview.captionDescendants.compactMap { $0 as? NSClipView }.first)
    #expect(text.string == longer)
    #expect(clip.bounds.height == 63)
    #expect(clip.bounds.minY > 0)
    #expect(abs(clip.bounds.maxY - text.frame.maxY) < 1)
    #expect(root.bounds.contains(root.convert(preview.bounds, from: preview)))
    #expect(window.styleMask.contains(.nonactivatingPanel))
    #expect(window.ignoresMouseEvents)
    try saveCaptionPreview(root, name: "caption-long-\(appearance.rawValue)")

    overlay.update(.init(phase: .finalizing(id), lastResult: nil, message: "Improving transcription…", transcriptPreview: longer))
    #expect(window.isVisible)
    #expect(text.string == longer)
    #expect(root.captionDescendants.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Improving transcription…" })
    try saveCaptionPreview(root, name: "caption-finalizing-\(appearance.rawValue)")
    overlay.update(.init(phase: .delivering(id), lastResult: LastResult(text: longer), transcriptPreview: longer))
    #expect(window.isVisible)
    #expect(text.string == longer)
    overlay.update(.init(phase: .ready, lastResult: nil, message: "Delivered"))
    #expect(!window.isVisible)
    #expect(text.string.isEmpty)
    #expect(preview.superview == nil)
    overlay.update(.init(phase: .capturing(DictationSessionID()), lastResult: nil))
    #expect(window.frame.size == NSSize(width: 212, height: 46))
    #expect(preview.superview == nil)
}

private func progress(_ text: String) -> StreamingTranscriptionProgress {
    .init(decodeCount: 1, confirmedAudioSeconds: 3, bufferedAudioSeconds: 0.1, confirmedText: text)
}

@MainActor @Test
func animatedCaptionExpansionKeepsTextBelowTheStatus() async throws {
    let overlay = StatusOverlayController()
    let id = DictationSessionID()
    let window = try #require(overlay.window)
    defer { window.orderOut(nil) }
    overlay.update(.init(phase: .capturing(id), lastResult: nil))
    overlay.update(.init(phase: .capturing(id), lastResult: nil,
                         transcriptPreview: "A short first phrase."))
    try await Task.sleep(for: .milliseconds(300))
    overlay.update(.init(phase: .capturing(id), lastResult: nil,
                         transcriptPreview: "A short first phrase. Now we continue with a few more ideas, watching the caption grow while the listening indicator stays in place. The last sentence stays visible."))
    try await Task.sleep(for: .milliseconds(80))
    let root = try #require(window.contentView)
    root.layoutSubtreeIfNeeded()
    let preview = try #require(root.captionDescendants.compactMap { $0 as? TranscriptPreviewView }.first)
    let status = try #require(root.captionDescendants.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Listening" })
    let statusFrame = root.convert(status.bounds, from: status)
    #expect(preview.frame.maxY <= statusFrame.minY)
    try saveCaptionPreview(root, name: "caption-expanding")
    try await Task.sleep(for: .milliseconds(300))
    #expect(window.frame.size == NSSize(width: 360, height: 125))
    overlay.update(.init(phase: .ready, lastResult: nil))
    overlay.update(.init(phase: .capturing(DictationSessionID()), lastResult: nil))
    try await Task.sleep(for: .milliseconds(300))
    #expect(window.frame.size == NSSize(width: 212, height: 46))
    #expect(preview.superview == nil)
}

@MainActor
private func saveCaptionPreview(_ root: NSView, name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["VOXKEY_SETTINGS_PREVIEW_DIR"] else { return }
    root.layoutSubtreeIfNeeded()
    let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
    root.cacheDisplay(in: root.bounds, to: bitmap)
    try #require(bitmap.representation(using: .png, properties: [:])).write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
}

private extension NSView {
    var captionDescendants: [NSView] { [self] + subviews.flatMap(\.captionDescendants) }
}
