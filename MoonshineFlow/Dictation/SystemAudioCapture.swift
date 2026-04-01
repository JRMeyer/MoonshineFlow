@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Darwin
import Foundation

final class SystemAudioCapture {
    var onBuffer: ((AVAudioPCMBuffer, UInt64) -> Void)?

    private let ioQueue = DispatchQueue(label: "ai.moonshine.flow.system-audio")
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var tapDescription: CATapDescription?
    private var tapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var ioProcID: AudioDeviceIOProcID?

    private(set) var isRunning = false

    init(
        sampleRate: Double = 16_000,
        channels: AVAudioChannelCount = 1
    ) {
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
    }

    func start() throws {
        guard !isRunning else { return }

        do {
            let system = AudioHardwareSystem.shared
            guard let outputDevice = try system.defaultOutputDevice else {
                throw SystemAudioCaptureError.outputDeviceUnavailable
            }

            let excludedProcesses = currentProcessObjectIDs()
            let tapDescription = CATapDescription(
                stereoGlobalTapButExcludeProcesses: excludedProcesses
            )
            tapDescription.uuid = UUID()
            tapDescription.name = "MoonshineFlow System Audio"
            tapDescription.isPrivate = true
            tapDescription.muteBehavior = .unmuted
            self.tapDescription = tapDescription

            var tapID = AudioObjectID.unknown
            var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
            guard status == noErr else {
                throw SystemAudioCaptureError.coreAudioFailure(
                    operation: "create process tap",
                    status: status
                )
            }
            self.tapID = tapID

            var streamDescription = try AudioHardwareTap(id: tapID).format
            guard let sourceFormat = AVAudioFormat(streamDescription: &streamDescription) else {
                throw SystemAudioCaptureError.invalidFormat
            }
            self.sourceFormat = sourceFormat
            self.converter = AVAudioConverter(from: sourceFormat, to: targetFormat)

            let aggregateDeviceDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MoonshineFlow System Audio",
                kAudioAggregateDeviceUIDKey: "ai.moonshine.flow.aggregate.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: try outputDevice.uid,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [
                        kAudioSubDeviceUIDKey: try outputDevice.uid,
                    ]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    ]
                ],
            ]

            status = AudioHardwareCreateAggregateDevice(
                aggregateDeviceDescription as CFDictionary,
                &aggregateDeviceID
            )
            guard status == noErr else {
                throw SystemAudioCaptureError.coreAudioFailure(
                    operation: "create aggregate device",
                    status: status
                )
            }

            status = AudioDeviceCreateIOProcIDWithBlock(
                &ioProcID,
                aggregateDeviceID,
                ioQueue
            ) { [weak self] _, inputData, inputTime, _, _ in
                self?.handleInputBuffer(inputData, inputTime: inputTime)
            }
            guard status == noErr else {
                throw SystemAudioCaptureError.coreAudioFailure(
                    operation: "create I/O proc",
                    status: status
                )
            }

            status = AudioDeviceStart(aggregateDeviceID, ioProcID)
            guard status == noErr else {
                throw SystemAudioCaptureError.coreAudioFailure(
                    operation: "start aggregate device",
                    status: status
                )
            }

            isRunning = true
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        guard tapID.isValid || aggregateDeviceID.isValid || ioProcID != nil else {
            converter = nil
            sourceFormat = nil
            tapDescription = nil
            isRunning = false
            return
        }

        if aggregateDeviceID.isValid {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
        }

        if let ioProcID {
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }

        if aggregateDeviceID.isValid {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .unknown
        }

        if tapID.isValid {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }

        converter = nil
        sourceFormat = nil
        tapDescription = nil
        isRunning = false
    }

    private func handleInputBuffer(
        _ inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>
    ) {
        guard
            let sourceFormat,
            let converter,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                bufferListNoCopy: inputData,
                deallocator: nil
            )
        else {
            return
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else {
            return
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        guard error == nil, convertedBuffer.frameLength > 0 else {
            return
        }

        let hostTime = inputTime.pointee.mHostTime != 0
            ? inputTime.pointee.mHostTime
            : AudioGetCurrentHostTime()
        onBuffer?(convertedBuffer, hostTime)
    }

    private func currentProcessObjectIDs() -> [AudioObjectID] {
        guard let processObject = try? AudioHardwareSystem.shared.process(for: getpid()) else {
            return []
        }

        return [processObject.id]
    }
}

private enum SystemAudioCaptureError: LocalizedError {
    case outputDeviceUnavailable
    case invalidFormat
    case coreAudioFailure(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .outputDeviceUnavailable:
            return "No system output device is available for capture."
        case .invalidFormat:
            return "System audio capture returned an invalid audio format."
        case let .coreAudioFailure(operation, status):
            let nsError = NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            return "Failed to \(operation): \(nsError.localizedDescription) (\(status))."
        }
    }
}

private extension AudioObjectID {
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool {
        self != .unknown
    }
}
