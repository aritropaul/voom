import Testing
@testable import VoomCore

struct CameraDeviceCatalogTests {
    private let continuity = CameraDeviceInfo(
        uniqueID: "iphone",
        localizedName: "iPhone Camera",
        isBuiltIn: false,
        isContinuityCamera: true
    )
    private let builtIn = CameraDeviceInfo(
        uniqueID: "facetime",
        localizedName: "FaceTime HD Camera",
        isBuiltIn: true,
        isContinuityCamera: false
    )
    private let usb = CameraDeviceInfo(
        uniqueID: "logitech",
        localizedName: "Logitech Webcam",
        isBuiltIn: false,
        isContinuityCamera: false
    )

    @Test func prefersBuiltInOverContinuityWhenNothingSelected() {
        let resolved = CameraDeviceCatalog.resolve(
            preferredID: nil,
            devices: [continuity, builtIn, usb]
        )
        #expect(resolved?.uniqueID == "facetime")
    }

    @Test func honorsExplicitSelection() {
        let resolved = CameraDeviceCatalog.resolve(
            preferredID: "logitech",
            devices: [continuity, builtIn, usb]
        )
        #expect(resolved?.uniqueID == "logitech")
    }

    @Test func fallsBackWhenPreferredCameraIsGone() {
        let resolved = CameraDeviceCatalog.resolve(
            preferredID: "missing",
            devices: [continuity, usb]
        )
        #expect(resolved?.uniqueID == "logitech")
    }

    @Test func triesPreferredThenBuiltInThenExternalThenContinuity() {
        let order = CameraDeviceCatalog.devicesInPreferenceOrder(
            preferredID: "iphone",
            devices: [continuity, usb, builtIn]
        ).map(\.uniqueID)
        #expect(order == ["iphone", "facetime", "logitech"])
    }
}
