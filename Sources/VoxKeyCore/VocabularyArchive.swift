import Foundation
import ZIPFoundation

extension VocabularyPackage {
    /// ZIP entries are decompressed into bounded memory, never into filesystem paths.
    public init(zipData: Data) throws {
        guard !zipData.isEmpty, zipData.count <= 8_388_608 else { throw VocabularyError.limitExceeded }
        let files: [[String]: Data]
        do {
            let expectedEntries = try Self.archiveEntryCount(zipData)
            // The file-backed reader handles invalid offsets as EOF. ZIPFoundation's
            // memory-backed reader can trap when a malformed entry seeks beyond its data.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxkey-zip-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let archiveURL = directory.appendingPathComponent("package.zip")
            try zipData.write(to: archiveURL, options: .atomic)
            files = try Self.readArchive(Archive(url: archiveURL, accessMode: .read), expectedEntries: expectedEntries)
        } catch let error as VocabularyError { throw error }
        catch { throw VocabularyError.invalidArchive }
        guard let manifest = files.first(where: { $0.key.last == "manifest.json" }),
              let terms = files.first(where: { $0.key.last == "terms.json" }),
              files.count == 2, manifest.key.dropLast() == terms.key.dropLast() else {
            throw VocabularyError.invalidArchive
        }
        try self.init(manifestData: manifest.value, termsData: terms.value)
    }

    private static func readArchive(_ archive: Archive, expectedEntries: Int) throws -> [[String]: Data] {
        var files: [[String]: Data] = [:]
        var seen: Set<String> = []
        var entryCount = 0
        var expandedBytes = 0
        for entry in archive {
            entryCount += 1
            guard entryCount <= 128 else { throw VocabularyError.limitExceeded }
            let components = try archivePath(entry.path)
            guard entry.type != .symlink,
                  seen.insert(components.joined(separator: "/").lowercased()).inserted else {
                throw VocabularyError.invalidArchive
            }
            let metadata = components.first == "__MACOSX" || components.last == ".DS_Store"
            let required = !metadata && (components.last == "manifest.json" || components.last == "terms.json")
            guard !required || (entry.type == .file && components.count <= 2) else {
                throw VocabularyError.invalidArchive
            }
            let limit = required ? (components.last == "manifest.json" ? 65_536 : 524_288) : 8_388_608
            guard entry.uncompressedSize <= limit else { throw VocabularyError.limitExceeded }
            var contents = Data()
            var entryBytes = 0
            let checksum = try archive.extract(entry, bufferSize: 16_384) { chunk in
                entryBytes += chunk.count
                expandedBytes += chunk.count
                guard entryBytes <= limit, expandedBytes <= 8_388_608 else { throw VocabularyError.limitExceeded }
                if required { contents.append(chunk) }
            }
            guard checksum == entry.checksum, entryBytes == entry.uncompressedSize else { throw VocabularyError.invalidArchive }
            if required { files[components] = contents }
        }
        guard entryCount == expectedEntries else { throw VocabularyError.invalidArchive }
        return files
    }

    /// ZIPFoundation's iterator ends early on encrypted or malformed entries.
    /// Check the classic ZIP directory count so a partial package cannot pass validation.
    /// ZIP64 and multi-volume archives are unnecessary for these small packages.
    private static func archiveEntryCount(_ data: Data) throws -> Int {
        guard data.count >= 22 else { throw VocabularyError.invalidArchive }
        func number(_ offset: Int, _ width: Int) -> Int {
            (0..<width).reduce(0) { $0 | (Int(data[data.startIndex + offset + $1]) << (8 * $1)) }
        }
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            guard number(offset, 4) == 0x06054b50,
                  offset + 22 + number(offset + 20, 2) == data.count else { continue }
            let count = number(offset + 10, 2)
            guard number(offset + 4, 2) == 0, number(offset + 6, 2) == 0,
                  number(offset + 8, 2) == count,
                  number(offset + 12, 4) + number(offset + 16, 4) == offset else {
                throw VocabularyError.invalidArchive
            }
            guard (1...128).contains(count) else { throw VocabularyError.limitExceeded }
            return count
        }
        throw VocabularyError.invalidArchive
    }

    private static func archivePath(_ path: String) throws -> [String] {
        guard !path.isEmpty, path.utf8.count <= 1_024,
              !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw VocabularyError.invalidArchive
        }
        var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.last == "" { components.removeLast() }
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw VocabularyError.invalidArchive
        }
        return components
    }
}
