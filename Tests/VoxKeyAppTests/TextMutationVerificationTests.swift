import Foundation
import Testing
@testable import VoxKeyApp

@Test
func matchingCaretCannotConfirmContradictoryText() {
    let original = TextMutationSnapshot(range: CFRange(location: 0, length: 0), preceding: "", following: "")
    let current = TextMutationSnapshot(range: CFRange(location: 5, length: 0), preceding: "World", following: "")
    #expect(TextMutationVerification.evaluate(
        original: original, current: current, insertedText: "Hello", contextLimit: 256
    ) == .ambiguous)
}

@Test
func matchingCaretCannotHideChangedFollowingText() {
    let original = TextMutationSnapshot(range: CFRange(location: 0, length: 0), preceding: "", following: " remainder")
    let current = TextMutationSnapshot(range: CFRange(location: 5, length: 0), preceding: "Hello", following: " damaged")
    #expect(TextMutationVerification.evaluate(
        original: original, current: current, insertedText: "Hello", contextLimit: 256
    ) == .ambiguous)
}

@Test
func unchangedEditorIsNotAcceptedAsDelivered() {
    let original = TextMutationSnapshot(
        range: CFRange(location: 4, length: 0),
        preceding: "Text",
        following: ""
    )

    #expect(TextMutationVerification.evaluate(
        original: original,
        current: original,
        insertedText: " added",
        contextLimit: 256
    ) == .unchanged)
}

@Test
func expectedCaretAndContextMutationConfirmsDelivery() {
    let original = TextMutationSnapshot(
        range: CFRange(location: 4, length: 0),
        preceding: "Text",
        following: " remains"
    )
    let current = TextMutationSnapshot(
        range: CFRange(location: 10, length: 0),
        preceding: "Text added",
        following: " remains"
    )

    #expect(TextMutationVerification.evaluate(
        original: original,
        current: current,
        insertedText: " added",
        contextLimit: 256
    ) == .confirmed)
}

@Test
func unexpectedEditorMutationIsAmbiguous() {
    let original = TextMutationSnapshot(
        range: CFRange(location: 4, length: 0),
        preceding: "Text",
        following: ""
    )
    let current = TextMutationSnapshot(
        range: CFRange(location: 5, length: 0),
        preceding: "Text?",
        following: ""
    )

    #expect(TextMutationVerification.evaluate(
        original: original,
        current: current,
        insertedText: " added",
        contextLimit: 256
    ) == .ambiguous)
}

@Test
func expectedCaretMovementIsUncertainWhenContextIsUnavailable() {
    let original = TextMutationSnapshot(
        range: CFRange(location: 0, length: 0),
        preceding: nil,
        following: nil
    )
    let current = TextMutationSnapshot(
        range: CFRange(location: 5, length: 0),
        preceding: nil,
        following: nil
    )

    #expect(TextMutationVerification.evaluate(
        original: original,
        current: current,
        insertedText: "Hello",
        contextLimit: 256
    ) == .ambiguous)
}

@Test
func expectedContextConfirmsDeliveryWhenCaretIsStale() {
    let original = TextMutationSnapshot(
        range: CFRange(location: 0, length: 0),
        preceding: "",
        following: ""
    )
    let current = TextMutationSnapshot(
        range: CFRange(location: 0, length: 0),
        preceding: "Hello",
        following: ""
    )

    #expect(TextMutationVerification.evaluate(
        original: original,
        current: current,
        insertedText: "Hello",
        contextLimit: 256
    ) == .confirmed)
}
