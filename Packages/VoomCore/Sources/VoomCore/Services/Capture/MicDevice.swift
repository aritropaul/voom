import CoreAudio
import AVFoundation
import Foundation

public struct MicDeviceInfo: Identifiable, Sendable, Equatable, Hashable {
    public var id: String { uniqueID }
    public let uniqueID: String
    public let audioDeviceID: UInt32
    public let localizedName: String
    public let isBuiltIn: Bool
    public let isBluetooth: Bool
    public let isVirtual: Bool
    public let hasInput: Bool
    /// Alternate IDs exposed by the same Bluetooth headset's output profile.
    public let relatedUniqueIDs: [String]

    public init(
        uniqueID: String,
        audioDeviceID: UInt32,
        localizedName: String,
        isBuiltIn: Bool,
        isBluetooth: Bool,
        isVirtual: Bool,
        hasInput: Bool = true,
        relatedUniqueIDs: [String] = []
    ) {
        self.uniqueID = uniqueID
        self.audioDeviceID = audioDeviceID
        self.localizedName = localizedName
        self.isBuiltIn = isBuiltIn
        self.isBluetooth = isBluetooth
        self.isVirtual = isVirtual
        self.hasInput = hasInput
        self.relatedUniqueIDs = relatedUniqueIDs
    }

    public var menuLabel: String {
        return localizedName
    }

    func matches(uniqueID: String) -> Bool {
        self.uniqueID == uniqueID || relatedUniqueIDs.contains(uniqueID)
            || (isBluetooth && hasInput && BluetoothAudioProfile.inputUID(forOutputUID: uniqueID) == self.uniqueID)
    }
}

/// Core Audio exposes AirPods input and output profiles under the same hardware
/// UID, with distinct direction suffixes. Keep saved selections across changes
/// in which profile is published, including headsets with the same display name.
enum BluetoothAudioProfile {
    static func inputUID(forOutputUID uid: String) -> String? {
        guard uid.hasSuffix(":output") else { return nil }
        return String(uid.dropLast(":output".count)) + ":input"
    }
}

/// Lists input devices, including Bluetooth headsets whose mic is inactive
/// until something actually opens it (AirPods Max on macOS).
public enum MicDeviceCatalog {
    public static let devicesDidChangeNotification = Notification.Name("VoomMicDevicesDidChange")

    private static let observerLock = NSLock()
    nonisolated(unsafe) private static var isObserving = false
    nonisolated(unsafe) private static var captureObservers: [NSObjectProtocol] = []
    nonisolated(unsafe) private static var observedDeviceIDs = Set<AudioDeviceID>()
    private static let devicePropertyListener: @Sendable (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void = { _, _ in
        NotificationCenter.default.post(name: devicesDidChangeNotification, object: nil)
    }

    public static func availableDevices() -> [MicDeviceInfo] {
        var seen = Set<String>()
        var devices: [MicDeviceInfo] = []
        for device in allDeviceIDs() {
            guard var info = info(for: device), !isHidden(info) else { continue }
            let hasMic = info.hasInput
            let bluetoothHeadset = info.isBluetooth
                && hasChannels(device, scope: kAudioDevicePropertyScopeOutput)
                && isPotentialBluetoothHeadset(
                    name: info.localizedName,
                    modelID: stringProperty(device: device, selector: kAudioDevicePropertyModelUID)
                )
            guard hasMic || bluetoothHeadset else { continue }
            guard seen.insert(info.uniqueID).inserted else { continue }
            info = MicDeviceInfo(
                uniqueID: info.uniqueID,
                audioDeviceID: info.audioDeviceID,
                localizedName: info.localizedName,
                isBuiltIn: info.isBuiltIn,
                isBluetooth: info.isBluetooth,
                isVirtual: info.isVirtual,
                hasInput: hasMic
            )
            devices.append(info)
        }
        let captureDevices = MicAudioDevices.availableCaptureDevices().map { device in
            let transport = UInt32(bitPattern: device.transportType)
            return MicDeviceInfo(
                uniqueID: device.uniqueID,
                audioDeviceID: 0,
                localizedName: device.localizedName,
                isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                    || transport == kAudioDeviceTransportTypeBluetoothLE,
                isVirtual: transport == kAudioDeviceTransportTypeVirtual
                    || transport == kAudioDeviceTransportTypeAggregate
            )
        }
        return mergedDevices(coreAudio: devices, capture: captureDevices)
    }

    /// Both APIs publish asynchronously when a headset connects or changes audio
    /// profile. Keep every advertised capture input, including unknown brands.
    static func mergedDevices(coreAudio: [MicDeviceInfo], capture: [MicDeviceInfo]) -> [MicDeviceInfo] {
        var devices = coreAudio.filter { !isHidden($0) }
        for device in capture where !isHidden(device) {
            if let index = devices.firstIndex(where: { $0.uniqueID == device.uniqueID }) {
                let hardware = devices[index]
                devices[index] = MicDeviceInfo(
                    uniqueID: device.uniqueID,
                    audioDeviceID: hardware.audioDeviceID,
                    localizedName: device.localizedName,
                    isBuiltIn: hardware.isBuiltIn || device.isBuiltIn,
                    isBluetooth: hardware.isBluetooth || device.isBluetooth,
                    isVirtual: hardware.isVirtual || device.isVirtual,
                    hasInput: true,
                    relatedUniqueIDs: hardware.relatedUniqueIDs
                )
            } else {
                devices.append(device)
            }
        }
        return deduplicated(devices)
    }

    /// Collapse an unambiguous Bluetooth input/output pair, retaining the output
    /// ID so a selection made before the headset mic activates still resolves.
    public static func deduplicated(_ devices: [MicDeviceInfo]) -> [MicDeviceInfo] {
        var seen = Set<String>()
        let devices = devices.filter { seen.insert($0.uniqueID).inserted }
        var result: [MicDeviceInfo] = []
        for device in devices {
            guard device.isBluetooth else {
                result.append(device)
                continue
            }
            let hardwarePeers = devices.filter { peer in
                guard peer.isBluetooth else { return false }
                if device.hasInput {
                    return BluetoothAudioProfile.inputUID(forOutputUID: peer.uniqueID) == device.uniqueID
                }
                return peer.hasInput
                    && BluetoothAudioProfile.inputUID(forOutputUID: device.uniqueID) == peer.uniqueID
            }
            let namePeers = devices.filter {
                $0.isBluetooth && $0.localizedName.caseInsensitiveCompare(device.localizedName) == .orderedSame
            }
            let peers = hardwarePeers.isEmpty ? namePeers : [device] + hardwarePeers
            let inputs = peers.filter(\.hasInput)
            // A shared display name alone cannot distinguish multiple microphones.
            guard peers.count == 2, inputs.count == 1, let input = inputs.first else {
                result.append(device)
                continue
            }
            // A known profile UID must never be paired with another headset
            // merely because both happen to have the same display name.
            let outputs = peers.filter { !$0.hasInput }
            if let output = outputs.first,
               let inputUID = BluetoothAudioProfile.inputUID(forOutputUID: output.uniqueID),
               inputUID != input.uniqueID {
                result.append(device)
                continue
            }
            guard !result.contains(where: { $0.uniqueID == input.uniqueID }) else { continue }
            let aliases = Set(input.relatedUniqueIDs + outputs.map(\.uniqueID))
            result.append(MicDeviceInfo(
                uniqueID: input.uniqueID,
                audioDeviceID: input.audioDeviceID,
                localizedName: input.localizedName,
                isBuiltIn: input.isBuiltIn,
                isBluetooth: input.isBluetooth,
                isVirtual: input.isVirtual,
                hasInput: true,
                relatedUniqueIDs: aliases.sorted()
            ))
        }
        return result
    }

    /// A Bluetooth output by itself is not evidence that a speaker has a mic.
    /// Retain recognizable dormant headset profiles; all actual inputs are listed.
    static func isPotentialBluetoothHeadset(name: String, modelID: String?) -> Bool {
        [name, modelID ?? ""].contains { description in
            ["AirPods", "Headset", "Headphones"].contains {
                description.localizedCaseInsensitiveContains($0)
            }
        }
    }

    public static func devicesInPreferenceOrder(
        preferredID: String?,
        devices: [MicDeviceInfo]
    ) -> [MicDeviceInfo] {
        var remaining = devices
        var ordered: [MicDeviceInfo] = []

        if let preferredID, let index = remaining.firstIndex(where: { $0.matches(uniqueID: preferredID) }) {
            ordered.append(remaining.remove(at: index))
        }

        let builtIn = remaining.filter(\.isBuiltIn)
        remaining.removeAll(where: \.isBuiltIn)
        ordered.append(contentsOf: builtIn)

        let wired = remaining.filter { !$0.isBluetooth && !$0.isVirtual }
        remaining.removeAll { !$0.isBluetooth && !$0.isVirtual }
        ordered.append(contentsOf: wired)

        let virtual = remaining.filter(\.isVirtual)
        remaining.removeAll(where: \.isVirtual)
        ordered.append(contentsOf: virtual)
        ordered.append(contentsOf: remaining)
        return ordered
    }

    public static func resolve(
        preferredID: String?,
        devices: [MicDeviceInfo]
    ) -> MicDeviceInfo? {
        devicesInPreferenceOrder(preferredID: preferredID, devices: devices).first
    }

    /// Explicit choices never switch to another microphone. Automatic selection
    /// prefers a built-in or wired input, avoiding Bluetooth's call-audio profile.
    public static func recordingDevice(
        preferredID: String?,
        devices: [MicDeviceInfo]
    ) -> MicDeviceInfo? {
        if let preferredID {
            return devices.first(where: { $0.matches(uniqueID: preferredID) })
        }
        return devicesInPreferenceOrder(preferredID: nil, devices: devices.filter(\.hasInput)).first
    }

    public static func startObservingHardwareChanges() {
        observerLock.lock()
        guard !isObserving else { observerLock.unlock(); return }
        isObserving = true
        observerLock.unlock()

        let tokens = [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { notification in
                guard let device = notification.object as? AVCaptureDevice, device.hasMediaType(.audio) else { return }
                refreshDevicePropertyObservers()
                NotificationCenter.default.post(name: devicesDidChangeNotification, object: nil)
            }
        }
        observerLock.lock()
        captureObservers = tokens
        observerLock.unlock()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { _, _ in
            refreshDevicePropertyObservers()
            NotificationCenter.default.post(name: devicesDidChangeNotification, object: nil)
        }
        refreshDevicePropertyObservers()
    }

    private static func isHidden(_ device: MicDeviceInfo) -> Bool {
        // The Loom loopback is not a physical mic. Do not hide a real headset
        // because its user-editable name contains "Loom" or "inactive".
        device.isVirtual && device.uniqueID.hasPrefix("com.loom.desktop.audio-device.")
    }

    private static func refreshDevicePropertyObservers() {
        let currentIDs = Set(allDeviceIDs())
        observerLock.lock()
        defer { observerLock.unlock() }
        let removed = observedDeviceIDs.subtracting(currentIDs)
        let added = currentIDs.subtracting(observedDeviceIDs)
        for device in removed {
            for var address in deviceChangeAddresses() {
                AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, devicePropertyListener)
            }
        }
        for device in added {
            for var address in deviceChangeAddresses() {
                AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, devicePropertyListener)
            }
        }
        observedDeviceIDs = currentIDs
    }

    private static func deviceChangeAddresses() -> [AudioObjectPropertyAddress] {
        let streamAddresses = [kAudioDevicePropertyStreams, kAudioDevicePropertyStreamConfiguration].flatMap { selector in
            [kAudioDevicePropertyScopeInput, kAudioDevicePropertyScopeOutput].map { scope in
                AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            }
        }
        return streamAddresses + [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyDeviceNameCFString].map { selector in
            AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func hasChannels(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioBufferList>.size else { return false }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &dataSize, storage) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func info(for device: AudioDeviceID) -> MicDeviceInfo? {
        var aliveAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 1
        var aliveSize = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &aliveAddress, 0, nil, &aliveSize, &alive) == noErr && alive == 0 {
            return nil
        }
        guard let uid = stringProperty(device: device, selector: kAudioDevicePropertyDeviceUID),
              let name = stringProperty(device: device, selector: kAudioDevicePropertyDeviceNameCFString) else {
            return nil
        }

        let transport = transportType(device)
        let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
        let isBuiltIn = transport == kAudioDeviceTransportTypeBuiltIn
        let isVirtual = transport == kAudioDeviceTransportTypeVirtual
            || transport == kAudioDeviceTransportTypeAggregate

        return MicDeviceInfo(
            uniqueID: uid,
            audioDeviceID: device,
            localizedName: name,
            isBuiltIn: isBuiltIn,
            isBluetooth: isBluetooth,
            isVirtual: isVirtual,
            hasInput: hasChannels(device, scope: kAudioDevicePropertyScopeInput)
        )
    }

    private static func transportType(_ device: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return value
    }

    private static func stringProperty(device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
