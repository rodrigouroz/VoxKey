import Foundation
import NaturalLanguage

/// Adjusts sentence-shaped transcription only when replacing one complete word.
enum SelectionReplacementMechanics {
    static func prepare(
        transcript: String, selectedText: String, precedingText: String, followingText: String
    ) -> String {
        let word = transcript.hasSuffix(".") ? String(transcript.dropLast()) : transcript
        guard isWord(selectedText), isWord(word),
              precedingText.last.map({ !$0.isLetter && !$0.isNumber }) ?? true,
              followingText.first.map({ !$0.isLetter && !$0.isNumber }) ?? true else { return transcript }
        // Short dotted tokens may be titles or abbreviations, such as Dr.
        guard !transcript.hasSuffix(".") || word.count > 2 else { return transcript }
        let canAdjustCase = selectedText.first?.isLowercase == true
            && word.first?.isUppercase == true && word.dropFirst().allSatisfy(\.isLowercase)
        guard transcript.hasSuffix(".") || canAdjustCase else { return transcript }

        // Keep name recognition small and local; no language assets are downloaded.
        // Unrecognized words inherit the selected word’s casing.
        let before = String(precedingText.suffix(128))
        let after = String(followingText.prefix(128))
        let tagger = NLTagger(tagSchemes: [.nameTypeOrLexicalClass])
        let replacementTag = tag(word, before: before, after: after, using: tagger)
        let namedWord = replacementTag.map(nameClasses.contains) == true
        // A correction can change grammatical class. The selected text supplies
        // casing; inferred part of speech must not veto that editing intent.

        var result = transcript
        // A whole-word selection does not include the sentence's punctuation.
        // Keep that punctuation outside the selection, and discard only a lone
        // model-added full stop. Questions, exclamations and abbreviations stay intact.
        if transcript.hasSuffix("."), !precedingText.isEmpty || !followingText.isEmpty {
            result = word
        }

        let previous = precedingText.last(where: { !$0.isWhitespace })
        let insideSentence = previous.map { !sentenceEndings.contains($0) } == true
            && !precedingText.reversed().prefix(while: { $0.isWhitespace }).contains(where: { $0.isNewline })
        if !namedWord, insideSentence, canAdjustCase {
            result.replaceSubrange(result.startIndex...result.startIndex, with: String(result.prefix(1)).lowercased())
        }
        return result
    }

    private static func isWord(_ text: String) -> Bool {
        // Longer text, contractions, symbols and identifiers need richer intent
        // than this word-replacement rule can establish.
        (2...64).contains(text.count) && text.allSatisfy(\.isLetter)
    }

    private static func tag(_ word: String, before: String, after: String, using tagger: NLTagger) -> NLTag? {
        let text = before + word + after
        tagger.string = text
        // Let the local tagger infer language from the bounded editing context.
        let index = text.index(text.startIndex, offsetBy: before.count)
        return tagger.tag(at: index, unit: .word, scheme: .nameTypeOrLexicalClass).0
    }

    private static let nameClasses: Set<NLTag> = [.personalName, .placeName, .organizationName]
    private static let sentenceEndings: Set<Character> = [".", "!", "?", "…"]
}
