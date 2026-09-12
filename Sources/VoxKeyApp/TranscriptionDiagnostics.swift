#if VOXKEY_LOCAL_DIAGNOSTICS && (!DEBUG || VOXKEY_RELEASE)
#error("Local diagnostics require Debug configuration and cannot be compiled into release or candidate packages.")
#endif

#if DEBUG && VOXKEY_LOCAL_DIAGNOSTICS && !VOXKEY_RELEASE
import AppKit
import Foundation
import os

// TEMPORARY RC ONLY: remove this file, its call sites and preference before shipping.
struct TranscriptionTrace: Codable, Sendable {
    let id: UUID
    let event: String
    let date: Date
    let build: String
    var raw: String
    var s1: String?
    var s1Rejected: Bool?
    var grammarInput: String?
    var gector: String?
    var output: String
    var status: String
    var language: String?
    var recognitionFinalizationMilliseconds: Double?
    var deliveryMilliseconds: Double?
    var s1Milliseconds: Double?
    var gectorMilliseconds: Double?
    var totalMilliseconds: Double?
    var proposedTokens: UInt64?
    var acceptedTokens: UInt64?
    var epoch: Int
}

/// Explicitly opted-in text stays in owner-only, bounded local files, never os_log.
/// The same lock serializes writes, opt-out and deletion, invalidating in-flight records.
final class TranscriptionDiagnostics: @unchecked Sendable {
    static let preferenceKey = "VoxKeyTemporaryTranscriptionTraceEnabled"
    static let shared = TranscriptionDiagnostics()
    let directory: URL
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var epoch = 0
    private let maximumRecords: Int
    private let logger = Logger(subsystem: "com.rodrigouroz.VoxKey", category: "trace")

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("com.rodrigouroz.VoxKey/Diagnostics/Transcription"),
         defaults: UserDefaults = .standard, maximumRecords: Int = 100) {
        self.directory = directory
        self.defaults = defaults
        self.maximumRecords = maximumRecords
    }

    var enabled: Bool { lock.withLock { defaults.bool(forKey: Self.preferenceKey) } }
    func setEnabled(_ enabled: Bool) {
        lock.withLock { epoch += 1; defaults.set(enabled, forKey: Self.preferenceKey) }
    }

    func begin(id: UUID, raw: String, event: String = "improvement") -> TranscriptionTrace? {
        lock.withLock {
            guard defaults.bool(forKey: Self.preferenceKey) else { return nil }
            return TranscriptionTrace(id: id, event: event, date: Date(),
                build: Bundle.main.object(forInfoDictionaryKey: "VoxKeyBuildID") as? String ?? "test",
                raw: raw, output: raw, status: "not_ready", epoch: epoch)
        }
    }

    func save(_ trace: TranscriptionTrace?) {
        guard let trace else { return }
        lock.withLock {
            guard defaults.bool(forKey: Self.preferenceKey), trace.epoch == epoch else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                var root = directory
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try root.setResourceValues(values)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(trace)
                // Never store a partial transcript as if it were the full input.
                guard data.count <= 256_000 else { return }
                let file = directory.appendingPathComponent("\(trace.id.uuidString)-\(trace.event).json")
                try data.write(to: file, options: [.atomic, .completeFileProtection])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                try prune()
            } catch { logger.error("transcription trace write failed") }
        }
    }

    func deleteAll() throws {
        try lock.withLock {
            epoch += 1
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
    }

    private func prune() throws {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            .filter { $0.pathExtension == "json" }
            .map { ($0, try $0.resourceValues(forKeys: keys)) }
            .sorted { ($0.1.contentModificationDate ?? .distantPast) > ($1.1.contentModificationDate ?? .distantPast) }
        var bytes = 0
        for (index, item) in files.enumerated() {
            bytes += item.1.fileSize ?? 0
            if index >= maximumRecords || bytes > 10_000_000 || (item.1.contentModificationDate ?? .distantPast) < Date().addingTimeInterval(-7 * 86_400) {
                try FileManager.default.removeItem(at: item.0)
            }
        }
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let d = start.duration(to: .now).components
        return Double(d.seconds) * 1000 + Double(d.attoseconds) / 1e15
    }
}

@MainActor
final class TranscriptionDiagnosticsCard: VoxKeyCardView {
    let checkbox = NSButton(checkboxWithTitle: "Record temporary transcription traces", target: nil, action: nil)
    private let note = VoxKeyDesign.label("Saves dictated text and model outputs on this Mac. No audio. Keeps up to 100 records / 10 MB; prunes records older than 7 days when saving. Local Debug build only.", style: .caption, color: VoxKeyDesign.secondaryInk)
    init() {
        super.init(fill: VoxKeyDesign.surface, border: VoxKeyDesign.border, cornerRadius: VoxKeyDesign.Layout.cardRadius)
        checkbox.state = TranscriptionDiagnostics.shared.enabled ? .on : .off
        checkbox.target = self; checkbox.action = #selector(toggle)
        let show = NSButton(title: "Show Traces", target: self, action: #selector(showTraces))
        let delete = NSButton(title: "Delete Traces", target: self, action: #selector(deleteTraces))
        VoxKeyDesign.configureButton(show); VoxKeyDesign.configureButton(delete)
        VoxKeyDesign.embed(VoxKeyDesign.vertical([checkbox, note, VoxKeyDesign.horizontal([show, delete, NSView()])], spacing: 6), in: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggle() { TranscriptionDiagnostics.shared.setEnabled(checkbox.state == .on) }
    @objc private func showTraces() {
        if FileManager.default.fileExists(atPath: TranscriptionDiagnostics.shared.directory.path) {
            NSWorkspace.shared.open(TranscriptionDiagnostics.shared.directory)
        }
    }
    @objc private func deleteTraces() {
        do { try TranscriptionDiagnostics.shared.deleteAll() }
        catch { note.stringValue = "Could not delete traces. Use Show Traces to inspect the local folder." }
    }
}
#endif
