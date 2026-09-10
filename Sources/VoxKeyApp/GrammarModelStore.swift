import CoreML
import CryptoKit
import Foundation
import Synchronization

enum GrammarInstallationError: Error, Equatable { case downloadRequired, invalidAsset, busy }

/// A signed, pinned recipe maps the author's original weights into the exact
/// qualified Core ML FP16 blob. No Python, conversion service, or model host
/// operated by VoxKey is involved on the user's Mac.
struct GrammarModelRecipe: Decodable, Sendable {
    struct File: Decodable, Sendable {
        let name: String
        let url: URL
        let bytes: Int
        let sha256: String
    }
    struct Constant: Decodable, Sendable { let offset: Int; let data: Data }
    struct Conversion: Decodable, Sendable {
        let sourceOffset: Int
        let count: Int
        let destinationOffset: Int
        let repetitions: Int
    }
    let identifier: String
    let modelBytes: Int
    let modelSHA256: String
    let files: [File]
    let outputBytes: Int
    let outputSHA256: String
    let constants: [Constant]
    let conversions: [Conversion]
}

actor GrammarModelStore {
    static var preparationResources: URL? { preparationResources(in: .main) }
    static func preparationResources(in application: Bundle) -> URL? {
        if application.bundleURL.pathExtension == "app" {
            // Match build-app.sh's location; a packaged app must never load
            // SwiftPM's absolute developer-checkout fallback.
            guard let resources = application.resourceURL,
                  let bundle = Bundle(url: resources.appendingPathComponent("VoxKey_VoxKeyApp.bundle")) else { return nil }
            return bundle.resourceURL?.appendingPathComponent("GrammarPreparation")
        }
        #if VOXKEY_PACKAGED
        // Packaged resources must be self-contained, including compiled metadata.
        return nil
        #else
        return Bundle.module.resourceURL?.appendingPathComponent("GrammarPreparation")
        #endif
    }
    static var defaultRoot: URL {
        URL.applicationSupportDirectory.appendingPathComponent("com.rodrigouroz.VoxKey/Models", isDirectory: true)
    }

    private let root: URL
    private let resources: URL?
    private let session: URLSession
    private var preparing = false

    init(root: URL = GrammarModelStore.defaultRoot, resources: URL? = GrammarModelStore.preparationResources,
         session: URLSession = URLSession(configuration: .ephemeral)) {
        self.root = root
        self.resources = resources
        self.session = session
    }

    func prepare(download: Bool, repair: Bool = false,
                 progress: @escaping @Sendable (GrammarCorrectionState) -> Void = { _ in }) async throws -> URL {
        guard !preparing else { throw GrammarInstallationError.busy }
        preparing = true
        defer { preparing = false }
        guard let resources else { throw GrammarInstallationError.invalidAsset }
        let recipeData = try Data(contentsOf: resources.appendingPathComponent("recipe.json"))
        let recipe = try JSONDecoder().decode(GrammarModelRecipe.self, from: recipeData)
        guard try Self.matches(resources.appendingPathComponent("model.mlmodel"), bytes: recipe.modelBytes, sha256: recipe.modelSHA256) else {
            throw GrammarInstallationError.invalidAsset
        }
        let receipt = Data(SHA256.hash(data: recipeData))
        let destination = root.appendingPathComponent(recipe.identifier, isDirectory: true)
        if !repair, installed(destination, receipt: receipt) { return destination }
        guard download else { throw GrammarInstallationError.downloadRequired }
        try Task.checkCancellation()
        let downloads = root.appendingPathComponent(recipe.identifier + "-downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        var cacheRoot = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try cacheRoot.setResourceValues(values)
        let total = recipe.files.reduce(0) { $0 + $1.bytes }
        var completed = 0
        for file in recipe.files {
            try Task.checkCancellation()
            let target = downloads.appendingPathComponent(file.name)
            if !(try Self.matches(target, bytes: file.bytes, sha256: file.sha256)) {
                let preceding = completed
                let temporary = downloads.appendingPathComponent("partial-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temporary) }
                progress(.downloading(Double(preceding) / Double(total)))
                let transfer = GrammarAssetDownload(destination: temporary, limit: file.bytes) { count in
                    progress(.downloading(Double(preceding + count) / Double(total)))
                }
                let response = try await transfer.run(from: file.url, configuration: session.configuration)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      http.url?.scheme == "https",
                      try Self.matches(temporary, bytes: file.bytes, sha256: file.sha256) else {
                    throw GrammarInstallationError.invalidAsset
                }
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.moveItem(at: temporary, to: target)
            }
            completed += file.bytes
            progress(.downloading(Double(completed) / Double(total)))
        }
        progress(.preparing)
        let staging = root.appendingPathComponent("grammar-install-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let package = staging.appendingPathComponent("Gector.mlpackage", isDirectory: true)
        let dataDirectory = package.appendingPathComponent("Data/com.apple.CoreML", isDirectory: true)
        let weightDirectory = dataDirectory.appendingPathComponent("weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weightDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: resources.appendingPathComponent("Manifest.json"), to: package.appendingPathComponent("Manifest.json"))
        try FileManager.default.copyItem(at: resources.appendingPathComponent("model.mlmodel"), to: dataDirectory.appendingPathComponent("model.mlmodel"))
        let weights = weightDirectory.appendingPathComponent("weight.bin")
        try await Self.convert(source: downloads.appendingPathComponent("model.safetensors"), destination: weights, recipe: recipe)
        guard try Self.matches(weights, bytes: recipe.outputBytes, sha256: recipe.outputSHA256) else {
            throw GrammarInstallationError.invalidAsset
        }
        try Task.checkCancellation()
        let compiled = try await MLModel.compileModel(at: package)
        defer { try? FileManager.default.removeItem(at: compiled) }
        try Task.checkCancellation()
        let prepared = staging.appendingPathComponent("prepared", isDirectory: true)
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: compiled, to: prepared.appendingPathComponent("Gector.mlmodelc", isDirectory: true))
        for file in recipe.files where file.name != "model.safetensors" {
            try FileManager.default.copyItem(at: downloads.appendingPathComponent(file.name), to: prepared.appendingPathComponent(file.name))
        }
        try receipt.write(to: prepared.appendingPathComponent("receipt"), options: .atomic)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: prepared)
        } else {
            try FileManager.default.moveItem(at: prepared, to: destination)
        }
        // Keep completed downloads across interrupted installs, then reclaim the
        // original FP32 checkpoint once the verified FP16 installation is committed.
        try? FileManager.default.removeItem(at: downloads)
        return destination
    }

    private func installed(_ directory: URL, receipt: Data) -> Bool {
        guard (try? Data(contentsOf: directory.appendingPathComponent("receipt"))) == receipt else { return false }
        return ["Gector.mlmodelc/coremldata.bin", "tokenizer.json", "config.json", "verb-form-vocab.txt"].allSatisfy {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    static func matches(_ url: URL, bytes: Int, sha256: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.size] as? Int == bytes else { return false }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == sha256
    }

    static func convert(source: URL, destination: URL, recipe: GrammarModelRecipe) async throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw GrammarInstallationError.invalidAsset }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        try output.truncate(atOffset: UInt64(recipe.outputBytes))
        for constant in recipe.constants {
            guard constant.offset >= 0, constant.offset <= recipe.outputBytes - constant.data.count else { throw GrammarInstallationError.invalidAsset }
            try output.seek(toOffset: UInt64(constant.offset))
            try output.write(contentsOf: constant.data)
        }
        for conversion in recipe.conversions {
            await Task.yield()
            try Task.checkCancellation()
            guard conversion.count > 0, conversion.count <= 50_000_000,
                  conversion.repetitions > 0, conversion.repetitions <= 80,
                  conversion.sourceOffset >= 0, conversion.destinationOffset >= 0,
                  conversion.count * 2 * conversion.repetitions <= recipe.outputBytes - conversion.destinationOffset else {
                throw GrammarInstallationError.invalidAsset
            }
            try input.seek(toOffset: UInt64(conversion.sourceOffset))
            guard let data = try input.read(upToCount: conversion.count * 4), data.count == conversion.count * 4 else {
                throw GrammarInstallationError.invalidAsset
            }
            var half = Data(count: conversion.count * 2)
            data.withUnsafeBytes { sourceBytes in
                half.withUnsafeMutableBytes { targetBytes in
                    for index in 0..<conversion.count {
                        let bits = UInt32(littleEndian: sourceBytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
                        let value = Float16(Float(bitPattern: bits)).bitPattern.littleEndian
                        targetBytes.storeBytes(of: value, toByteOffset: index * 2, as: UInt16.self)
                    }
                }
            }
            try output.seek(toOffset: UInt64(conversion.destinationOffset))
            for _ in 0..<conversion.repetitions { try output.write(contentsOf: half) }
        }
        try output.synchronize()
    }
}

final class GrammarAssetDownload: NSObject, URLSessionDownloadDelegate, Sendable {
    private struct State {
        var continuation: CheckedContinuation<URLResponse, Error>?
        var task: URLSessionDownloadTask?
        var cancelled = false
        var failure: Error?
        var moved = false
        var lastPercent = -1
    }
    private let destination: URL
    private let limit: Int
    private let report: @Sendable (Int) -> Void
    private let state = Mutex(State())

    init(destination: URL, limit: Int, report: @escaping @Sendable (Int) -> Void) {
        self.destination = destination; self.limit = limit; self.report = report
    }

    func run(from url: URL, configuration: URLSessionConfiguration) async throws -> URLResponse {
        // The async URLSession.download convenience consumes download-delegate
        // callbacks. An explicit task preserves progress and the size limit.
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: url)
                let start = state.withLock { state in
                    guard !state.cancelled else { return false }
                    state.continuation = continuation
                    state.task = task
                    return true
                }
                if start { task.resume() } else {
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let task = self.state.withLock { state in
                state.cancelled = true
                return state.task
            }
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= limit else {
            state.withLock { $0.failure = GrammarInstallationError.invalidAsset }
            downloadTask.cancel()
            return
        }
        let percent = Int(totalBytesWritten) * 100 / max(1, limit)
        let changed = state.withLock { state in
            guard percent != state.lastPercent else { return false }
            state.lastPercent = percent
            return true
        }
        if changed { report(Int(totalBytesWritten)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            state.withLock { $0.moved = true }
        } catch { state.withLock { $0.failure = error } }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completion = state.withLock { state -> (CheckedContinuation<URLResponse, Error>?, Error?) in
            let continuation = state.continuation
            state.continuation = nil
            state.task = nil
            let failure: Error? = state.cancelled ? CancellationError()
                : state.failure ?? error ?? (state.moved ? nil : GrammarInstallationError.invalidAsset)
            return (continuation, failure)
        }
        if let error = completion.1 { completion.0?.resume(throwing: error) }
        else if let response = task.response { completion.0?.resume(returning: response) }
        else { completion.0?.resume(throwing: GrammarInstallationError.invalidAsset) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}
