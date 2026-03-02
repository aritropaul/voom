import Carbon.HIToolbox
import AppKit

/// Registers Cmd+Shift+R as a global keyboard shortcut to toggle recording.
@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()

    private var eventHandler: EventHandlerRef?
    private var hotkeyRef: EventHotKeyRef?

    private init() {}

    func register() {
        guard eventHandler == nil else { return }

        // Install Carbon event handler
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

        // Register Cmd+Shift+R
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

    func unregister() {
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

extension Notification.Name {
    static let toggleRecordingFromHotkey = Notification.Name("toggleRecordingFromHotkey")
}
