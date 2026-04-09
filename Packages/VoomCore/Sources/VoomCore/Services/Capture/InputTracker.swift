import Foundation
import CoreGraphics
import AppKit

// MARK: - Cursor Event

public struct CursorEvent: Codable, Sendable {
    public let timestamp: TimeInterval  // relative to recording start
    public let x: Double
    public let y: Double
    public let eventType: EventType

    public enum EventType: String, Codable, Sendable {
        case move
        case leftClick
        case rightClick
    }

    public init(timestamp: TimeInterval, x: Double, y: Double, eventType: EventType) {
        self.timestamp = timestamp
        self.x = x
        self.y = y
        self.eventType = eventType
    }
}

// MARK: - Sendable Box

/// Wraps a non-Sendable value for safe transfer across isolation boundaries
/// when the developer guarantees no concurrent access.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

// MARK: - Shared Callback State

/// State shared between the actor and the CGEvent tap C callback.
/// Access is guarded by an NSLock since the callback runs on an arbitrary thread.
private final class InputTrackerCallbackState: @unchecked Sendable {
    let lock = NSLock()
    var events: [CursorEvent] = []
    var startTime: Date?
    var isTracking = false

    func append(_ event: CursorEvent) {
        lock.withLock { events.append(event) }
    }

    func drainEvents() -> [CursorEvent] {
        lock.withLock {
            let captured = events
            events = []
            return captured
        }
    }
}

// MARK: - C Callback

/// CGEvent tap callback — must be a plain C function pointer (no captures).
/// The `refcon` carries our shared state.
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let state = Unmanaged<InputTrackerCallbackState>.fromOpaque(refcon).takeUnretainedValue()

    guard state.lock.withLock({ state.isTracking }) else {
        return Unmanaged.passUnretained(event)
    }

    let cursorType: CursorEvent.EventType
    switch type {
    case .leftMouseDown:
        cursorType = .leftClick
    case .rightMouseDown:
        cursorType = .rightClick
    default:
        return Unmanaged.passUnretained(event)
    }

    let startTime = state.lock.withLock { state.startTime } ?? Date()
    let location = event.location
    let cursorEvent = CursorEvent(
        timestamp: Date().timeIntervalSince(startTime),
        x: location.x,
        y: location.y,
        eventType: cursorType
    )
    state.append(cursorEvent)

    return Unmanaged.passUnretained(event)
}

// MARK: - Input Tracker

public actor InputTracker {
    public static let shared = InputTracker()
    private init() {}

    /// Shared state accessed from both the actor and the CGEvent tap callback.
    private let callbackState = InputTrackerCallbackState()

    private var isTracking = false
    private var positionTimer: Timer?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: - Start / Stop

    public func startTracking() {
        guard !isTracking else { return }
        isTracking = true

        callbackState.lock.withLock {
            callbackState.events = []
            callbackState.startTime = Date()
            callbackState.isTracking = true
        }

        // 10 Hz position polling — Timer needs a RunLoop, so schedule on main
        Task { @MainActor [callbackState] in
            let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                let location = NSEvent.mouseLocation
                let startTime = callbackState.lock.withLock { callbackState.startTime } ?? Date()
                let event = CursorEvent(
                    timestamp: Date().timeIntervalSince(startTime),
                    x: location.x,
                    y: location.y,
                    eventType: .move
                )
                callbackState.append(event)
            }
            RunLoop.main.add(timer, forMode: .common)
            await self.storeTimer(timer)
        }

        setupEventTap()
    }

    public func stopTracking() -> [CursorEvent] {
        guard isTracking else { return [] }
        isTracking = false

        callbackState.lock.withLock {
            callbackState.isTracking = false
        }

        // Invalidate timer on main thread
        if let timer = positionTimer {
            positionTimer = nil
            let sendableTimer = UncheckedSendableBox(timer)
            Task { @MainActor in sendableTimer.value.invalidate() }
        }

        teardownEventTap()

        let captured = callbackState.drainEvents()
        callbackState.lock.withLock {
            callbackState.startTime = nil
        }
        return captured
    }

    // MARK: - Persistence

    /// Write cursor events to a JSON sidecar file alongside the recording.
    public func writeEvents(_ events: [CursorEvent], sidecarURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(events)
        try data.write(to: sidecarURL, options: .atomic)
    }

    /// Read cursor events from a previously saved sidecar file.
    public func readEvents(from sidecarURL: URL) throws -> [CursorEvent] {
        let data = try Data(contentsOf: sidecarURL)
        return try JSONDecoder().decode([CursorEvent].self, from: data)
    }

    // MARK: - Private Helpers

    private func storeTimer(_ timer: Timer) {
        positionTimer = timer
    }

    // MARK: - CGEvent Tap

    private func setupEventTap() {
        let eventsOfInterest: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)

        let refcon = Unmanaged.passUnretained(callbackState).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventsOfInterest,
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            return
        }

        eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func teardownEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        eventTap = nil
    }
}
