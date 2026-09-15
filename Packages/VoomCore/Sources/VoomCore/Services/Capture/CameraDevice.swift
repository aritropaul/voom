import AVFoundation
import Foundation

public struct CameraDeviceInfo: Identifiable, Sendable, Equatable, Hashable {
    public var id: String { uniqueID }
    public let uniqueID: String
    public let localizedName: String
    public let isBuiltIn: Bool
    public let isContinuityCamera: Bool

    public init(
        uniqueID: String,
        localizedName: String,
        isBuiltIn: Bool,
        isContinuityCamera: Bool
    ) {
        self.uniqueID = uniqueID
        self.localizedName = localizedName
        self.isBuiltIn = isBuiltIn
        self.isContinuityCamera = isContinuityCamera
    }

    public init(device: AVCaptureDevice) {
        self.uniqueID = device.uniqueID
        self.localizedName = device.localizedName
        self.isBuiltIn = device.deviceType == .builtInWideAngleCamera
        self.isContinuityCamera = device.isContinuityCamera
    }
}

/// Lists connected cameras and prefers a stable local device over Continuity Camera.
public enum CameraDeviceCatalog {
    public static func availableDevices() -> [CameraDeviceInfo] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .external,
                .continuityCamera,
                .deskViewCamera,
            ],
            mediaType: .video,
            position: .unspecified
        )

        var seen = Set<String>()
        var devices: [CameraDeviceInfo] = []
        for device in session.devices {
            guard seen.insert(device.uniqueID).inserted else { continue }
            devices.append(CameraDeviceInfo(device: device))
        }

        if devices.isEmpty, let fallback = AVCaptureDevice.default(for: .video) {
            devices = [CameraDeviceInfo(device: fallback)]
        }
        return devices
    }

    public static func devicesInPreferenceOrder(
        preferredID: String?,
        devices: [CameraDeviceInfo]
    ) -> [CameraDeviceInfo] {
        var remaining = devices
        var ordered: [CameraDeviceInfo] = []

        if let preferredID, let index = remaining.firstIndex(where: { $0.uniqueID == preferredID }) {
            ordered.append(remaining.remove(at: index))
        }

        let builtIn = remaining.filter(\.isBuiltIn)
        remaining.removeAll(where: \.isBuiltIn)
        ordered.append(contentsOf: builtIn)

        let external = remaining.filter { !$0.isContinuityCamera }
        remaining.removeAll { !$0.isContinuityCamera }
        ordered.append(contentsOf: external)
        ordered.append(contentsOf: remaining)
        return ordered
    }

    public static func resolve(
        preferredID: String?,
        devices: [CameraDeviceInfo]
    ) -> CameraDeviceInfo? {
        devicesInPreferenceOrder(preferredID: preferredID, devices: devices).first
    }
}
