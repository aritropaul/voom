import CoreAudio
import Foundation

public struct AudioOutputDeviceInfo: Identifiable, Equatable, Sendable {
    public var id: String { uniqueID }
    public let uniqueID: String
    public let audioDeviceID: UInt32
    public let localizedName: String
    public let isBluetooth: Bool
    public let isBuiltIn: Bool

    public init(
        uniqueID: String,
        audioDeviceID: UInt32,
        localizedName: String,
        isBluetooth: Bool,
        isBuiltIn: Bool
    ) {
        self.uniqueID = uniqueID
        self.audioDeviceID = audioDeviceID
        self.localizedName = localizedName
        self.isBluetooth = isBluetooth
        self.isBuiltIn = isBuiltIn
    }
}

public enum AudioOutputDeviceError: LocalizedError {
    case deviceUnavailable
    case selectionUnavailable
    case coreAudio(operation: String, status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .deviceUnavailable:
            return "That audio output is no longer available. Reconnect it and choose it again."
        case .selectionUnavailable:
            return "macOS does not currently allow changing the audio output."
        case let .coreAudio(operation, status):
            return "Could not \(operation) (Core Audio error \(status))."
        }
    }
}

/// Uses the Mac's regular playback output so headphones work for Voom playback
/// and meeting audio. Selecting an output never changes the microphone or the
/// separate output used for system alerts.
public enum AudioOutputDeviceCatalog {
    public static let devicesDidChangeNotification = Notification.Name("VoomAudioOutputDevicesDidChange")

    private static let observerLock = NSLock()
    nonisolated(unsafe) private static var observedSelectors = Set<AudioObjectPropertySelector>()

    public static func availableDevices() -> [AudioOutputDeviceInfo] {
        (try? outputDevices()) ?? []
    }

    public static func currentDeviceID() -> String? {
        var address = systemAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr, device != kAudioObjectUnknown else {
            return nil
        }
        return stringProperty(device: device, selector: kAudioDevicePropertyDeviceUID)
    }

    /// Resolve the persistent UID again because numeric Core Audio device IDs
    /// can change when a headset reconnects or switches Bluetooth profiles.
    public static func selectDevice(uniqueID: String) throws {
        guard let device = try outputDevices().first(where: { $0.uniqueID == uniqueID }) else {
            throw AudioOutputDeviceError.deviceUnavailable
        }

        var address = systemAddress(kAudioHardwarePropertyDefaultOutputDevice)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var isSettable: DarwinBoolean = false
        let checkStatus = AudioObjectIsPropertySettable(system, &address, &isSettable)
        guard checkStatus == noErr else {
            throw AudioOutputDeviceError.coreAudio(operation: "check the audio output", status: checkStatus)
        }
        guard isSettable.boolValue else {
            throw AudioOutputDeviceError.selectionUnavailable
        }

        var id = device.audioDeviceID
        let status = AudioObjectSetPropertyData(
            system, &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id
        )
        guard status == noErr else {
            throw AudioOutputDeviceError.coreAudio(operation: "change the audio output", status: status)
        }
    }

    public static func startObservingHardwareChanges() {
        observerLock.lock()
        defer { observerLock.unlock() }

        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            guard !observedSelectors.contains(selector) else { continue }
            var address = systemAddress(selector)
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
            ) { _, _ in
                NotificationCenter.default.post(name: devicesDidChangeNotification, object: nil)
            }
            if status == noErr {
                observedSelectors.insert(selector)
            }
        }
    }

    private static func outputDevices() throws -> [AudioOutputDeviceInfo] {
        var seen = Set<String>()
        return try allDeviceIDs().compactMap { device in
            guard hasOutputChannels(device),
                  uint32Property(device: device, selector: kAudioDevicePropertyDeviceIsAlive) != 0,
                  let uid = stringProperty(device: device, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(device: device, selector: kAudioDevicePropertyDeviceNameCFString),
                  seen.insert(uid).inserted else {
                return nil
            }
            let transport = uint32Property(device: device, selector: kAudioDevicePropertyTransportType)
            let isVirtual = transport == kAudioDeviceTransportTypeVirtual
                || transport == kAudioDeviceTransportTypeAggregate
            guard !(isVirtual && uid.hasPrefix("com.loom.desktop.audio-device.")) else { return nil }
            return AudioOutputDeviceInfo(
                uniqueID: uid,
                audioDeviceID: device,
                localizedName: name,
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                    || transport == kAudioDeviceTransportTypeBluetoothLE,
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn
            )
        }
    }

    private static func allDeviceIDs() throws -> [AudioDeviceID] {
        var address = systemAddress(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard sizeStatus == noErr else {
            throw AudioOutputDeviceError.coreAudio(operation: "list audio outputs", status: sizeStatus)
        }
        guard size > 0 else { return [] }

        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices)
        guard status == noErr else {
            throw AudioOutputDeviceError.coreAudio(operation: "list audio outputs", status: status)
        }
        return Array(devices.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    /// Streams can exist without usable channels, particularly on virtual and
    /// Bluetooth devices. Only offer devices with an actual output channel.
    private static func hasOutputChannels(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else {
            return false
        }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else {
            return false
        }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func uint32Property(device: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32 {
        var address = systemAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return value
    }

    private static func stringProperty(device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = systemAddress(selector)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func systemAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
