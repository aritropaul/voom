import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import os

private let micLogger = Logger(subsystem: "com.voom.app", category: "MicCapture")

struct MicCaptureDeviceIdentity {
    let uniqueID: String
    let localizedName: String
    let isBluetooth: Bool
}

enum MicAudioDevices {
    static func availableCaptureDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.filter { $0.isConnected && $0.hasMediaType(.audio) }
    }

    static func captureDevice(
        preferredID: String?,
        preferredName: String?,
        allowBluetoothNameMatch: Bool = false
    ) -> AVCaptureDevice? {
        let devices = availableCaptureDevices()

        // A Core Audio input can become available before the discovery session
        // publishes its update. Resolve its exact UID without changing defaults.
        if let preferredID, let direct = AVCaptureDevice(uniqueID: preferredID),
           direct.isConnected, direct.hasMediaType(.audio) {
            return direct
        }

        if preferredID == nil && preferredName == nil {
            return AVCaptureDevice.default(for: .audio)
        }

        let identities = devices.map { device in
            let transport = UInt32(bitPattern: device.transportType)
            return MicCaptureDeviceIdentity(
                uniqueID: device.uniqueID,
                localizedName: device.localizedName,
                isBluetooth: transport == kAudioDeviceTransportTypeBluetooth
                    || transport == kAudioDeviceTransportTypeBluetoothLE
            )
        }
        guard let id = matchingDeviceID(
            preferredID: preferredID,
            preferredName: preferredName,
            allowBluetoothNameMatch: allowBluetoothNameMatch,
            devices: identities
        ) else { return nil }
        return devices.first { $0.uniqueID == id }
    }

    /// Only a dormant Bluetooth output profile may match its input by name.
    /// Substring matches and ambiguous names could record the wrong microphone.
    static func matchingDeviceID(
        preferredID: String?,
        preferredName: String?,
        allowBluetoothNameMatch: Bool,
        devices: [MicCaptureDeviceIdentity]
    ) -> String? {
        if let preferredID, let match = devices.first(where: { $0.uniqueID == preferredID }) {
            return match.uniqueID
        }
        if allowBluetoothNameMatch, let preferredID,
           let inputUID = BluetoothAudioProfile.inputUID(forOutputUID: preferredID) {
            // A known hardware UID is stronger evidence than a display name.
            // If its input is disconnected, another same-named headset is wrong.
            return devices.first { $0.isBluetooth && $0.uniqueID == inputUID }?.uniqueID
        }
        guard allowBluetoothNameMatch, let preferredName, !preferredName.isEmpty else { return nil }
        let matches = devices.filter {
            $0.isBluetooth && $0.localizedName.caseInsensitiveCompare(preferredName) == .orderedSame
        }
        return matches.count == 1 ? matches.first?.uniqueID : nil
    }
}

final class MicAudioDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let handler: @Sendable (CMSampleBuffer) -> Void
    let beautifier: VoiceBeautifier?
    private let converter = MicPCMConverter()
    private var didLogSample = false

    init(beautifier: VoiceBeautifier?, handler: @escaping @Sendable (CMSampleBuffer) -> Void) {
        self.beautifier = beautifier
        self.handler = handler
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard sampleBuffer.isValid else { return }
        if !didLogSample {
            didLogSample = true
            micLogger.notice("First microphone sample received")
        }
        if let beautifier, let polished = MicPCM.polish(sampleBuffer, beautifier: beautifier, converter: converter) {
            handler(polished)
        } else {
            handler(sampleBuffer)
        }
    }
}

extension MicPCM {
    static func polish(_ input: CMSampleBuffer, beautifier: VoiceBeautifier, converter: MicPCMConverter) -> CMSampleBuffer? {
        guard let unpacked = extract(input) else { return nil }
        guard var mono = converter.mono48k(
            floats: unpacked.floats, channels: unpacked.channels, sampleRate: unpacked.sampleRate
        ) else { return nil }
        guard !mono.isEmpty else { return nil }
        beautifier.process(&mono)
        return sampleBuffer(
            floats: mono,
            sampleRate: targetSampleRate,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(input)
        )
    }

    static func extract(_ sampleBuffer: CMSampleBuffer) -> (floats: [Float], channels: Int, sampleRate: Double)? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        ) == noErr, let data = dataPointer, length > 0 else {
            return nil
        }

        let channels = max(Int(asbd.pointee.mChannelsPerFrame), 1)
        let sampleRate = asbd.pointee.mSampleRate
        if asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let count = length / MemoryLayout<Float>.size
            let floats = data.withMemoryRebound(to: Float.self, capacity: count) { Array(UnsafeBufferPointer(start: $0, count: count)) }
            return (floats, channels, sampleRate)
        }
        if asbd.pointee.mBitsPerChannel == 16 {
            let count = length / MemoryLayout<Int16>.size
            var floats = [Float](repeating: 0, count: count)
            data.withMemoryRebound(to: Int16.self, capacity: count) { ptr in
                for i in 0..<count {
                    floats[i] = Float(ptr[i]) / Float(Int16.max)
                }
            }
            return (floats, channels, sampleRate)
        }
        return nil
    }

    static func sampleBuffer(floats: [Float], sampleRate: Double, presentationTime: CMTime) -> CMSampleBuffer? {
        let frameCount = floats.count
        guard frameCount > 0 else { return nil }
        let dataSize = frameCount * MemoryLayout<Float>.size

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let block = blockBuffer else { return nil }

        guard floats.withUnsafeBytes({ bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: dataSize
            )
        }) == noErr else { return nil }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let fmtDesc = formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = MemoryLayout<Float>.size
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmtDesc,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }
}
