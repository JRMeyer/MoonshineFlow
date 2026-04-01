import AVFoundation

enum AudioCaptureSource {
    case microphone
    case systemAudio
}

final class MixedChunkBuffer {
    var onChunkReady: ((AudioChunk) -> Void)?

    private let sampleRate: Int32
    private let chunkSizeSamples: Int
    private let emissionSafetySamples: Int

    private var baseHostTime: UInt64?
    private var mixOffsetFrame: Int64 = 0
    private var nextEmitFrame: Int64 = 0
    private var latestFrameSeen: Int64 = 0
    private var mixedSamples: [Float] = []
    private var lastEndFrameBySource: [AudioCaptureSource: Int64] = [:]

    init(
        sampleRate: Int32 = 16_000,
        chunkDuration: TimeInterval = 0.6,
        emissionSafetyDuration: TimeInterval = 0.12
    ) {
        self.sampleRate = sampleRate
        self.chunkSizeSamples = max(Int(Double(sampleRate) * chunkDuration), 1)
        self.emissionSafetySamples = max(Int(Double(sampleRate) * emissionSafetyDuration), 0)
    }

    func reset() {
        baseHostTime = nil
        mixOffsetFrame = 0
        nextEmitFrame = 0
        latestFrameSeen = 0
        mixedSamples.removeAll(keepingCapacity: true)
        lastEndFrameBySource.removeAll(keepingCapacity: true)
    }

    func append(_ buffer: AVAudioPCMBuffer, hostTime: UInt64, source: AudioCaptureSource) {
        guard
            let channelData = buffer.floatChannelData,
            buffer.frameLength > 0
        else {
            return
        }

        let samples = UnsafeBufferPointer(
            start: channelData[0],
            count: Int(buffer.frameLength)
        )

        let startFrame = resolveStartFrame(
            for: hostTime,
            source: source,
            sampleCount: samples.count
        )

        let droppedPrefixFrames = max(mixOffsetFrame - startFrame, 0)
        let droppedPrefixSamples = min(Int(droppedPrefixFrames), samples.count)
        guard droppedPrefixSamples < samples.count else {
            lastEndFrameBySource[source] = startFrame + Int64(samples.count)
            return
        }

        let writableStartFrame = startFrame + Int64(droppedPrefixSamples)
        let writableSamples = samples.dropFirst(droppedPrefixSamples)
        let endFrame = writableStartFrame + Int64(writableSamples.count)

        ensureCapacity(toCover: endFrame)

        let startIndex = Int(writableStartFrame - mixOffsetFrame)
        for (offset, sample) in writableSamples.enumerated() {
            mixedSamples[startIndex + offset] += sample
        }

        latestFrameSeen = max(latestFrameSeen, endFrame)
        lastEndFrameBySource[source] = endFrame

        emitReadyChunks()
    }

    func flush() -> AudioChunk? {
        let availableSamples = Int(latestFrameSeen - nextEmitFrame)
        guard availableSamples > 0 else { return nil }

        ensureCapacity(toCover: latestFrameSeen)
        let startIndex = Int(nextEmitFrame - mixOffsetFrame)
        let endIndex = startIndex + availableSamples
        let chunk = normalizedChunk(from: Array(mixedSamples[startIndex..<endIndex]))

        nextEmitFrame = latestFrameSeen
        trimConsumedSamples()
        return chunk
    }

    private func resolveStartFrame(
        for hostTime: UInt64,
        source: AudioCaptureSource,
        sampleCount: Int
    ) -> Int64 {
        if baseHostTime == nil {
            baseHostTime = hostTime
        }

        let baseHostTime = baseHostTime ?? hostTime
        let rawStartFrame: Int64
        if hostTime >= baseHostTime {
            let deltaSeconds = AVAudioTime.seconds(forHostTime: hostTime - baseHostTime)
            rawStartFrame = Int64((deltaSeconds * Double(sampleRate)).rounded())
        } else {
            rawStartFrame = 0
        }

        if let previousEndFrame = lastEndFrameBySource[source] {
            return max(rawStartFrame, previousEndFrame)
        }

        return rawStartFrame
    }

    private func emitReadyChunks() {
        let safeFrame = latestFrameSeen - Int64(emissionSafetySamples)
        while safeFrame - nextEmitFrame >= Int64(chunkSizeSamples) {
            let chunkEndFrame = nextEmitFrame + Int64(chunkSizeSamples)
            let startIndex = Int(nextEmitFrame - mixOffsetFrame)
            let endIndex = startIndex + chunkSizeSamples
            let chunkSamples = Array(mixedSamples[startIndex..<endIndex])
            onChunkReady?(normalizedChunk(from: chunkSamples))
            nextEmitFrame = chunkEndFrame
            trimConsumedSamples()
        }
    }

    private func normalizedChunk(from samples: [Float]) -> AudioChunk {
        let peak = samples.reduce(Float.zero) { partialResult, sample in
            max(partialResult, abs(sample))
        }

        guard peak > 1 else {
            return AudioChunk(samples: samples, sampleRate: sampleRate)
        }

        let scale = 1 / peak
        return AudioChunk(
            samples: samples.map { $0 * scale },
            sampleRate: sampleRate
        )
    }

    private func ensureCapacity(toCover endFrame: Int64) {
        let requiredCount = Int(endFrame - mixOffsetFrame)
        if requiredCount > mixedSamples.count {
            mixedSamples.append(
                contentsOf: repeatElement(0, count: requiredCount - mixedSamples.count)
            )
        }
    }

    private func trimConsumedSamples() {
        let consumedSamples = Int(nextEmitFrame - mixOffsetFrame)
        guard consumedSamples > 0 else { return }

        mixedSamples.removeFirst(consumedSamples)
        mixOffsetFrame = nextEmitFrame
    }
}
