import Foundation

/// Content-free evidence for diagnosing decoder repetition. This never changes
/// text: deliberate spoken repetition must remain intact.
enum TranscriptionRepetition {
    private static let maximumPhraseWords = 16

    static func adjacentWordCount(in text: String) -> Int {
        let words = words(in: text)
        let maximum = min(maximumPhraseWords, words.count / 2)
        guard maximum >= 3 else { return 0 }
        for length in stride(from: maximum, through: 3, by: -1) {
            for start in 0...(words.count - 2 * length) {
                if words[start..<(start + length)] == words[(start + length)..<(start + 2 * length)] {
                    return length
                }
            }
        }
        return 0
    }

    static func boundaryWordCount(previous: String, next: String) -> Int {
        let previous = words(in: previous).suffix(maximumPhraseWords)
        let next = words(in: next).prefix(maximumPhraseWords)
        let maximum = min(previous.count, next.count)
        guard maximum >= 3 else { return 0 }
        for length in stride(from: maximum, through: 3, by: -1) {
            if previous.suffix(length).elementsEqual(next.prefix(length)) { return length }
        }
        return 0
    }

    private static func words(in text: String) -> [Substring] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }
    }
}
