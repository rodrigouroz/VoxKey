import CoreAudio
import Foundation

struct AudioInputDescriptor: Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

struct AudioInputSelection: Equatable, Sendable {
    var deviceID: AudioDeviceID?
    var usedDefaultFallback = false
}

/// A value snapshot of the hardware boundary; names are consumed only by Settings.
struct AudioInputCatalog: Equatable, Sendable {
    var devices: [AudioInputDescriptor] = []
    var defaultID: AudioDeviceID?

    func selection(for uid: String?) -> AudioInputSelection {
        guard let uid else { return AudioInputSelection() }
        return AudioInputSelection(deviceID: devices.first { $0.uid == uid }?.id,
                                   usedDefaultFallback: !devices.contains { $0.uid == uid })
    }

    var defaultName: String { devices.first { $0.id == defaultID }?.name ?? "Unavailable" }
}

enum SystemAudioInputDevices {
    static func read() -> AudioInputCatalog {
        var address = property(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return AudioInputCatalog()
        }
        guard size > 0 else { return AudioInputCatalog(defaultID: defaultInputID()) }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return AudioInputCatalog() }
        let devices = ids.compactMap { id -> AudioInputDescriptor? in
            var streams = property(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0,
                  let uid = string(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = string(id, selector: kAudioObjectPropertyName) else { return nil }
            return AudioInputDescriptor(id: id, uid: uid, name: name)
        }
        return AudioInputCatalog(devices: devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                                 defaultID: defaultInputID())
    }

    static func defaultInputID() -> AudioDeviceID? {
        var address = property(kAudioHardwarePropertyDefaultInputDevice)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout.size(ofValue: id))
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func isAlive(_ id: AudioDeviceID) -> Bool {
        var address = property(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: alive))
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    static func property(_ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = property(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

@MainActor
final class AudioInputDeviceObserver {
    var onChange: ((AudioInputCatalog) -> Void)?
    private var listener: AudioObjectPropertyListenerBlock?
    private let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice]

    func start() {
        guard listener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        self.listener = listener
        for selector in selectors {
            var address = SystemAudioInputDevices.property(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        refresh()
    }

    func refresh() { onChange?(SystemAudioInputDevices.read()) }

    func stop() {
        guard let listener else { return }
        for selector in selectors {
            var address = SystemAudioInputDevices.property(selector)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        self.listener = nil
    }
}
