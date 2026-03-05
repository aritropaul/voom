import Carbon.HIToolbox
import AppKit

/// Registers Cmd+Shift+R as a global keyboard shortcut to toggle recording.
@MainActor
public final class GlobalHotkey {
    public static let shared = GlobalHotkey()

    private var eventHandler: EventHandlerRef?
    private var hotkeyRef: EventHotKeyRef?

    private init() {}

    public func register() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerRef = UnsafeMutablePointer<EventHandlerRef?>.allocate(capacity: 1)

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                Task { @MainActor in
                    NotificationCenter.default.post(name: .toggleRecordingFromHotkey, object: nil)
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            handlerRef
        )

        guard status == noErr else {
            handlerRef.deallocate()
            return
        }
        eventHandler = handlerRef.pointee
        handlerRef.deallocate()

        let hotkeyID = EventHotKeyID(signature: OSType(0x766F6F6D), id: 1) // "voom"
        var hotkey: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(cmdKey | shiftKey),
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkey
        )
        hotkeyRef = hotkey
    }

    public func unregister() {
        if let hotkey = hotkeyRef {
            UnregisterEventHotKey(hotkey)
            hotkeyRef = nil
        }
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
    }
}

// MARK: - Notification Names

public extension Notification.Name {
    static let toggleRecordingFromHotkey = Notification.Name("toggleRecordingFromHotkey")
    static let startRecordingFromMeeting = Notification.Name("startRecordingFromMeeting")
    static let autoStopMeetingRecording = Notification.Name("autoStopMeetingRecording")
}
