import Foundation
@preconcurrency import WhisperKit

/// Downloaded files are independent of the one model loaded for dictation.
struct TranscriptionModelFiles: Sendable {
    let root: URL?

    static func downloadBase() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw TranscriptionError.modelNotInstalled
        }
        return documents.appending(path: "huggingface", directoryHint: .isDirectory)
    }

    func folder(for model: String) throws -> URL {
        let directory = try root ?? Self.downloadBase().appending(path: "models/argmaxinc/whisperkit-coreml", directoryHint: .isDirectory)
        return directory.appending(path: model, directoryHint: .isDirectory)
    }

    static func isComplete(at folder: URL) -> Bool {
        ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { component in
            let file = folder.appending(path: "\(component).mlmodelc/weights/weight.bin")
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        }
    }

    func installedModels() -> Set<TranscriptionModel> {
        Set(TranscriptionModel.allCases.filter { model in
            guard let folder = try? folder(for: model.rawValue) else { return false }
            return Self.isComplete(at: folder)
        })
    }
}

actor TranscriptionModelLibrary {
    private var downloading = false
    private let files = TranscriptionModelFiles(root: nil)

    func installedModels() -> Set<TranscriptionModel> { files.installedModels() }

    func download(_ model: TranscriptionModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !downloading else { throw TranscriptionError.inferenceBusy }
        if files.installedModels().contains(model) { return }
        downloading = true
        defer { downloading = false }
        let folder = try await WhisperKit.download(variant: model.rawValue, downloadBase: TranscriptionModelFiles.downloadBase()) {
            progress($0.fractionCompleted)
        }
        try Task.checkCancellation()
        guard TranscriptionModelFiles.isComplete(at: folder) else { throw TranscriptionError.modelNotInstalled }
    }
}
