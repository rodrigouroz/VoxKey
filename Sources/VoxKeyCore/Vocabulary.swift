import CryptoKit
import Foundation

public enum VocabularyError: Error, LocalizedError {
    case invalidPackage
    case invalidArchive
    case unsupportedFormat
    case unsupportedLanguage
    case integrityMismatch
    case invalidTerms
    case limitExceeded
    case unreadableStorage

    public var errorDescription: String? {
        switch self {
        case .invalidPackage: "Choose a vocabulary ZIP, package folder, or manifest.json file."
        case .invalidArchive: "Choose a ZIP containing one vocabulary package, with manifest.json and terms.json together at the root or inside one folder. The archive must be readable, unencrypted, and contain no links or unsafe paths."
        case .unsupportedFormat: "This vocabulary package uses an unsupported format."
        case .unsupportedLanguage: "This version of VoxKey supports English vocabulary only."
        case .integrityMismatch: "The vocabulary contents do not match the package checksum. Import a fresh copy."
        case .invalidTerms: "Use one term per line, up to 80 characters each. Terms cannot contain control characters or model tokens."
        case .limitExceeded: "Vocabulary limit reached: 200 personal terms, 500 terms per package, and 20 packages."
        case .unreadableStorage: "Saved vocabulary could not be loaded. Your saved file has not been changed."
        }
    }
}

public struct VocabularyTerm: Codable, Equatable, Sendable {
    public let canonical: String
    public let category: String?
    public let priority: Int
    public let spokenForms: [String]?

    public init(canonical: String, category: String? = nil, priority: Int = 100, spokenForms: [String]? = nil) {
        self.canonical = canonical
        self.category = category
        self.priority = priority
        self.spokenForms = spokenForms
    }

    public var recognitionHint: String {
        guard let spokenForms, !spokenForms.isEmpty else { return canonical }
        return "\(canonical) (\(spokenForms.joined(separator: ", ")))"
    }
}

public struct VocabularyManifest: Codable, Equatable, Sendable {
    public struct Content: Codable, Equatable, Sendable {
        public let path: String
        public let sha256: String
    }
    public let schemaVersion: Int
    public let identifier: String
    public let displayName: String
    public let version: String
    public let classification: String
    public let locales: [String]
    public let content: Content
}

public struct VocabularyPackage: Equatable, Sendable {
    public let manifest: VocabularyManifest
    public let terms: [VocabularyTerm]
    public let manifestData: Data
    public let termsData: Data

    public init(manifestData: Data, termsData: Data) throws {
        guard manifestData.count <= 65_536, termsData.count <= 524_288 else { throw VocabularyError.limitExceeded }
        let manifest: VocabularyManifest
        let content: TermFile
        do {
            manifest = try JSONDecoder().decode(VocabularyManifest.self, from: manifestData)
            content = try JSONDecoder().decode(TermFile.self, from: termsData)
        } catch { throw VocabularyError.invalidPackage }
        guard manifest.schemaVersion == 1, content.schemaVersion == 1 else { throw VocabularyError.unsupportedFormat }
        guard manifest.locales == ["en"], content.locale == "en" else { throw VocabularyError.unsupportedLanguage }
        guard manifest.content.path == "terms.json",
              !manifest.identifier.isEmpty, manifest.identifier.count <= 160,
              manifest.identifier.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_").contains($0) }),
              VocabularyRules.isValidTerm(manifest.displayName),
              VocabularyRules.isValidTerm(manifest.version),
              VocabularyRules.isValidTerm(manifest.classification) else { throw VocabularyError.invalidPackage }
        let digest = SHA256.hash(data: termsData).map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.content.sha256.lowercased() else { throw VocabularyError.integrityMismatch }
        guard !content.terms.isEmpty, content.terms.count <= 500 else { throw VocabularyError.limitExceeded }
        var seen: Set<String> = []
        for term in content.terms {
            guard VocabularyRules.isValidTerm(term.canonical), (0...100).contains(term.priority),
                  term.category.map(VocabularyRules.isValidTerm) ?? true,
                  (term.spokenForms?.count ?? 0) <= 5,
                  term.spokenForms?.allSatisfy(VocabularyRules.isValidTerm) ?? true,
                  seen.insert(VocabularyRules.key(term.canonical)).inserted else { throw VocabularyError.invalidTerms }
        }
        self.manifest = manifest
        self.terms = content.terms
        self.manifestData = manifestData
        self.termsData = termsData
    }

    private struct TermFile: Decodable {
        let schemaVersion: Int
        let locale: String
        let terms: [VocabularyTerm]
    }
}

public enum VocabularyRules {
    public static func isValidTerm(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 80
            && text == text.trimmingCharacters(in: .whitespacesAndNewlines)
            && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
            && !text.contains("<|") && !text.contains("|>")
    }

    public static func key(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }

    public static func personalTerms(from text: String) throws -> [String] {
        guard text.utf8.count <= 65_536 else { throw VocabularyError.limitExceeded }
        let terms = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard terms.count <= 200 else { throw VocabularyError.limitExceeded }
        guard terms.allSatisfy(isValidTerm) else { throw VocabularyError.invalidTerms }
        var seen: Set<String> = []
        return terms.filter { seen.insert(key($0)).inserted }
    }

    public static func orderedTerms(personal: [String], packages: [VocabularyPackage]) -> [VocabularyTerm] {
        let packageTerms = packages.flatMap(\.terms).enumerated().sorted {
            $0.element.priority == $1.element.priority ? $0.offset < $1.offset : $0.element.priority > $1.element.priority
        }.map(\.element)
        var seen: Set<String> = []
        return (personal.map { VocabularyTerm(canonical: $0) } + packageTerms)
            .filter { seen.insert(key($0.canonical)).inserted }
    }
}
