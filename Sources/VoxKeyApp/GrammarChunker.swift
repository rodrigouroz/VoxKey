import Foundation
import NaturalLanguage

/// Ranges refer to the original transcript. Everything between ranges is copied
/// verbatim, including paragraph separators and words too large for the model.
enum GrammarChunker {
    static func ranges(in text: String, tokenizer: GectorTokenizer,
                       preserveShortContext: Bool = true) throws -> [Range<String.Index>] {
        // Preserve the qualified single-call behavior for short transcripts.
        if preserveShortContext, text.utf8.count <= 2_000, hasSupportedSpacing(text),
           (try? GrammarCorrector.tokenize(["$START"] + text.components(separatedBy: " "), with: tokenizer)) != nil {
            return [text.startIndex..<text.endIndex]
        }

        let sentences = NLTokenizer(unit: .sentence)
        sentences.setLanguage(.english)
        sentences.string = text
        let wordBudget = GrammarCorrector.tokenLimit - 3 // BOS, $START, EOS
        var result: [Range<String.Index>] = []
        for sentence in sentences.tokens(for: text.startIndex..<text.endIndex) {
            var pending: Range<String.Index>?
            var count = 0
            func flush() {
                if let pending { result.append(pending) }
                pending = nil
                count = 0
            }
            for word in text[sentence].split(whereSeparator: { $0.isWhitespace }) {
                try Task.checkCancellation()
                if let pending, text[pending.upperBound..<word.startIndex].contains(where: { $0.isNewline }) {
                    flush()
                }
                // Avoid quadratic BPE work on a pathological unbroken word.
                guard word.utf8.count <= 2_000 else { flush(); continue }
                let tokens = try tokenizer.encode(word: String(word)).count
                guard tokens > 0, tokens <= wordBudget else { flush(); continue }
                if count + tokens > wordBudget { flush() }
                pending = (pending?.lowerBound ?? word.startIndex)..<word.endIndex
                count += tokens
            }
            flush()
        }
        return result
    }

    static func hasSupportedSpacing(_ text: String) -> Bool {
        !text.contains(where: { $0.isWhitespace && $0 != " " })
            && !text.contains("  ") && !text.hasPrefix(" ") && !text.hasSuffix(" ")
    }
}
