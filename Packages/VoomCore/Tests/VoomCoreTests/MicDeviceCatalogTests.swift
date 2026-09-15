import AVFoundation
import Testing
@testable import VoomCore

struct MicDeviceCatalogTests {
    private let airPods = MicDeviceInfo(
        uniqueID: "airpods",
        audioDeviceID: 1,
        localizedName: "Vitalii’s AirPods Max",
        isBuiltIn: false,
        isBluetooth: true,
        isVirtual: false
    )
    private let builtIn = MicDeviceInfo(
        uniqueID: "macbook",
        audioDeviceID: 2,
        localizedName: "MacBook Pro Microphone",
        isBuiltIn: true,
        isBluetooth: false,
        isVirtual: false
    )
    private let usb = MicDeviceInfo(
        uniqueID: "yeti",
        audioDeviceID: 3,
        localizedName: "Yeti",
        isBuiltIn: false,
        isBluetooth: false,
        isVirtual: false
    )
    private let loopback = MicDeviceInfo(
        uniqueID: "blackhole",
        audioDeviceID: 4,
        localizedName: "BlackHole 2ch",
        isBuiltIn: false,
        isBluetooth: false,
        isVirtual: true
    )

    @Test func prefersBuiltInOverAirPodsWhenNothingSelected() {
        let resolved = MicDeviceCatalog.resolve(
            preferredID: nil,
            devices: [airPods, builtIn, usb]
        )
        #expect(resolved?.uniqueID == "macbook")
    }

    @Test func honorsExplicitAirPodsSelection() {
        let resolved = MicDeviceCatalog.resolve(
            preferredID: "airpods",
            devices: [airPods, builtIn]
        )
        #expect(resolved?.uniqueID == "airpods")
    }

    @Test func recordingHonorsAirPodsWhenMacBookExists() {
        let recording = MicDeviceCatalog.recordingDevice(
            preferredID: "airpods",
            devices: [airPods, builtIn]
        )
        #expect(recording?.uniqueID == "airpods")
    }

    @Test func recordingDoesNotReplaceDisconnectedSelectedMic() {
        #expect(MicDeviceCatalog.recordingDevice(
            preferredID: "airpods", devices: [builtIn, usb]
        ) == nil)
    }

    @Test func automaticRecordingPrefersBuiltInThenWired() {
        #expect(MicDeviceCatalog.recordingDevice(
            preferredID: nil, devices: [airPods, loopback, usb, builtIn]
        )?.uniqueID == "macbook")
        #expect(MicDeviceCatalog.recordingDevice(
            preferredID: nil, devices: [airPods, loopback, usb]
        )?.uniqueID == "yeti")
    }

    @Test func recordingHonorsExplicitVirtualInput() {
        #expect(MicDeviceCatalog.recordingDevice(
            preferredID: "blackhole", devices: [builtIn, loopback]
        )?.uniqueID == "blackhole")
    }

    @Test func dormantHeadsetIsExplicitlySelectableButNotAutomatic() {
        let dormant = MicDeviceInfo(
            uniqueID: "airpods-out", audioDeviceID: 8, localizedName: "AirPods Max",
            isBuiltIn: false, isBluetooth: true, isVirtual: false, hasInput: false
        )
        #expect(MicDeviceCatalog.recordingDevice(
            preferredID: "airpods-out", devices: [builtIn, dormant]
        )?.uniqueID == "airpods-out")
        #expect(MicDeviceCatalog.recordingDevice(preferredID: nil, devices: [dormant]) == nil)
    }

    @Test func outputOnlySpeakersAreNotAssumedToHaveMicrophones() {
        #expect(!MicDeviceCatalog.isPotentialBluetoothHeadset(name: "Living Room Speaker", modelID: nil))
        #expect(!MicDeviceCatalog.isPotentialBluetoothHeadset(name: "Beats Pill", modelID: nil))
        #expect(MicDeviceCatalog.isPotentialBluetoothHeadset(name: "AirPods Max Vitalii", modelID: nil))
        #expect(MicDeviceCatalog.isPotentialBluetoothHeadset(name: "Vitalii", modelID: "Apple AirPods Max"))
    }

    @Test func recordingKeepsWiredMic() {
        let recording = MicDeviceCatalog.recordingDevice(
            preferredID: "yeti",
            devices: [airPods, builtIn, usb]
        )
        #expect(recording?.uniqueID == "yeti")
    }

    @Test func prefersWiredOverBluetoothAndVirtual() {
        let resolved = MicDeviceCatalog.resolve(
            preferredID: nil,
            devices: [airPods, loopback, usb]
        )
        #expect(resolved?.uniqueID == "yeti")
    }

    @Test func labelsBluetoothHeadsets() {
        #expect(airPods.menuLabel == "Vitalii’s AirPods Max")
        #expect(builtIn.menuLabel == "MacBook Pro Microphone")
    }

    @Test func keepsAirPodsSelectableWhenListed() {
        let order = MicDeviceCatalog.devicesInPreferenceOrder(
            preferredID: nil,
            devices: [builtIn, airPods]
        ).map(\.uniqueID)
        #expect(order == ["macbook", "airpods"])
    }

    @Test func collapsesDuplicateAirPodsNameToTheMic() {
        let headphones = MicDeviceInfo(
            uniqueID: "airpods-out",
            audioDeviceID: 8,
            localizedName: "AirPods Max Vitalii",
            isBuiltIn: false,
            isBluetooth: true,
            isVirtual: false,
            hasInput: false
        )
        let mic = MicDeviceInfo(
            uniqueID: "airpods-in",
            audioDeviceID: 9,
            localizedName: "AirPods Max Vitalii",
            isBuiltIn: false,
            isBluetooth: true,
            isVirtual: false,
            hasInput: true
        )
        let collapsed = MicDeviceCatalog.deduplicated([headphones, mic, builtIn])
        #expect(collapsed.map(\.uniqueID) == ["airpods-in", "macbook"])
        #expect(MicDeviceCatalog.recordingDevice(
            preferredID: "airpods-out", devices: collapsed
        )?.uniqueID == "airpods-in")
    }

    @Test func identicalNamesDoNotHideDistinctInputDevices() {
        let secondUSB = MicDeviceInfo(
            uniqueID: "second-yeti", audioDeviceID: 10, localizedName: usb.localizedName,
            isBuiltIn: false, isBluetooth: false, isVirtual: false
        )
        let secondHeadset = MicDeviceInfo(
            uniqueID: "second-airpods", audioDeviceID: 11, localizedName: airPods.localizedName,
            isBuiltIn: false, isBluetooth: true, isVirtual: false
        )
        #expect(MicDeviceCatalog.deduplicated([usb, secondUSB, airPods, secondHeadset]).count == 4)
    }

    @Test func savedBluetoothOutputStillSelectsItsInputAfterOutputProfileDisappears() {
        let input = bluetoothProfile(uid: "headset-one:input", name: "AirPods Max", hasInput: true)
        #expect(MicDeviceCatalog.recordingDevice(
            preferredID: "headset-one:output", devices: [builtIn, input]
        )?.uniqueID == input.uniqueID)
    }

    @Test func pairsBluetoothProfilesByHardwareDespiteDifferentNames() {
        let output = bluetoothProfile(uid: "headset-one:output", name: "Old AirPods Name", hasInput: false)
        let input = bluetoothProfile(uid: "headset-one:input", name: "Renamed AirPods", hasInput: true)
        let devices = MicDeviceCatalog.deduplicated([output, builtIn, input])
        #expect(devices.map(\.uniqueID) == [input.uniqueID, builtIn.uniqueID])
        #expect(devices.first?.relatedUniqueIDs == [output.uniqueID])
    }

    @Test func sameNamedHeadsetsKeepTheirOwnProfilePairs() {
        let firstOutput = bluetoothProfile(uid: "headset-one:output", name: "AirPods Max", hasInput: false)
        let firstInput = bluetoothProfile(uid: "headset-one:input", name: "AirPods Max", hasInput: true)
        let secondOutput = bluetoothProfile(uid: "headset-two:output", name: "AirPods Max", hasInput: false)
        let secondInput = bluetoothProfile(uid: "headset-two:input", name: "AirPods Max", hasInput: true)
        let devices = MicDeviceCatalog.deduplicated([firstOutput, secondInput, firstInput, secondOutput])
        #expect(devices.map(\.uniqueID) == [firstInput.uniqueID, secondInput.uniqueID])
        #expect(MicDeviceCatalog.recordingDevice(
            preferredID: secondOutput.uniqueID, devices: devices
        )?.uniqueID == secondInput.uniqueID)

        let incomplete = MicDeviceCatalog.deduplicated([firstOutput, secondInput])
        #expect(incomplete.count == 2)
        #expect(MicDeviceCatalog.recordingDevice(
            preferredID: firstOutput.uniqueID, devices: incomplete
        )?.uniqueID == firstOutput.uniqueID)
    }

    @Test func includesCaptureAdvertisedHeadsetsOfAnyBrandWithoutCoreAudioEntry() {
        let headphones = bluetoothProfile(uid: "third-party-mic", name: "CMF Buds Pro 2", hasInput: true)
        let devices = MicDeviceCatalog.mergedDevices(coreAudio: [builtIn], capture: [headphones])
        #expect(devices.map(\.uniqueID) == [builtIn.uniqueID, headphones.uniqueID])
        #expect(MicDeviceCatalog.recordingDevice(
            preferredID: headphones.uniqueID, devices: devices
        )?.uniqueID == headphones.uniqueID)
    }

    @Test func captureAdvertisementUpgradesDormantProfileWithoutDuplicatingIt() {
        let dormant = bluetoothProfile(uid: "headset-one", name: "Old Name", hasInput: false)
        let capture = bluetoothProfile(uid: "headset-one", name: "Current Name", hasInput: true)
        let devices = MicDeviceCatalog.mergedDevices(coreAudio: [dormant, builtIn], capture: [capture, builtIn])
        #expect(devices.count == 2)
        #expect(devices.first?.hasInput == true)
        #expect(devices.first?.localizedName == "Current Name")
        #expect(devices.first?.audioDeviceID == dormant.audioDeviceID)
    }

    @Test func userEditableNamesDoNotHidePhysicalMicrophones() {
        let renamed = bluetoothProfile(uid: "headset-one:input", name: "Loom recording headphones (inactive name)", hasInput: true)
        #expect(MicDeviceCatalog.mergedDevices(coreAudio: [renamed], capture: []).first == renamed)
        #expect(MicDeviceCatalog.mergedDevices(coreAudio: [], capture: [renamed]).first == renamed)
    }

    @Test func excludesKnownLoomLoopbackFromBothDiscoverySources() {
        let loom = MicDeviceInfo(
            uniqueID: "com.loom.desktop.audio-device.device", audioDeviceID: 9,
            localizedName: "LoomAudioDevice", isBuiltIn: false, isBluetooth: false, isVirtual: true
        )
        #expect(MicDeviceCatalog.mergedDevices(coreAudio: [loom, builtIn], capture: [loom, builtIn]) == [builtIn])
        // An explicitly selected, unrelated virtual microphone remains available.
        #expect(MicDeviceCatalog.mergedDevices(coreAudio: [loopback], capture: []).first == loopback)
    }

    private func bluetoothProfile(uid: String, name: String, hasInput: Bool) -> MicDeviceInfo {
        MicDeviceInfo(
            uniqueID: uid, audioDeviceID: 8, localizedName: name,
            isBuiltIn: false, isBluetooth: true, isVirtual: false, hasInput: hasInput
        )
    }
}

struct MicAudioDeviceMatchingTests {
    private let input = MicCaptureDeviceIdentity(
        uniqueID: "airpods-in", localizedName: "AirPods Max Vitalii", isBluetooth: true
    )
    private let builtIn = MicCaptureDeviceIdentity(
        uniqueID: "macbook", localizedName: "MacBook Pro Microphone", isBluetooth: false
    )

    @Test func selectedInputUsesUIDAndNeverDefaultFallback() {
        #expect(MicAudioDevices.matchingDeviceID(
            preferredID: "airpods-in", preferredName: nil, allowBluetoothNameMatch: false,
            devices: [builtIn, input]
        ) == "airpods-in")
        #expect(MicAudioDevices.matchingDeviceID(
            preferredID: "disconnected", preferredName: input.localizedName, allowBluetoothNameMatch: false,
            devices: [builtIn, input]
        ) == nil)
    }

    @Test func dormantBluetoothOutputMatchesOnlyOneExactBluetoothInputName() {
        #expect(MicAudioDevices.matchingDeviceID(
            preferredID: "airpods-out", preferredName: input.localizedName, allowBluetoothNameMatch: true,
            devices: [builtIn, input]
        ) == "airpods-in")
        #expect(MicAudioDevices.matchingDeviceID(
            preferredID: "airpods-out", preferredName: "AirPods Max", allowBluetoothNameMatch: true,
            devices: [builtIn, input]
        ) == nil)
        let sameNamedUSB = MicCaptureDeviceIdentity(
            uniqueID: "usb", localizedName: input.localizedName, isBluetooth: false
        )
        #expect(MicAudioDevices.matchingDeviceID(
            preferredID: "airpods-out", preferredName: input.localizedName, allowBluetoothNameMatch: true,
            devices: [builtIn, sameNamedUSB]
        ) == nil)
        let secondHeadset = MicCaptureDeviceIdentity(
            uniqueID: "other-airpods", localizedName: input.localizedName, isBluetooth: true
        )
        #expect(MicAudioDevices.matchingDeviceID(
            preferredID: "airpods-out", preferredName: input.localizedName, allowBluetoothNameMatch: true,
            devices: [input, secondHeadset]
        ) == nil)
    }

    @Test func bluetoothProfileUIDWinsOverAnIdenticalDisplayName() {
        let first = MicCaptureDeviceIdentity(
            uniqueID: "headset-one:input", localizedName: "AirPods Max", isBluetooth: true
        )
        let second = MicCaptureDeviceIdentity(
            uniqueID: "headset-two:input", localizedName: "AirPods Max", isBluetooth: true
        )
        #expect(MicAudioDevices.matchingDeviceID(
            preferredID: "headset-two:output", preferredName: "AirPods Max", allowBluetoothNameMatch: true,
            devices: [builtIn, first, second]
        ) == second.uniqueID)
        #expect(MicAudioDevices.matchingDeviceID(
            preferredID: "headset-two:output", preferredName: "AirPods Max", allowBluetoothNameMatch: true,
            devices: [builtIn, first]
        ) == nil)
    }
}

struct MicPCMTests {
    @Test func downmixesStereoToMono() {
        let stereo: [Float] = [0.5, -0.5, 1.0, 1.0]
        let mono = stereo.withUnsafeBufferPointer { buffer in
            MicPCM.mono48k(
                floats: buffer.baseAddress!,
                floatCount: stereo.count,
                channels: 2,
                sampleRate: 48_000
            )
        }
        #expect(mono.count == 2)
        #expect(abs(mono[0] - 0) < 0.0001)
        #expect(abs(mono[1] - 1) < 0.0001)
    }

    @Test func resamplesSixteenKiloToFortyEight() {
        let source: [Float] = [0, 1, 0]
        let output = MicPCM.resample(source, from: 16_000, to: 48_000)
        #expect(output.count == 9)
        #expect(abs(output[0] - 0) < 0.0001)
        #expect(abs(output[3] - 1) < 0.0001)
        #expect(abs(output[8] - 0) < 0.0001)
    }
}

struct MicPCMRoundTripTests {
    @Test func sampleBufferRoundTripKeepsEnergy() {
        let source: [Float] = [0.25, -0.25, 0.5, -0.5]
        let buffer = MicPCM.sampleBuffer(
            floats: source,
            sampleRate: 48_000,
            presentationTime: .zero
        )
        #expect(buffer != nil)
        let extracted = buffer.flatMap { MicPCM.extract($0) }
        #expect(extracted?.channels == 1)
        #expect(extracted?.floats.count == source.count)
        if let extracted {
            for (a, b) in zip(extracted.floats, source) {
                #expect(abs(a - b) < 0.0001)
            }
        }
    }
}

struct MicTapConverterTests {
    @Test func timestampsStartAtZero() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        buffer.floatChannelData?[0].update(repeating: 0.2, count: 480)

        let converter = MicTapConverter(enhanceVoice: false)
        let time = AVAudioTime(hostTime: mach_absolute_time())
        let first = try #require(converter.convert(buffer: buffer, time: time))
        let second = try #require(converter.convert(buffer: buffer, time: time))
        #expect(CMSampleBufferGetPresentationTimeStamp(first) == .zero)
        #expect(CMSampleBufferGetPresentationTimeStamp(second) == CMTime(value: 480, timescale: 48_000))
    }
}

struct VoiceBeautifierTests {
    @Test func limitsHotPeaks() {
        let beautifier = VoiceBeautifier(sampleRate: 48_000)
        var samples = [Float](repeating: 1.8, count: 2_048)
        beautifier.process(&samples)
        #expect(samples.allSatisfy { abs($0) <= 1.0 })
    }

    @Test func leavesSilenceQuiet() {
        let beautifier = VoiceBeautifier(sampleRate: 48_000)
        var samples = [Float](repeating: 0, count: 512)
        beautifier.process(&samples)
        #expect(samples.allSatisfy { abs($0) < 0.001 })
    }

    @Test func highPassRemovesSettledDC() {
        let beautifier = VoiceBeautifier(sampleRate: 48_000)
        var samples = [Float](repeating: 0.4, count: 8_000)
        beautifier.process(&samples)
        let tail = samples.suffix(256).map(abs)
        let mean = tail.reduce(0, +) / Float(tail.count)
        #expect(mean < 0.08)
    }

    @Test func keepsChestBandInsteadOfScoopingIt() {
        let sampleRate = 48_000.0
        var samples = (0..<4_800).map { index in
            sin(2 * Float.pi * 220 * Float(index) / Float(sampleRate)) * 0.25
        }
        let beautifier = VoiceBeautifier(sampleRate: sampleRate)
        beautifier.process(&samples)
        let energy = samples.suffix(1_200).reduce(0) { $0 + $1 * $1 } / 1_200
        #expect(energy > 0.012)
    }
}
