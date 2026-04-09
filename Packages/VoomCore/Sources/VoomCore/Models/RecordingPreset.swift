import Foundation

public struct RecordingPreset: Codable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var recordingMode: RecordingMode
    public var isCameraEnabled: Bool
    public var isMicEnabled: Bool
    public var isSystemAudioEnabled: Bool
    public var pipPosition: PiPPosition

    public init(
        name: String,
        recordingMode: RecordingMode,
        isCameraEnabled: Bool,
        isMicEnabled: Bool,
        isSystemAudioEnabled: Bool,
        pipPosition: PiPPosition
    ) {
        self.id = UUID()
        self.name = name
        self.recordingMode = recordingMode
        self.isCameraEnabled = isCameraEnabled
        self.isMicEnabled = isMicEnabled
        self.isSystemAudioEnabled = isSystemAudioEnabled
        self.pipPosition = pipPosition
    }
}
