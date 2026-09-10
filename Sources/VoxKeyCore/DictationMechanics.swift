import Foundation

public enum DictationMechanics {
    public static func prepare(
        transcript: String,
        precedingText: String,
        followingText: String,
        replacesSelection: Bool,
        selectedText: String? = nil
    ) -> String {
        var result = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        if replacesSelection, let selectedText {
            result = SelectionReplacementMechanics.prepare(
                transcript: result, selectedText: selectedText,
                precedingText: precedingText, followingText: followingText
            )
        }

        if shouldCapitalize(after: precedingText, replacingSelection: replacesSelection) {
            result = capitalizeFirstLetter(in: result)
        }

        if needsLeadingSpace(before: result, precedingText: precedingText, replacingSelection: replacesSelection) {
            result.insert(" ", at: result.startIndex)
        }

        if needsTrailingSpace(after: result, followingText: followingText, replacingSelection: replacesSelection) {
            result.append(" ")
        }

        return result
    }

    private static func shouldCapitalize(after text: String, replacingSelection: Bool) -> Bool {
        if replacingSelection { return false }
        guard let last = text.last else { return true }
        return last == "." || last == "!" || last == "?" || last == "\n"
    }

    private static func needsLeadingSpace(
        before transcript: String,
        precedingText: String,
        replacingSelection: Bool
    ) -> Bool {
        guard !replacingSelection, let preceding = precedingText.last, let first = transcript.first else { return false }
        if preceding.isWhitespace || openingPunctuation.contains(preceding) { return false }
        if closingPunctuation.contains(first) { return false }
        return true
    }

    private static func needsTrailingSpace(
        after transcript: String,
        followingText: String,
        replacingSelection: Bool
    ) -> Bool {
        guard !replacingSelection, let following = followingText.first, let last = transcript.last else { return false }
        if following.isWhitespace || closingPunctuation.contains(following) { return false }
        if last.isWhitespace || openingPunctuation.contains(last) { return false }
        return true
    }

    private static func capitalizeFirstLetter(in text: String) -> String {
        guard let index = text.firstIndex(where: { $0.isLetter }) else { return text }
        var result = text
        result.replaceSubrange(index...index, with: String(result[index]).uppercased())
        return result
    }

    private static let openingPunctuation: Set<Character> = ["(", "[", "{", "\"", "“", "‘", "¿", "¡"]
    private static let closingPunctuation: Set<Character> = [".", ",", "!", "?", ":", ";", ")", "]", "}", "\"", "”", "’"]
}
