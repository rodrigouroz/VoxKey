import Foundation
import VoxKeyCore

@MainActor
final class VocabularyStore {
    struct InstalledPackage {
        let package: VocabularyPackage
        var active: Bool
    }

    private(set) var personalTerms: [String] = []
    private(set) var packages: [InstalledPackage] = []
    private let fileURL: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.rodrigouroz.VoxKey", isDirectory: true)) throws {
        fileURL = directory.appendingPathComponent("vocabulary.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Self.readFile(fileURL, limit: 16_777_216)
            let saved = try JSONDecoder().decode(SavedVocabulary.self, from: data)
            guard saved.schemaVersion == 1, saved.packages.count <= 20 else { throw VocabularyError.unreadableStorage }
            let personal = try VocabularyRules.personalTerms(from: saved.personalTerms.joined(separator: "\n"))
            guard personal == saved.personalTerms else { throw VocabularyError.unreadableStorage }
            var identifiers: Set<String> = []
            let restored = try saved.packages.map { entry in
                let package = try VocabularyPackage(manifestData: entry.manifest, termsData: entry.terms)
                guard identifiers.insert(package.manifest.identifier).inserted else { throw VocabularyError.unreadableStorage }
                return InstalledPackage(package: package, active: entry.active)
            }
            personalTerms = personal
            packages = restored
        } catch { throw VocabularyError.unreadableStorage }
    }

    var recognitionTerms: [VocabularyTerm] {
        VocabularyRules.orderedTerms(personal: personalTerms, packages: packages.filter(\.active).map(\.package))
    }

    func savePersonalTerms(_ text: String) throws {
        let personal = try VocabularyRules.personalTerms(from: text)
        try persist(personal: personal, packages: packages)
        personalTerms = personal
    }

    static func previewPackage(at selection: URL) throws -> VocabularyPackage {
        let folder = selection.lastPathComponent == "manifest.json" ? selection.deletingLastPathComponent() : selection
        do {
            if selection.pathExtension.lowercased() == "zip" {
                return try VocabularyPackage(zipData: readFile(selection, limit: 8_388_608))
            }
            let manifest = try readFile(folder.appendingPathComponent("manifest.json"), limit: 65_536)
            // The format permits only this sibling file, never paths supplied by the manifest.
            let terms = try readFile(folder.appendingPathComponent("terms.json"), limit: 524_288)
            return try VocabularyPackage(manifestData: manifest, termsData: terms)
        } catch let error as VocabularyError { throw error }
        catch { throw VocabularyError.invalidPackage }
    }

    func importPackage(_ package: VocabularyPackage) throws {
        var updated = packages
        if let index = updated.firstIndex(where: { $0.package.manifest.identifier == package.manifest.identifier }) {
            // A replacement must be activated explicitly, even if the old version was active.
            updated[index] = InstalledPackage(package: package, active: false)
        } else {
            guard updated.count < 20 else { throw VocabularyError.limitExceeded }
            updated.append(InstalledPackage(package: package, active: false))
        }
        try persist(personal: personalTerms, packages: updated)
        packages = updated
    }

    func setActive(_ active: Bool, identifier: String) throws {
        guard let index = packages.firstIndex(where: { $0.package.manifest.identifier == identifier }) else { return }
        var updated = packages
        updated[index].active = active
        try persist(personal: personalTerms, packages: updated)
        packages = updated
    }

    func removePackage(identifier: String) throws {
        let updated = packages.filter { $0.package.manifest.identifier != identifier }
        try persist(personal: personalTerms, packages: updated)
        packages = updated
    }

    private func persist(personal: [String], packages: [InstalledPackage]) throws {
        let saved = SavedVocabulary(schemaVersion: 1, personalTerms: personal, packages: packages.map {
            SavedPackage(manifest: $0.package.manifestData, terms: $0.package.termsData, active: $0.active)
        })
        let data = try JSONEncoder().encode(saved)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: fileURL, options: .atomic)
    }

    private static func readFile(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw VocabularyError.invalidPackage }
        guard (values.fileSize ?? limit + 1) <= limit else { throw VocabularyError.limitExceeded }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw VocabularyError.limitExceeded }
        return data
    }

    private struct SavedVocabulary: Codable {
        let schemaVersion: Int
        let personalTerms: [String]
        let packages: [SavedPackage]
    }
    private struct SavedPackage: Codable {
        let manifest: Data
        let terms: Data
        let active: Bool
    }
}
