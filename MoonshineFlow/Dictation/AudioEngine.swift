@preconcurrency import AVFoundation
import AudioToolbox

final class AudioEngine {
    var onBuffer: ((AVAudioPCMBuffer, UInt64) -> Void)?

    private let engine = AVAudioEngine()
    private let bufferSize: AVAudioFrameCount
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private(set) var isRunning = false

    init(
        sampleRate: Double = 16_000,
        channels: AVAudioChannelCount = 1,
        bufferSize: AVAudioFrameCount = 1_024
    ) {
        self.bufferSize = bufferSize
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
    }

    func start() throws {
        guard !isRunning else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) {
            [weak self] buffer, time in
            self?.handleInputBuffer(buffer, at: time)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        isRunning = false
    }

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let converter else { return }

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

        let hostTime = time.isHostTimeValid ? time.hostTime : AudioGetCurrentHostTime()
        onBuffer?(convertedBuffer, hostTime)
    }
}
