import CryptoKit
import Foundation
import Testing
@testable import VoxKeyApp
import VoxKeyCore
import ZIPFoundation

private struct ZipEntry {
    let path: String
    var data = Data()
    var link: String? = nil
}

private func vocabularyZip(_ entries: [ZipEntry]) throws -> Data {
    let archive = try Archive(accessMode: .create)
    for item in entries {
        let contents = item.link.map { Data($0.utf8) } ?? item.data
        let type: Entry.EntryType = item.link == nil ? (item.path.hasSuffix("/") ? .directory : .file) : .symlink
        try archive.addEntry(with: item.path, type: type, uncompressedSize: Int64(contents.count), compressionMethod: .deflate) { position, size in
            contents.subdata(in: Int(position)..<(Int(position) + size))
        }
    }
    return try #require(archive.data)
}

private func vocabularyZipEntries(prefix: String = "", version: String = "1") throws -> [ZipEntry] {
    let terms = Data(#"{"schemaVersion":1,"locale":"en","terms":[{"canonical":"Quasar Ledger","priority":100}]}"#.utf8)
    let manifest = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 1, "identifier": "org.example.zip", "displayName": "Example Vocabulary",
        "version": version, "classification": "personal", "locales": ["en"],
        "content": ["path": "terms.json", "sha256": SHA256.hash(data: terms).map { String(format: "%02x", $0) }.joined()]
    ])
    return [ZipEntry(path: prefix + "manifest.json", data: manifest), ZipEntry(path: prefix + "terms.json", data: terms)]
}

@MainActor
@Test(arguments: ["", "Example Vocabulary/"])
func vocabularyZIPPreviewAndReplacementPreserveActivationRules(prefix: String) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("package.ZIP")
    let entries = try vocabularyZipEntries(prefix: prefix)
    let zip = try vocabularyZip(entries + [ZipEntry(path: "__MACOSX/._Example Vocabulary", data: Data("metadata".utf8))])
    try zip.write(to: url)
    let package = try VocabularyStore.previewPackage(at: url)
    #expect(package.terms.map(\.canonical) == ["Quasar Ledger"])
    #expect(package.manifest.version == "1")
    // Preview leaves the archive intact and creates no extracted or saved files.
    #expect(try Data(contentsOf: url) == zip)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["package.ZIP"])
    let store = try VocabularyStore(directory: directory)
    try store.importPackage(package)
    #expect(store.recognitionTerms.isEmpty)
    try store.setActive(true, identifier: package.manifest.identifier)
    #expect(store.recognitionTerms.map(\.canonical) == ["Quasar Ledger"])
    try vocabularyZip(vocabularyZipEntries(prefix: prefix, version: "2")).write(to: url)
    try store.importPackage(VocabularyStore.previewPackage(at: url))
    let restored = try VocabularyStore(directory: directory)
    #expect(restored.packages.count == 1)
    #expect(restored.packages.first?.package.manifest.version == "2")
    #expect(restored.recognitionTerms.isEmpty)
}

@Test
func vocabularyZIPAcceptsFinderDirectoriesAndUnrelatedFiles() throws {
    let entries = try vocabularyZipEntries(prefix: "Example/") + [
        ZipEntry(path: "Example/"), ZipEntry(path: "__MACOSX/"),
        ZipEntry(path: "Example/.DS_Store", data: Data("metadata".utf8)),
        ZipEntry(path: "Example/README.md", data: Data("Instructions".utf8))
    ]
    #expect(try VocabularyPackage(zipData: vocabularyZip(entries)).terms.count == 1)
}

@Test(arguments: ["../escape", "/tmp/escape", "Example/../../escape", "Example\\escape", "C:/escape", "Example//escape"])
func vocabularyZIPRejectsUnsafePaths(path: String) throws {
    let entries = try vocabularyZipEntries() + [ZipEntry(path: path)]
    #expect(throws: VocabularyError.self) { try VocabularyPackage(zipData: vocabularyZip(entries)) }
}

@Test
func vocabularyZIPRejectsLinksDuplicatesAndAmbiguousPackages() throws {
    let entries = try vocabularyZipEntries()
    let invalid = [
        entries + [ZipEntry(path: "link", link: "../../outside")],
        entries + [entries[0]],
        entries + [ZipEntry(path: "MANIFEST.JSON", data: entries[0].data)],
        entries + (try vocabularyZipEntries(prefix: "Second/")),
        [entries[0], ZipEntry(path: "Other/terms.json", data: entries[1].data)],
        [entries[0]],
        try vocabularyZipEntries(prefix: "Nested/Package/")
    ]
    for archive in invalid {
        #expect(throws: VocabularyError.self) { try VocabularyPackage(zipData: vocabularyZip(archive)) }
    }
}

@Test
func vocabularyZIPRejectsCorruptionAndPackageTampering() throws {
    let entries = try vocabularyZipEntries()
    let archive = try vocabularyZip(entries)
    #expect(throws: VocabularyError.self) { try VocabularyPackage(zipData: Data("not a zip".utf8)) }
    #expect(throws: VocabularyError.self) { try VocabularyPackage(zipData: archive.prefix(archive.count / 2)) }
    let changed = [entries[0], ZipEntry(path: "terms.json", data: Data("{}".utf8))]
    #expect(throws: VocabularyError.self) { try VocabularyPackage(zipData: vocabularyZip(changed)) }
}

@Test
func vocabularyZIPRejectsEncryptedOrUnreadableTrailingEntriesAndBadCRC() throws {
    let entries = try vocabularyZipEntries() + [ZipEntry(path: "README.md", data: Data("readme".utf8))]
    let zip = try vocabularyZip(entries)
    let signature = Data([0x50, 0x4b, 0x01, 0x02])
    let first = try #require(zip.range(of: signature)?.lowerBound)
    let last = try #require(zip.range(of: signature, options: .backwards)?.lowerBound)
    var encrypted = zip
    encrypted[last + 8] |= 1
    #expect(throws: VocabularyError.self) { try VocabularyPackage(zipData: encrypted) }
    var unreadable = zip
    unreadable.replaceSubrange((last + 42)..<(last + 46), with: [0xff, 0xff, 0xff, 0x7f])
    #expect(throws: VocabularyError.self) { try VocabularyPackage(zipData: unreadable) }
    var wrongCRC = zip
    wrongCRC[first + 16] ^= 1
    #expect(throws: VocabularyError.self) { try VocabularyPackage(zipData: wrongCRC) }
}

@Test
func vocabularyZIPRejectsOversizedContentsAndTooManyEntries() throws {
    let entries = try vocabularyZipEntries()
    for (name, limit) in [("manifest.json", 65_536), ("terms.json", 524_288)] {
        let oversized = entries.filter { $0.path != name } + [ZipEntry(path: name, data: Data(repeating: 32, count: limit + 1))]
        #expect(throws: VocabularyError.self) { try VocabularyPackage(zipData: vocabularyZip(oversized)) }
    }
    let bomb = entries + [ZipEntry(path: "README.md", data: Data(repeating: 32, count: 8_388_609))]
    #expect(throws: VocabularyError.self) { try VocabularyPackage(zipData: vocabularyZip(bomb)) }
    let aggregateBomb = entries + (0..<2).map { ZipEntry(path: "extra-\($0)", data: Data(repeating: 32, count: 4_194_305)) }
    #expect(throws: VocabularyError.self) { try VocabularyPackage(zipData: vocabularyZip(aggregateBomb)) }
    let many = entries + (0..<127).map { ZipEntry(path: "extra-\($0)") }
    #expect(throws: VocabularyError.self) { try VocabularyPackage(zipData: vocabularyZip(many)) }
}
