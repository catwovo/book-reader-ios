import AVFoundation
import Foundation
import UIKit

@Observable
final class StepFeedbackPlayer {
    private static let sampleRate: Double = 44100.0
    private static let minIntervalMs = 180
    private static let maxIntervalMs = 700
    private static let maxStepNotes = 6

    private struct TrackDefinition {
        let phrases: [[Int]]
        let notes: [Int]
        let phraseEndIndices: Set<Int>

        init(phrases: [[Int]]) {
            self.phrases = phrases
            self.notes = phrases.flatMap { $0 }
            var ends = Set<Int>()
            var acc = 0
            for phrase in phrases where !phrase.isEmpty {
                acc += phrase.count
                ends.insert(acc - 1)
            }
            self.phraseEndIndices = ends
        }
    }

    private static let trackDefinitions: [StepSoundTrack: TrackDefinition] = [
        .off: TrackDefinition(phrases: []),
        .canon: TrackDefinition(phrases: [
            [78, 76, 74, 73, 71, 69, 71, 73],
            [74, 73, 71, 69, 67, 66, 67, 64],
            [62, 66, 69, 67, 66, 62, 66, 64],
            [62, 59, 62, 69, 67, 71, 69, 67],
            [66, 62, 64, 73, 74, 78, 81, 69],
            [71, 67, 69, 66, 62, 74, 74, 73]
        ]),
        .twinkle: TrackDefinition(phrases: [
            [60, 60, 67, 67, 69, 69, 67],
            [65, 65, 64, 64, 62, 62, 60],
            [67, 67, 65, 65, 64, 64, 62],
            [67, 67, 65, 65, 64, 64, 62],
            [60, 60, 67, 67, 69, 69, 67],
            [65, 65, 64, 64, 62, 62, 60]
        ]),
        .fur_elise: TrackDefinition(phrases: [
            [76, 75, 76, 75, 76, 71, 74, 72, 69],
            [60, 64, 69, 71, 64, 68, 71, 72],
            [64, 76, 75, 76, 75, 76, 71, 74, 72, 69],
            [60, 64, 69, 71, 64, 72, 71, 69],
            [71, 72, 74, 76, 67, 77, 76, 74],
            [65, 76, 74, 72, 64, 74, 72, 71]
        ]),
        .ode_to_joy: TrackDefinition(phrases: [
            [64, 64, 65, 67, 67, 65, 64, 62, 60, 60, 62, 64, 64, 62, 62],
            [64, 64, 65, 67, 67, 65, 64, 62, 60, 60, 62, 64, 62, 60, 60],
            [62, 62, 64, 60, 62, 64, 65, 64, 60, 62, 64, 65, 64, 62, 60, 62, 55],
            [64, 64, 65, 67, 67, 65, 64, 62, 60, 60, 62, 64, 62, 60, 60]
        ])
    ]

    private struct ScheduledNote {
        let midi: Int
        let isPhraseEnd: Bool
        let volume: Float
    }

    private struct BufferKey: Hashable {
        let midi: Int
        let isLong: Bool
    }

    private let audioQueue = DispatchQueue(label: "com.tin.bookreader.stepfeedback", qos: .userInitiated)
    private let lock = NSLock()

    private var audioEngine: AVAudioEngine?
    private var playerPool: [AVAudioPlayerNode] = []
    private var activeVoiceCursor = 0
    private var bufferCache: [BufferKey: AVAudioPCMBuffer] = [:]
    private var audioFormat: AVAudioFormat?

    private var currentTrack: StepSoundTrack = .canon
    private var noteCursor: Int = 0
    private var audioGeneration: Int = 0
    private var hapticGeneration: Int = 0

    var hapticLevel: Int = 1
    var hapticFollowLines: Bool = false
    var noteIntervalMs: Int = 240

    func configure(track: StepSoundTrack, intervalMs: Int, hapticLevel: Int, hapticMode: StepHapticMode) {
        setSoundTrack(track)
        self.noteIntervalMs = min(Self.maxIntervalMs, max(Self.minIntervalMs, intervalMs))
        self.hapticLevel = min(3, max(0, hapticLevel))
        self.hapticFollowLines = (hapticMode == .line)
    }

    func setSoundTrack(_ track: StepSoundTrack) {
        lock.lock()
        let switched = (currentTrack != track)
        if switched {
            currentTrack = track
            noteCursor = 0
        }
        lock.unlock()

        if track == .off {
            lock.lock()
            audioGeneration &+= 1
            lock.unlock()
            audioQueue.async { [weak self] in
                self?.stopAllVoices()
            }
        } else if switched {
            audioQueue.async { [weak self] in
                self?.preloadTrack(track)
            }
        }
    }

    func pauseAll() {
        lock.lock()
        audioGeneration &+= 1
        hapticGeneration &+= 1
        lock.unlock()
        audioQueue.async { [weak self] in
            self?.stopAllVoices()
        }
    }

    func triggerFeedback(soundTrack: StepSoundTrack, hapticLevel: Int, noteCount: Int = 1) {
        setSoundTrack(soundTrack)
        playStep(hapticLevel: hapticLevel, noteCount: noteCount)
    }

    func playStep(hapticLevel: Int? = nil, noteCount: Int = 1) {
        let clampedHaptic = min(3, max(0, hapticLevel ?? self.hapticLevel))
        let desiredCount = min(Self.maxStepNotes, max(1, noteCount))
        let intervalMs = min(Self.maxIntervalMs, max(Self.minIntervalMs, noteIntervalMs))

        lock.lock()
        audioGeneration &+= 1
        hapticGeneration &+= 1
        let curAudioGen = audioGeneration
        let curHapticGen = hapticGeneration
        let track = currentTrack
        let def = Self.trackDefinitions[track] ?? TrackDefinition(phrases: [])

        var scheduled: [ScheduledNote] = []
        if !def.notes.isEmpty {
            scheduled.reserveCapacity(desiredCount)
            var step = 0
            var remaining = desiredCount
            while remaining > 0 {
                remaining -= 1
                let idx = min(max(0, noteCursor), def.notes.count - 1)
                let isPhraseEnd = def.phraseEndIndices.contains(idx)
                let baseVol: Float = isPhraseEnd ? 0.72 : max(0.46, 0.66 - Float(step) * 0.045)
                scheduled.append(ScheduledNote(midi: def.notes[idx], isPhraseEnd: isPhraseEnd, volume: baseVol))
                noteCursor = (idx + 1) % def.notes.count
                step += 1
                if isPhraseEnd {
                    break
                }
            }
        }
        lock.unlock()

        let hapticCount: Int
        if clampedHaptic <= 0 {
            hapticCount = 0
        } else if hapticFollowLines {
            hapticCount = desiredCount
        } else {
            hapticCount = 1
        }

        let maxSteps = max(scheduled.count, hapticCount)
        if !scheduled.isEmpty {
            audioQueue.async { [weak self] in
                self?.duckActiveVoices()
            }
        }

        for step in 0..<maxSteps {
            let note = step < scheduled.count ? scheduled[step] : nil
            let shouldVibrate = step < hapticCount
            let delaySec = Double(step * intervalMs) / 1000.0

            if step == 0 {
                if shouldVibrate {
                    triggerHaptic(level: clampedHaptic)
                }
                if let note {
                    audioQueue.async { [weak self] in
                        guard let self, self.isAudioGenerationCurrent(curAudioGen) else { return }
                        self.playMidi(note.midi, isLong: note.isPhraseEnd, volume: note.volume)
                    }
                }
            } else {
                if shouldVibrate {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delaySec) { [weak self] in
                        guard let self, self.isHapticGenerationCurrent(curHapticGen) else { return }
                        self.triggerHaptic(level: clampedHaptic)
                    }
                }
                if let note {
                    audioQueue.asyncAfter(deadline: .now() + delaySec) { [weak self] in
                        guard let self, self.isAudioGenerationCurrent(curAudioGen) else { return }
                        self.playMidi(note.midi, isLong: note.isPhraseEnd, volume: note.volume)
                    }
                }
            }
        }
    }

    func playTrackPreview(track: StepSoundTrack) {
        lock.lock()
        currentTrack = track
        noteCursor = 0
        audioGeneration &+= 1
        let gen = audioGeneration
        lock.unlock()

        guard track != .off, let def = Self.trackDefinitions[track], !def.notes.isEmpty else {
            audioQueue.async { [weak self] in
                self?.stopAllVoices()
            }
            return
        }

        let intervalMs = min(Self.maxIntervalMs, max(Self.minIntervalMs, noteIntervalMs))
        audioQueue.async { [weak self] in
            self?.duckActiveVoices()
            self?.preloadTrack(track)
        }

        let previewCount = min(3, def.notes.count)
        for step in 0..<previewCount {
            let midi = def.notes[step]
            let isPhraseEnd = def.phraseEndIndices.contains(step)
            let vol: Float = isPhraseEnd ? 0.72 : max(0.48, 0.66 - Float(step) * 0.045)
            let delaySec = Double(step * intervalMs) / 1000.0
            audioQueue.asyncAfter(deadline: .now() + delaySec) { [weak self] in
                guard let self, self.isAudioGenerationCurrent(gen) else { return }
                self.playMidi(midi, isLong: isPhraseEnd, volume: vol)
            }
            if isPhraseEnd { break }
        }
    }

    func playHapticPreview(level: Int, followLines: Bool) {
        let clamped = min(3, max(0, level))
        guard clamped > 0 else { return }

        lock.lock()
        hapticGeneration &+= 1
        let gen = hapticGeneration
        lock.unlock()

        triggerHaptic(level: clamped)
        guard followLines else { return }

        let intervalMs = min(Self.maxIntervalMs, max(Self.minIntervalMs, noteIntervalMs))
        for step in 1..<3 {
            let delaySec = Double(step * intervalMs) / 1000.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delaySec) { [weak self] in
                guard let self, self.isHapticGenerationCurrent(gen) else { return }
                self.triggerHaptic(level: clamped)
            }
        }
    }

    // MARK: - Private Helpers

    private func isAudioGenerationCurrent(_ gen: Int) -> Bool {
        lock.lock()
        let ok = (audioGeneration == gen)
        lock.unlock()
        return ok
    }

    private func isHapticGenerationCurrent(_ gen: Int) -> Bool {
        lock.lock()
        let ok = (hapticGeneration == gen)
        lock.unlock()
        return ok
    }

    private func triggerHaptic(level: Int) {
        DispatchQueue.main.async {
            switch level {
            case 1:
                UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.65)
            case 2:
                UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.85)
            case 3:
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred(intensity: 1.0)
            default:
                break
            }
        }
    }

    private func ensureEngineReady() -> AVAudioFormat? {
        if let engine = audioEngine, let fmt = audioFormat {
            if !engine.isRunning {
                try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
                try? AVAudioSession.sharedInstance().setActive(true)
                try? engine.start()
            }
            return fmt
        }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1) else {
            return nil
        }

        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)

        let engine = AVAudioEngine()
        var nodes: [AVAudioPlayerNode] = []
        for _ in 0..<6 {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            nodes.append(node)
        }
        engine.prepare()
        try? engine.start()

        self.audioFormat = format
        self.audioEngine = engine
        self.playerPool = nodes
        return format
    }

    private func preloadTrack(_ track: StepSoundTrack) {
        guard track != .off, let def = Self.trackDefinitions[track] else { return }
        guard let fmt = ensureEngineReady() else { return }
        let uniqueMidis = Set(def.notes)
        for midi in uniqueMidis {
            let key = BufferKey(midi: midi, isLong: false)
            if bufferCache[key] == nil, let buf = synthesizeGrandPianoBuffer(midi: midi, isLongHarmonic: false, format: fmt) {
                bufferCache[key] = buf
            }
        }
        for idx in def.phraseEndIndices where idx < def.notes.count {
            let midi = def.notes[idx]
            let key = BufferKey(midi: midi, isLong: true)
            if bufferCache[key] == nil, let buf = synthesizeGrandPianoBuffer(midi: midi, isLongHarmonic: true, format: fmt) {
                bufferCache[key] = buf
            }
        }
    }

    private func duckActiveVoices() {
        for node in playerPool where node.isPlaying {
            node.volume = min(node.volume, 0.22)
        }
    }

    private func stopAllVoices() {
        for node in playerPool where node.isPlaying {
            node.stop()
        }
    }

    private func playMidi(_ midi: Int, isLong: Bool, volume: Float) {
        guard let fmt = ensureEngineReady(), !playerPool.isEmpty else { return }
        let key = BufferKey(midi: midi, isLong: isLong)
        let buffer: AVAudioPCMBuffer
        if let cached = bufferCache[key] {
            buffer = cached
        } else if let generated = synthesizeGrandPianoBuffer(midi: midi, isLongHarmonic: isLong, format: fmt) {
            bufferCache[key] = generated
            buffer = generated
        } else {
            return
        }

        let node = playerPool[activeVoiceCursor % playerPool.count]
        activeVoiceCursor = (activeVoiceCursor + 1) % playerPool.count
        if node.isPlaying {
            node.stop()
        }
        node.volume = volume
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        node.play()
    }

    private func synthesizeGrandPianoBuffer(midi: Int, isLongHarmonic: Bool, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let freq = 440.0 * pow(2.0, Double(midi - 69) / 12.0)
        let durationSec = isLongHarmonic ? 1.40 : 0.60
        let sampleCount = Int(Self.sampleRate * durationSec)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)),
              let channelData = buffer.floatChannelData?[0] else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)

        // Concert grand string inharmonicity stiffness B
        let bCoeff = min(0.00065, max(0.00004, 0.00015 * pow(freq / 261.63, 0.55)))
        func harmonicFreq(_ n: Int) -> Double {
            Double(n) * freq * sqrt(1.0 + bCoeff * Double(n * n))
        }

        let pitchDecayScale = min(1.45, max(0.70, pow(freq / 261.63, 0.28))) * (isLongHarmonic ? 0.52 : 0.90)
        let releaseSamples = Int(Self.sampleRate * (isLongHarmonic ? 0.12 : 0.06))

        let f1 = harmonicFreq(1)
        let w1a = 2.0 * Double.pi * f1
        let w1b = 2.0 * Double.pi * (f1 * 1.0013)
        let w1c = 2.0 * Double.pi * (f1 * 0.9987)

        let f2 = harmonicFreq(2)
        let w2a = 2.0 * Double.pi * f2
        let w2b = 2.0 * Double.pi * (f2 * 1.0008)
        let w3 = 2.0 * Double.pi * harmonicFreq(3)
        let w4 = 2.0 * Double.pi * harmonicFreq(4)
        let w5 = 2.0 * Double.pi * harmonicFreq(5)
        let w6 = 2.0 * Double.pi * harmonicFreq(6)
        let w7 = 2.0 * Double.pi * harmonicFreq(7)

        let hammerFreq = min(2600.0, freq * 2.6)
        let wHammer = 2.0 * Double.pi * hammerFreq

        for i in 0..<sampleCount {
            let t = Double(i) / Self.sampleRate
            let attack = min(1.0, t / 0.0045)

            let env1 = 0.32 * exp(-10.0 * pitchDecayScale * t) + 0.68 * exp(-2.6 * pitchDecayScale * t)
            let env2 = 0.40 * exp(-12.5 * pitchDecayScale * t) + 0.60 * exp(-3.8 * pitchDecayScale * t)
            let env3 = exp(-6.5 * pitchDecayScale * t)
            let env4 = exp(-10.5 * pitchDecayScale * t)
            let env5 = exp(-15.0 * pitchDecayScale * t)
            let env6 = exp(-21.0 * pitchDecayScale * t)
            let env7 = exp(-28.0 * pitchDecayScale * t)

            let fundamental = (0.42 * sin(w1a * t) + 0.30 * sin(w1b * t) + 0.28 * sin(w1c * t)) * env1
            let h2 = (0.28 * sin(w2a * t) + 0.14 * sin(w2b * t)) * env2
            let h3 = 0.22 * sin(w3 * t) * env3
            let h4 = 0.13 * sin(w4 * t) * env4
            let h5 = 0.07 * sin(w5 * t) * env5
            let h6 = 0.035 * sin(w6 * t) * env6
            let h7 = 0.015 * sin(w7 * t) * env7
            let hammerTransient = 0.035 * sin(wHammer * t) * exp(-190.0 * t)

            let tailFade: Double
            if i > sampleCount - releaseSamples {
                tailFade = min(1.0, max(0.0, Double(sampleCount - i) / Double(releaseSamples)))
            } else {
                tailFade = 1.0
            }

            let sample = (fundamental + h2 + h3 + h4 + h5 + h6 + h7 + hammerTransient) * 0.42 * attack * tailFade
            channelData[i] = Float(min(0.98, max(-0.98, sample)))
        }
        return buffer
    }
}
