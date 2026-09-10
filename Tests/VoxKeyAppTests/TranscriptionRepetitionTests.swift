import Testing
@testable import VoxKeyApp

@Test func repetitionDiagnosticsRecognizeTheReportedPhrase() {
    let text = "We are downloading that and once that downloaded that and once that downloaded, we start using it."
    #expect(TranscriptionRepetition.adjacentWordCount(in: text) == 5)
    #expect(TranscriptionRepetition.boundaryWordCount(
        previous: "We are downloading that and once that downloaded",
        next: "that and once that downloaded, we start using it.") == 5)
}

@Test func repetitionDiagnosticsIgnoreCaseAndPunctuationAtPhraseBoundaries() {
    #expect(TranscriptionRepetition.adjacentWordCount(in: "Send the notes. Send the notes!") == 3)
    #expect(TranscriptionRepetition.boundaryWordCount(previous: "Send the notes.", next: "send the notes!") == 3)
}

@Test func repetitionDiagnosticsDoNotTreatOrdinaryWordReuseAsAPhraseRepeat() {
    for text in ["", "Very very useful.", "We need the model, and once the model downloads, use it."] {
        #expect(TranscriptionRepetition.adjacentWordCount(in: text) == 0)
    }
    #expect(TranscriptionRepetition.boundaryWordCount(previous: "We are downloading that.", next: "And once that downloaded, use it.") == 0)
}

@Test func repetitionDiagnosticsAlsoFlagDeliberateRepeatsSoCountsAreNotProofOfAnError() {
    #expect(TranscriptionRepetition.adjacentWordCount(in: "Go to the door. Go to the door.") == 4)
}
