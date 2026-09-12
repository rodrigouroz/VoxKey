import Foundation

/// The pinned publisher artifact. Installation
/// happens only after opt-in, verifies the entire file, and commits atomically.
actor S1ModelStore {
    struct Artifact: Sendable {
        let name: String
        let url: URL
        let bytes: Int
        let sha256: String
        static let qualified = Artifact(
            name: "s1-mini-f16-34add00a.gguf",
            url: URL(string: "https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/34add00a48a2e5d24e5a4ee5405a99620a3a240c/s1-mini-f16.gguf")!,
            bytes: 1_509_347_232,
            sha256: "0370da4f1bae19e3150bcafa33c5d396c15f97bf25519540a3e013db5cc00af4")
    }

    private let root: URL
    private let artifact: Artifact
    private let configuration: URLSessionConfiguration
    private var preparing = false

    init(root: URL = GrammarModelStore.defaultRoot, artifact: Artifact = .qualified,
         configuration: URLSessionConfiguration = .ephemeral) {
        self.root = root
        self.artifact = artifact
        self.configuration = configuration
    }

    func prepare(download: Bool, repair: Bool = false,
                 progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard !preparing else { throw GrammarInstallationError.busy }
        preparing = true
        defer { preparing = false }
        try Task.checkCancellation()
        let destination = root.appendingPathComponent(artifact.name)
        if !repair, try GrammarModelStore.matches(destination, bytes: artifact.bytes, sha256: artifact.sha256) {
            try Task.checkCancellation()
            return destination
        }
        guard download else { throw GrammarInstallationError.downloadRequired }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let temporary = root.appendingPathComponent("s1-partial-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let expected = artifact.bytes
        let transfer = GrammarAssetDownload(destination: temporary, limit: expected) { count in
            progress(Double(count) / Double(expected))
        }
        progress(0)
        let response = try await transfer.run(from: artifact.url, configuration: configuration)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https",
              try GrammarModelStore.matches(temporary, bytes: artifact.bytes, sha256: artifact.sha256) else {
            throw GrammarInstallationError.invalidAsset
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        progress(1)
        return destination
    }
}
