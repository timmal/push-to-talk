import AVFoundation
import Combine

public final class AudioRecorder {
    public let amplitude = PassthroughSubject<Float, Never>()
    public let chunks = PassthroughSubject<AVAudioPCMBuffer, Never>()

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var monoHWFormat: AVAudioFormat?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1, interleaved: false)!
    private var accumulated: AVAudioPCMBuffer?
    private var isRecording = false

    public init() {}

    public func start() throws {
        guard !isRecording else { return }
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        pttLog("AudioRecorder hwFormat: sampleRate=\(hwFormat.sampleRate) channels=\(hwFormat.channelCount)")
        let monoHW = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: hwFormat.sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        monoHWFormat = monoHW
        converter = AVAudioConverter(from: monoHW, to: targetFormat)

        var tapCount = 0
        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            tapCount += 1
            if tapCount <= 3 || tapCount % 50 == 0 {
                if let ch = buffer.floatChannelData?[0] {
                    var sum: Float = 0
                    let n = Int(buffer.frameLength)
                    for i in 0..<n { sum += ch[i] * ch[i] }
                    let rms = (sum / Float(max(n,1))).squareRoot()
                    pttLog("tap #\(tapCount) frames=\(n) rms=\(rms)")
                }
            }
            self?.process(buffer: buffer)
        }
        accumulated = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 16_000 * 120)
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    @discardableResult
    public func stop() -> AVAudioPCMBuffer? {
        guard isRecording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        let out = accumulated
        accumulated = nil
        return out
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let converter, let monoHW = monoHWFormat else { return }
        guard let monoBuffer = downmixToMono(buffer, monoFormat: monoHW) else { return }

        let ratio = targetFormat.sampleRate / monoHW.sampleRate
        let capacity = AVAudioFrameCount(Double(monoBuffer.frameLength) * ratio + 128)
        guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var err: NSError?
        var didProvide = false
        converter.convert(to: targetBuffer, error: &err) { _, status in
            if didProvide { status.pointee = .noDataNow; return nil }
            didProvide = true
            status.pointee = .haveData
            return monoBuffer
        }
        if err != nil { return }

        if let ch = targetBuffer.floatChannelData?[0], targetBuffer.frameLength > 0 {
            let count = Int(targetBuffer.frameLength)
            var sum: Float = 0
            for i in 0..<count { sum += ch[i] * ch[i] }
            let rms = (sum / Float(count)).squareRoot()
            amplitude.send(rms)
        }

        if let acc = accumulated { append(targetBuffer, to: acc) }
        chunks.send(targetBuffer)
    }

    private func downmixToMono(_ src: AVAudioPCMBuffer, monoFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = src.frameLength
        guard frames > 0, let channelData = src.floatChannelData else { return nil }
        let channels = Int(src.format.channelCount)
        guard let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frames),
              let dst = out.floatChannelData?[0] else { return nil }
        out.frameLength = frames
        let n = Int(frames)
        if channels == 1 {
            memcpy(dst, channelData[0], n * MemoryLayout<Float>.size)
        } else {
            let inv = 1.0 / Float(channels)
            for i in 0..<n {
                var sum: Float = 0
                for c in 0..<channels { sum += channelData[c][i] }
                dst[i] = sum * inv
            }
        }
        return out
    }

    private func append(_ src: AVAudioPCMBuffer, to dst: AVAudioPCMBuffer) {
        let available = dst.frameCapacity - dst.frameLength
        let toCopy = min(src.frameLength, available)
        guard toCopy > 0,
              let srcData = src.floatChannelData?[0],
              let dstData = dst.floatChannelData?[0] else { return }
        memcpy(dstData + Int(dst.frameLength), srcData, Int(toCopy) * MemoryLayout<Float>.size)
        dst.frameLength += toCopy
    }
}
