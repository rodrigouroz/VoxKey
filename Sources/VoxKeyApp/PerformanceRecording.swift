#if VOXKEY_PERFORMANCE && VOXKEY_RELEASE
#error("Performance recording is restricted to local performance builds.")
#endif

#if VOXKEY_PERFORMANCE && !VOXKEY_RELEASE
import AppKit
import Darwin
import Foundation
import Synchronization

/// This schema deliberately cannot accept audio, transcript text, vocabulary,
/// arbitrary destination names, window titles, or error descriptions. Known
/// application categories and allowlisted AX metadata explain delivery failures.
struct PerformanceRecord: Codable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let date: Date
    let build: String
    let model: String
    let language: String
    let improvementEnabled: Bool
    var outcome: String
    var milestonesMS: [String: Double]
    var totals: [String: Double]
    var processCPUTimeMS: Double
    var captureProcessCPUTimeMS: Double?
    var sampledPeakResidentBytes: UInt64
    let thermalStateAtStart: Int
    var thermalStateAtEnd: Int
    var destination: DestinationDiagnosticRecord?
    var delivery: DestinationDiagnosticRecord?
}

enum PerformanceMilestone: String {
    case destinationResolved, captureStarted, releaseRequested, microphoneClosed
    case recognitionReady, improvementFinished, deliveryStarted, finished
}

enum PerformanceMetric: String {
    case captureAudioSeconds, resampledAudioSeconds, resampleCalls, resampleMS
    case drainPolls, drainBatches, drainMS, maximumPendingAudioSeconds
    case previewDecodes, previewDecodeMS, previewAudioSeconds, previewCompleted, previewInterrupted
    case authoritativeDecodes, authoritativeDecodeMS, authoritativeAudioSeconds
    case authoritativeDecodesBeforeRelease, maximumUncommittedAudioSeconds
    case previewCancellationWaitMS, finalTailAudioSeconds, firstPreviewMS
    case s1MS, gectorMS, improvementMS, deliveryMS, finalCharacterCount
    case s1ProposedTokens, s1AcceptedTokens
}

enum PerformanceOutcome: String { case delivered, unconfirmed, noDestination, noSpeech, cancelled, failed, interrupted }

private struct ProcessMeasurement {
    let cpuMS: Double
    let residentBytes: UInt64

    static func read() -> Self {
        var usage = rusage()
        let valid = getrusage(RUSAGE_SELF, &usage) == 0
        let cpu = valid ? (Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000) : 0
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return Self(cpuMS: cpu, residentBytes: result == KERN_SUCCESS ? info.resident_size : 0)
    }
}

/// One small in-memory accumulator per session. Nothing writes on the audio
/// callback or inference path. Late updates are ignored after finalization.
final class PerformanceSession: Sendable {
    private struct State: Sendable { var record: PerformanceRecord; var finished = false }
    private let state: Mutex<State>
    private let started = ContinuousClock.now
    private let initialCPU: Double

    init(id: UUID = UUID(), model: TranscriptionModel, language: String?, improvementEnabled: Bool) {
        let resources = ProcessMeasurement.read()
        initialCPU = resources.cpuMS
        state = Mutex(State(record: PerformanceRecord(schemaVersion: 1, id: id, date: Date(),
            build: Bundle.main.object(forInfoDictionaryKey: "VoxKeyBuildID") as? String ?? "test",
            model: model.rawValue, language: language ?? "auto", improvementEnabled: improvementEnabled,
            outcome: PerformanceOutcome.interrupted.rawValue, milestonesMS: [:], totals: [:],
            processCPUTimeMS: 0, sampledPeakResidentBytes: resources.residentBytes,
            thermalStateAtStart: ProcessInfo.processInfo.thermalState.rawValue,
            thermalStateAtEnd: ProcessInfo.processInfo.thermalState.rawValue)))
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15
    }

    func mark(_ milestone: PerformanceMilestone) {
        let elapsed = Self.milliseconds(since: started)
        let resources = ProcessMeasurement.read()
        state.withLock {
            guard !$0.finished, $0.record.milestonesMS[milestone.rawValue] == nil else { return }
            $0.record.milestonesMS[milestone.rawValue] = elapsed
            $0.record.sampledPeakResidentBytes = max($0.record.sampledPeakResidentBytes, resources.residentBytes)
            if milestone == .releaseRequested { $0.record.captureProcessCPUTimeMS = max(0, resources.cpuMS - initialCPU) }
        }
    }

    func add(_ metric: PerformanceMetric, _ value: Double = 1) {
        guard value.isFinite, value >= 0 else { return }
        state.withLock {
            guard !$0.finished else { return }
            $0.record.totals[metric.rawValue, default: 0] += value
        }
    }

    func maximum(_ metric: PerformanceMetric, _ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        state.withLock {
            guard !$0.finished else { return }
            $0.record.totals[metric.rawValue] = max($0.record.totals[metric.rawValue] ?? 0, value)
        }
    }

    func firstPreview() {
        let elapsed = Self.milliseconds(since: started)
        state.withLock {
            guard !$0.finished, $0.record.totals[PerformanceMetric.firstPreviewMS.rawValue] == nil else { return }
            $0.record.totals[PerformanceMetric.firstPreviewMS.rawValue] = elapsed
        }
    }

    var released: Bool { state.withLock { $0.record.milestonesMS[PerformanceMilestone.releaseRequested.rawValue] != nil } }

    func recordDestination(_ diagnostics: DestinationDiagnosticRecord, delivery: Bool = false) {
        state.withLock {
            guard !$0.finished else { return }
            if delivery { $0.record.delivery = diagnostics }
            else { $0.record.destination = diagnostics }
        }
    }

    func finish(_ outcome: PerformanceOutcome) -> PerformanceRecord? {
        mark(.finished)
        let resources = ProcessMeasurement.read()
        return state.withLock {
            guard !$0.finished else { return nil }
            $0.finished = true
            $0.record.outcome = outcome.rawValue
            $0.record.processCPUTimeMS = max(0, resources.cpuMS - initialCPU)
            $0.record.thermalStateAtEnd = ProcessInfo.processInfo.thermalState.rawValue
            return $0.record
        }
    }
}

/// Explicit performance bundles opt in by construction; public builds contain
/// none of this code. Use one serial utility queue for bounded, owner-only files.
final class PerformanceRecording: Sendable {
    static let shared = PerformanceRecording()
    static let directory = URL.applicationSupportDirectory.appendingPathComponent("com.rodrigouroz.VoxKey/Diagnostics/Performance")
    private let active = Mutex<PerformanceSession?>(nil)
    private let writer = DispatchQueue(label: "com.voxkey.performance.writer", qos: .utility)
    var current: PerformanceSession? { active.withLock { $0 } }

    #if !VOXKEY_PACKAGED
    /// Explicit test scope; never starts persistence or changes user preferences.
    func useForTesting(_ session: PerformanceSession?) { active.withLock { $0 = session } }
    #endif

    func begin(id: UUID, model: TranscriptionModel, language: String?, improvementEnabled: Bool) {
        guard Bundle.main.object(forInfoDictionaryKey: "VoxKeyPerformanceBuild") as? Bool == true else { return }
        active.withLock { $0 = PerformanceSession(id: id, model: model, language: language, improvementEnabled: improvementEnabled) }
    }

    func finish(_ outcome: PerformanceOutcome) {
        let session = active.withLock { value in let previous = value; value = nil; return previous }
        guard let record = session?.finish(outcome) else { return }
        writer.async {
            do { try Self.save(record, to: Self.directory) }
            catch { fputs("VoxKey performance report could not be saved.\n", stderr) }
        }
    }

    static func save(_ record: PerformanceRecord, to directory: URL, maximumRecords: Int = 200) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var root = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let path = directory.appendingPathComponent("\(record.id.uuidString).json")
        try data.write(to: path, options: [.atomic, .completeFileProtection])
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let records = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" }
            .map { ($0, (try $0.resourceValues(forKeys: [.contentModificationDateKey])).contentModificationDate ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        for (index, entry) in records.enumerated() where index >= maximumRecords || entry.1 < Date().addingTimeInterval(-7 * 86_400) {
            try files.removeItem(at: entry.0)
        }
    }
}
#endif
