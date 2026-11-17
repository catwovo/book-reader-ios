import AVFoundation
import UIKit

@Observable
final class StepFeedbackPlayer {
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var stepCounter = 0

    // Pentatonic frequencies (C5, D5, E5, G5, A5, C6)
    private let scale: [Double] = [523.25, 587.33, 659.25, 783.99, 880.00, 1046.50]

    func triggerFeedback(soundTrack: StepSoundTrack, hapticLevel: Int) {
        triggerHaptic(level: hapticLevel)
        if soundTrack != .off {
            playNote(track: soundTrack)
        }
    }

    private func triggerHaptic(level: Int) {
        switch level {
        case 1:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case 2:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case 3:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        default:
            break
        }
    }

    private func playNote(track: StepSoundTrack) {
        let freq = scale[stepCounter % scale.count]
        stepCounter += 1

        let sampleRate: Double = 44100
        let duration: Double = track == .chime ? 0.35 : (track == .piano ? 0.22 : 0.16)
        let frameCount = AVAudioFrameCount(sampleRate * duration)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return
        }
        buffer.frameLength = frameCount

        if let data = buffer.floatChannelData?[0] {
            for i in 0..<Int(frameCount) {
                let t = Double(i) / sampleRate
                let env = exp(-t * (track == .chime ? 8.0 : 16.0))
                let harmonic = track == .piano ? 0.25 * sin(2 * .pi * freq * 2 * t) : 0.0
                let sample = Float((sin(2 * .pi * freq * t) + harmonic) * env * 0.14)
                data[i] = sample
            }
        }

        if audioEngine == nil {
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            try? engine.start()
            audioEngine = engine
            playerNode = node
        }

        if let engine = audioEngine, !engine.isRunning {
            try? engine.start()
        }
        playerNode?.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        playerNode?.play()
    }
}
