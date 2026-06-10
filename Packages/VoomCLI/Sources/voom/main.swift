import Foundation
import ScreenCaptureKit
import VoomCore
import VoomApp

// MARK: - Output helpers

func emit<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(value), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

func emitError(_ message: String, code: Int32 = 1) -> Never {
    let data = (try? JSONEncoder().encode(["error": message])) ?? Data()
    FileHandle.standardError.write(data)
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    exit(code)
}

func note(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

func flag(_ name: String, in args: [String]) -> Bool { args.contains(name) }

func value(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

// MARK: - DTOs

struct DisplayInfo: Codable { let id: UInt32; let width: Int; let height: Int }
struct WindowInfo: Codable { let id: UInt32; let app: String?; let title: String? }
struct TargetsOut: Codable { let displays: [DisplayInfo]; let windows: [WindowInfo] }
struct RecordOut: Codable { let id: String?; let title: String?; let path: String? }

// MARK: - Commands

func cmdTargets() async {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displays = content.displays.map { DisplayInfo(id: $0.displayID, width: $0.width, height: $0.height) }
        let windows = content.windows
            .filter { ($0.title?.isEmpty == false) }
            .map { WindowInfo(id: $0.windowID, app: $0.owningApplication?.applicationName, title: $0.title) }
        emit(TargetsOut(displays: displays, windows: windows))
    } catch {
        emitError("Couldn't read capture targets: \(error.localizedDescription). Grant Screen Recording permission in System Settings → Privacy & Security.")
    }
}

func cmdList() async {
    let recordings: [Recording] = await MainActor.run {
        RecordingStore.shared.load()
        return RecordingStore.shared.recordings
    }
    emit(recordings)
}

func cmdRecord(_ args: [String]) async {
    let micEnabled = flag("--mic", in: args)
    let systemAudioEnabled = flag("--system-audio", in: args)
    let displaySel = value("--display", in: args)
    let duration = value("--duration", in: args).flatMap { Double($0) }

    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard !content.displays.isEmpty else { emitError("No displays available.") }

        let display: SCDisplay
        if let sel = displaySel {
            if let id = UInt32(sel), let match = content.displays.first(where: { $0.displayID == id }) {
                display = match
            } else if let idx = Int(sel), idx >= 0, idx < content.displays.count {
                display = content.displays[idx]
            } else {
                emitError("No display matching '\(sel)'. Run `voom targets` to list displays.")
            }
        } else {
            display = content.displays[0]
        }

        let provider = await MainActor.run { CLIStateProvider() }
        let recorder = ScreenRecorder(stateProvider: provider)
        try await recorder.startRecording(
            display: display,
            cameraEnabled: false,
            micEnabled: micEnabled,
            systemAudioEnabled: systemAudioEnabled,
            pipPosition: .bottomRight
        )

        if let duration {
            note("Recording for \(Int(duration))s…")
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        } else {
            note("Recording… press Ctrl-C to stop.")
            await waitForInterrupt()
        }

        let id = try await recorder.stopRecording()
        let recording: Recording? = await MainActor.run {
            RecordingStore.shared.load()
            if let id { return RecordingStore.shared.recording(for: id) }
            return nil
        }
        emit(RecordOut(id: id?.uuidString, title: recording?.title, path: recording?.fileURL.path))
    } catch {
        emitError("Recording failed: \(error.localizedDescription). Grant Screen Recording permission in System Settings → Privacy & Security.")
    }
}

func cmdGuide(json: Bool) {
    struct Cmd: Codable { let name: String; let usage: String; let summary: String }
    let commands = [
        Cmd(name: "targets", usage: "voom targets", summary: "List capturable displays and windows as JSON."),
        Cmd(name: "record", usage: "voom record [--display <id|index>] [--mic] [--system-audio] [--duration <seconds>]",
            summary: "Record the screen to your Voom library. Stops on Ctrl-C (or after --duration)."),
        Cmd(name: "list", usage: "voom list", summary: "List recordings in your Voom library as JSON."),
        Cmd(name: "guide", usage: "voom guide [--json]", summary: "Describe every command (machine-readable with --json)."),
    ]
    if json {
        struct Guide: Codable { let app: String; let commands: [Cmd] }
        emit(Guide(app: "voom", commands: commands))
    } else {
        print("voom — Voom screen recording from the command line\n")
        for c in commands { print("  \(c.usage)\n      \(c.summary)") }
        print("\nPass --json to any command for machine-readable output.")
    }
}

// MARK: - Helpers

/// Park until SIGINT, then return so the caller can finalize the recording.
func waitForInterrupt() async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        src.setEventHandler { [src] in
            _ = src // retain the source until it fires
            cont.resume()
        }
        src.resume()
    }
}

// MARK: - Entry

let allArgs = Array(CommandLine.arguments.dropFirst())
let jsonFlag = flag("--json", in: allArgs)
let positional = allArgs.filter { $0 != "--json" }
let command = positional.first ?? "guide"

switch command {
case "targets":
    await cmdTargets()
case "list":
    await cmdList()
case "record":
    await cmdRecord(Array(positional.dropFirst()))
case "guide":
    cmdGuide(json: jsonFlag)
case "help", "--help", "-h":
    cmdGuide(json: false)
default:
    emitError("Unknown command '\(command)'. Run `voom guide` to see commands.")
}
