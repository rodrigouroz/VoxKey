import Testing
@testable import VoxKeyCore

@Test func repeatedReadinessSnapshotIsPublishedOnlyOnce() {
    var deduplicator = SnapshotDeduplicator()
    let snapshot = SessionSnapshot(
        phase: .notReady(.microphonePermission),
        lastResult: nil,
        message: "Microphone access is required."
    )

    let first = deduplicator.accept(snapshot)
    let repeated = deduplicator.accept(snapshot)
    #expect(first)
    #expect(!repeated)
}

@Test func changedReadinessSnapshotIsPublished() {
    var deduplicator = SnapshotDeduplicator()
    let microphone = SessionSnapshot(
        phase: .notReady(.microphonePermission),
        lastResult: nil,
        message: "Microphone access is required."
    )
    let model = SessionSnapshot(
        phase: .notReady(.modelUnavailable),
        lastResult: nil,
        message: "Prepare the English transcription model."
    )

    let first = deduplicator.accept(microphone)
    let changed = deduplicator.accept(model)
    #expect(first)
    #expect(changed)
}
