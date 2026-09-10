import Testing
@testable import VoxKeyCore

@Test func capitalizesAtBeginning() {
    #expect(DictationMechanics.prepare(
        transcript: "hello world",
        precedingText: "",
        followingText: "",
        replacesSelection: false
    ) == "Hello world")
}

@Test func insertsBoundarySpacesInsideText() {
    #expect(DictationMechanics.prepare(
        transcript: "brave new",
        precedingText: "hello",
        followingText: "world",
        replacesSelection: false
    ) == " brave new ")
}

@Test func selectionReplacementDoesNotInventSpacesOrCapitalization() {
    #expect(DictationMechanics.prepare(
        transcript: "replacement",
        precedingText: "before ",
        followingText: " after",
        replacesSelection: true
    ) == "replacement")
}

@Test func avoidsSpaceBeforePunctuation() {
    #expect(DictationMechanics.prepare(
        transcript: "hello",
        precedingText: "",
        followingText: ", world",
        replacesSelection: false
    ) == "Hello")
}

@Test(arguments: [
    ("Build.", "filled", "Okay, let’s check. This is the first dictation after this new ", ".", "build"),
    ("Build", "filled", "This is the first dictation after this new ", ".", "build"),
    ("Second.", "first", "This is my ", " test", "second"),
    ("Second", "first", "This is my ", " test", "second"),
    ("Red.", "brown", "The quick ", " fox", "red"),
    ("Second.", "First", "", " test", "Second"),
    // A correction can change grammatical class; selection casing still applies.
    ("Second.", "first", "This is the ", "", "second"),
    ("Second.", "first", "This is the ", ". Next sentence.", "second"),
    ("Second.", "first", "Earlier. ", " test", "Second"),
    ("Second.", "first", "Earlier\n", " test", "Second"),
    ("Sarah.", "someone", "Talk to ", " today", "Sarah"),
    ("Paris.", "town", "We visited ", " yesterday", "Paris"),
    ("NASA.", "someone", "Talk to ", " today", "NASA"),
    // Unrecognized title-case names are indistinguishable from sentence casing.
    // The selected lowercase style wins; mixed-case and recognized names remain intact.
    ("Rod", "someone", "Talk to ", " today", "rod"),
    ("Swift", "something", "We use ", " daily", "swift"),
    ("VoxKey", "something", "We use ", " daily", "VoxKey"),
    ("I", "we", "They said ", " can go", "I"),
    ("Dr.", "someone", "Talk to ", " Smith", "Dr."),
    ("U.S.", "town", "We visited ", " yesterday", "U.S."),
    ("Second!", "first", "This is my ", " test", "Second!"),
    ("Second?", "first", "This is my ", " test", "Second?"),
    ("A complete sentence.", "first", "This is my ", " test", "A complete sentence."),
    ("Second.", "first test", "This is my ", "", "Second."),
    ("Second.", "irs", "This is my f", "t test", "Second."),
    ("Second.", "First", "", "", "Second.")
])
func wordReplacementUsesOnlyUnambiguousSentenceContext(
    _ transcript: String, _ selected: String, _ before: String, _ after: String, _ expected: String
) {
    #expect(DictationMechanics.prepare(
        transcript: transcript, precedingText: before, followingText: after,
        replacesSelection: true, selectedText: selected
    ) == expected)
}

@Test func missingSelectionContentDoesNotGuessItsStyle() {
    #expect(DictationMechanics.prepare(
        transcript: "Second.", precedingText: "This is my ", followingText: " test", replacesSelection: true
    ) == "Second.")
}
