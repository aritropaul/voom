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
}
