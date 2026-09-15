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

    public static let selectedCameraDeviceIDKey = "SelectedCameraDeviceID"
    public static let selectedMicrophoneDeviceIDKey = "SelectedMicrophoneDeviceID"
    public static let voiceEnhanceKey = "VoiceStudio"

    public static var voiceEnhanceEnabled: Bool {
        UserDefaults.standard.object(forKey: voiceEnhanceKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: voiceEnhanceKey)
    }

    public static var selectedCameraDeviceID: String? {
        get { UserDefaults.standard.string(forKey: selectedCameraDeviceIDKey) }
        set { setOptionalString(newValue, forKey: selectedCameraDeviceIDKey) }
    }

    public static var selectedMicrophoneDeviceID: String? {
        get { UserDefaults.standard.string(forKey: selectedMicrophoneDeviceIDKey) }
        set { setOptionalString(newValue, forKey: selectedMicrophoneDeviceIDKey) }
    }

    private static func setOptionalString(_ value: String?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
