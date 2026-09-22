import Foundation

/// Shared accessors for cross-package UserDefaults preferences. Keys that more
/// than one module reads belong here so the key string and default value have
/// exactly one definition.
public enum AppDefaults {
    /// Auto-transcribe new recordings (defaults to on when never set).
    public static var autoTranscribeEnabled: Bool {
        UserDefaults.standard.object(forKey: "AutoTranscribe") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "AutoTranscribe")
    }

    /// `AVCaptureDevice.uniqueID` of the camera the user chose, or nil to follow
    /// the system's pick. Stores the id rather than the name because
    /// `localizedName` is neither unique nor stable.
    public static var preferredCameraDeviceID: String? {
        get { UserDefaults.standard.string(forKey: "PreferredCameraDeviceID") }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: "PreferredCameraDeviceID")
            } else {
                UserDefaults.standard.removeObject(forKey: "PreferredCameraDeviceID")
            }
        }
    }
}
