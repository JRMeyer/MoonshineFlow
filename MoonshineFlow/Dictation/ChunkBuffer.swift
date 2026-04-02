import AVFoundation

enum AudioCaptureSource {
    case microphone
    case systemAudio
}

struct AudioChunk {
    let samples: [Float]
    let sampleRate: Int32
}

final class ChunkBuffer {
    var onChunkReady: ((AudioChunk) -> Void)?

    private let sampleRate: Int32
    private let chunkSizeSamples: Int
    private var pendingSamples: [Float] = []

    init(sampleRate: Int32 = 16_000, chunkDuration: TimeInterval = 0.6) {
        self.sampleRate = sampleRate
        self.chunkSizeSamples = max(Int(Double(sampleRate) * chunkDuration), 1)
    }

    func reset() {
        pendingSamples.removeAll(keepingCapacity: true)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
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
        pendingSamples.append(contentsOf: samples)

        while pendingSamples.count >= chunkSizeSamples {
            let chunk = Array(pendingSamples.prefix(chunkSizeSamples))
            pendingSamples.removeFirst(chunkSizeSamples)
            onChunkReady?(AudioChunk(samples: chunk, sampleRate: sampleRate))
        }
    }

    func flush() -> AudioChunk? {
        guard !pendingSamples.isEmpty else { return nil }
        let chunk = AudioChunk(samples: pendingSamples, sampleRate: sampleRate)
        pendingSamples.removeAll(keepingCapacity: true)
        return chunk
    }
}
