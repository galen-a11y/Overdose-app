import Combine
import AudioToolbox
import AVFoundation
import Foundation

/// The loud part: a siren tone plus vibration.
///
/// The audio session uses the `.playback` category, which the silent switch does
/// not mute. It is activated (silently) when a session starts, while the app is
/// in the foreground, and kept active for the whole session. Starting audio from
/// the background can fail, so the alarm only has to raise the volume of a tone
/// that is already playing.
///
/// The app can't change the phone's volume, so the session start screen warns
/// when the volume is low.
final class AlarmController: ObservableObject {
    enum Level: Equatable {
        case off
        /// Check-in: pulsing siren, the person can stop it with "I'm OK".
        case checkIn
        /// Alert sent: continuous siren so anyone nearby can find the person.
        case alert
    }

    @Published private(set) var level: Level = .off

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var vibrationTimer: Timer?
    private var isArmed = false
    private let tone = ToneState()

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleMediaReset()
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.handleConfigurationChange()
        })
    }

    /// Current system output volume, 0...1. The app can only read it, not set it.
    var outputVolume: Float { AVAudioSession.sharedInstance().outputVolume }

    /// Call at session start, in the foreground.
    func arm() {
        guard !isArmed else { return }
        isArmed = true
        configureSession()
        startEngine()
    }

    /// Call at session end.
    func disarm() {
        set(.off)
        isArmed = false
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func set(_ newLevel: Level) {
        guard newLevel != level else { return }
        level = newLevel
        tone.mode = newLevel
        if newLevel == .off {
            vibrationTimer?.invalidate()
            vibrationTimer = nil
            return
        }
        if !isArmed { arm() }
        if !engine.isRunning { startEngine() }
        startVibration()
    }

    // MARK: - Audio

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // mixWithOthers lets the session start and stay active in the background;
            // the siren is loud enough to be heard over other audio.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            NSLog("Spotter: audio session error \(error.localizedDescription)")
        }
    }

    private func startEngine() {
        if sourceNode == nil {
            let format = engine.outputNode.inputFormat(forBus: 0)
            let sampleRate = format.sampleRate > 0 ? format.sampleRate : 44_100
            let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            let tone = self.tone
            let node = AVAudioSourceNode(format: monoFormat!) { _, _, frameCount, bufferList -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                for frame in 0..<Int(frameCount) {
                    let sample = tone.nextSample(sampleRate: sampleRate)
                    for buffer in buffers {
                        buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample
                    }
                }
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: monoFormat)
            engine.mainMixerNode.outputVolume = 1.0
            sourceNode = node
        }
        do {
            try engine.start()
        } catch {
            NSLog("Spotter: audio engine error \(error.localizedDescription)")
        }
    }

    private func startVibration() {
        vibrationTimer?.invalidate()
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        vibrationTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { _ in
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        // A phone call or another app took the audio. Take it back as soon as it ends.
        if type == .ended, isArmed {
            configureSession()
            startEngine()
        }
    }

    private func handleMediaReset() {
        guard isArmed else { return }
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil
        configureSession()
        startEngine()
    }

    private func handleConfigurationChange() {
        // Headphones unplugged or route changed; the engine stops itself.
        guard isArmed, !engine.isRunning else { return }
        startEngine()
    }
}

/// Generates the siren on the audio thread. Reads `mode` without locking; a
/// torn read just means one buffer plays the old pattern.
private final class ToneState {
    var mode: AlarmController.Level = .off
    private var phase: Double = 0
    private var time: Double = 0

    func nextSample(sampleRate: Double) -> Float {
        time += 1 / sampleRate
        guard mode != .off else { return 0 }

        // Two-tone siren: alternate 960 Hz and 1440 Hz every 0.25 s. During a
        // check-in it pulses (on 0.75 s, off 0.25 s) so it reads as a question.
        let step = Int(time / 0.25)
        let frequency = step % 2 == 0 ? 960.0 : 1440.0
        if mode == .checkIn, step % 4 == 3 { return 0 }

        phase += 2 * Double.pi * frequency / sampleRate
        if phase > 2 * Double.pi { phase -= 2 * Double.pi }
        // A square-ish wave is louder at the same peak than a pure sine.
        let value = sin(phase)
        let shaped = max(-1, min(1, value * 3))
        return Float(shaped * 0.9)
    }
}
