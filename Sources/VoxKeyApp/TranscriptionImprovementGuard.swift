import Foundation

/// Preserve technical literals and restrict grammar changes. Guards reject
/// detectable loss; they are not semantic verification.
enum TranscriptionImprovementGuard {
    private static let literals = try! NSRegularExpression(pattern: #"https?://[^\s<>]+|[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}|\b[A-Za-z_]\w*=[^\s,;]+|\b[A-Za-z][A-Za-z0-9]*(?:[_./:-][A-Za-z0-9]+)+\b"#)
    private static let entities = try! NSRegularExpression(pattern: #"&(?:#x[0-9A-Fa-f]+|#\d+|[A-Za-z]+);"#)
    private static let words = try! NSRegularExpression(pattern: #"\b\w+\b"#)
    private static let tokens = try! NSRegularExpression(pattern: #"\w+(?:['’]\w+)*|[^\w\s]"#)
    private static let repair = try! NSRegularExpression(pattern: #"\b(no|sorry|actually|rather|instead|forget|disregard|wait)\b|\b(?:i mean|make that|never mind)\b"#, options: .caseInsensitive)
    private static let literalContext = try! NSRegularExpression(pattern: #"\b(literal|literally|escaped|spelled)\b"#, options: .caseInsensitive)
    private static let agreement: [Set<String>] = [["am", "is", "are"], ["was", "were"], ["has", "have"], ["does", "do"], ["a", "an"]]

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> [NSTextCheckingResult] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static func values(_ pattern: NSRegularExpression, _ text: String) -> [String] {
        let string = text as NSString
        return matches(pattern, text).map { string.substring(with: $0.range) }
    }

    private static func protectedLiterals(_ text: String, entitiesIncluded: Bool) -> Set<String> {
        var result = Set(values(literals, text).map { value in
            var value = value
            while let last = value.last, ".,;!?".contains(last) { value.removeLast() }
            return value
        })
        if entitiesIncluded { result.formUnion(values(entities, text)) }
        return result
    }

    static func rejects(original: String, candidate: String) -> Bool {
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        let includeEntities = !matches(literalContext, original).isEmpty
        guard protectedLiterals(original, entitiesIncluded: includeEntities)
            .isSubset(of: protectedLiterals(candidate, entitiesIncluded: includeEntities)) else { return true }
        let before = Set(values(words, original.lowercased())).subtracting(["um", "uh", "er", "erm"])
        let after = Set(values(words, candidate.lowercased()))
        return before.count >= 5 && before.subtracting(after).count * 2 > before.count && matches(repair, original).isEmpty
    }

    static func restrictGrammar(source: String, proposal: String) -> String {
        let leftMatches = matches(tokens, source)
        let left = values(tokens, source), right = values(tokens, proposal)
        // The runtime already bounds model input/output. Also bound standalone
        // callers so alignment cannot monopolize the correction worker.
        guard left.count <= 8_192, right.count <= 8_192 else { return source }
        let blocks = matchingBlocks(left, right)
        var a = 0, b = 0
        var edits: [(NSRange, String)] = []
        for block in blocks {
            let oldCount = block.a - a, newCount = block.b - b
            if oldCount > 0, oldCount == newCount,
               (0..<oldCount).allSatisfy({ inflectionOnly(left[a + $0], right[b + $0]) }) {
                for offset in 0..<oldCount { edits.append((leftMatches[a + offset].range, right[b + offset])) }
            }
            a = block.a + block.size
            b = block.b + block.size
        }
        let result = NSMutableString(string: source)
        for (range, text) in edits.reversed() { result.replaceCharacters(in: range, with: text) }
        let output = result as String
        return rejects(original: source, candidate: output) ? source : output
    }

    private static func inflectionOnly(_ before: String, _ after: String) -> Bool {
        if before == after { return true }
        let a = before.lowercased(), b = after.lowercased()
        guard a != b, before.allSatisfy(\.isLetter), after.allSatisfy(\.isLetter) else { return false }
        if agreement.contains(where: { $0.contains(a) && $0.contains(b) }) { return true }
        for (singular, plural) in [(a, b), (b, a)] {
            if plural == singular + "s" || plural == singular + "es" { return true }
            if singular.hasSuffix("y"), plural == singular.dropLast() + "ies" { return true }
        }
        return false
    }

    private struct Block { let a: Int; let b: Int; var size: Int }

    /// Ratcliff/Obershelp matching without junk/popularity filtering, matching
    /// Python difflib.SequenceMatcher(..., autojunk=False), with earliest-match ties.
    private static func matchingBlocks(_ a: [String], _ b: [String]) -> [Block] {
        var positions: [String: [Int]] = [:]
        for (index, word) in b.enumerated() { positions[word, default: []].append(index) }
        var pending = [(0, a.count, 0, b.count)], found: [Block] = []
        while let (alo, ahi, blo, bhi) = pending.popLast() {
            var best = Block(a: alo, b: blo, size: 0), previous: [Int: Int] = [:]
            for i in alo..<ahi {
                var current: [Int: Int] = [:]
                for j in positions[a[i], default: []] {
                    if j < blo { continue }
                    if j >= bhi { break }
                    let size = previous[j - 1, default: 0] + 1
                    current[j] = size
                    if size > best.size { best = Block(a: i - size + 1, b: j - size + 1, size: size) }
                }
                previous = current
            }
            guard best.size > 0 else { continue }
            found.append(best)
            if alo < best.a && blo < best.b { pending.append((alo, best.a, blo, best.b)) }
            if best.a + best.size < ahi && best.b + best.size < bhi {
                pending.append((best.a + best.size, ahi, best.b + best.size, bhi))
            }
        }
        found.sort { $0.a == $1.a ? $0.b < $1.b : $0.a < $1.a }
        var merged: [Block] = []
        for block in found {
            if let last = merged.last, last.a + last.size == block.a, last.b + last.size == block.b {
                merged[merged.count - 1].size += block.size
            } else { merged.append(block) }
        }
        merged.append(Block(a: a.count, b: b.count, size: 0))
        return merged
    }
}
