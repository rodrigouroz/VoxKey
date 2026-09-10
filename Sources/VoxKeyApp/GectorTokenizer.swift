import Foundation

/// The pinned RoBERTa checkpoint uses byte-level BPE, with a prefix space once
/// per word. Keeping this tokenizer separate avoids changing Whisper's tokenizer.
struct GectorTokenizer {
    private struct Specification: Decodable {
        struct Model: Decodable { let vocab: [String: Int]; let merges: [String] }
        let model: Model
    }

    private let vocabulary: [String: Int]
    private let ranks: [String: Int]
    private let pattern: NSRegularExpression
    private let bytes: [String]

    init(contentsOf url: URL) throws {
        let specification = try JSONDecoder().decode(Specification.self, from: Data(contentsOf: url))
        vocabulary = specification.model.vocab
        ranks = Dictionary(specification.model.merges.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        pattern = try NSRegularExpression(pattern: "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+")
        let visible = Array(33...126) + Array(161...172) + Array(174...255)
        var mapping = [String](repeating: "", count: 256)
        for value in visible { mapping[value] = String(UnicodeScalar(value)!) }
        var extra = 256
        for value in 0..<256 where mapping[value].isEmpty {
            mapping[value] = String(UnicodeScalar(extra)!)
            extra += 1
        }
        bytes = mapping
    }

    func encode(word: String) throws -> [Int] {
        if word == "$START" { return [50265] }
        let text = " " + word
        let string = text as NSString
        return try pattern.matches(in: text, range: NSRange(location: 0, length: string.length)).flatMap { match in
            var pieces = string.substring(with: match.range).utf8.map { bytes[Int($0)] }
            while pieces.count > 1 {
                let candidates = (0..<(pieces.count - 1)).compactMap { index -> (Int, Int)? in
                    ranks[pieces[index] + " " + pieces[index + 1]].map { (index, $0) }
                }
                guard let pair = candidates.min(by: { $0.1 < $1.1 }) else { break }
                let left = pieces[pair.0], right = pieces[pair.0 + 1]
                var merged: [String] = []
                var index = 0
                while index < pieces.count {
                    if index + 1 < pieces.count, pieces[index] == left, pieces[index + 1] == right {
                        merged.append(left + right)
                        index += 2
                    } else {
                        merged.append(pieces[index])
                        index += 1
                    }
                }
                pieces = merged
            }
            return try pieces.map {
                guard let token = vocabulary[$0] else { throw GrammarCorrectionError.invalidAssets }
                return token
            }
        }
    }
}
