import AVFoundation
import ClaudeNativeCore
import SwiftUI

/// How each cue sounds. Cues differ by shape (how many notes, which way
/// they move, their rhythm), not just pitch, so they stay apart for anyone
/// who can't name a pitch:
///
/// - tool started: one short blip
/// - tool succeeded: two notes leaping up
/// - tool failed: two lower notes stepping down
/// - Claude finished: three notes climbing
/// - needs permission: the same note twice, a knock
enum CueTone {
    struct Note {
        let frequency: Double
        let duration: TimeInterval
        /// Silence after the note, before the next one.
        var gapAfter: TimeInterval = 0
    }

    /// Equal-tempered pitches from E-flat 4 to G5: high enough to cut
    /// through speech, low enough not to sting.
    enum Pitch {
        static let eFlat4 = 311.13
        static let g4 = 392.00
        static let c5 = 523.25
        static let d5 = 587.33
        static let e5 = 659.25
        static let g5 = 783.99
    }

    static func notes(for cue: SoundCue) -> [Note] {
        switch cue {
        case .toolStarted:
            [Note(frequency: Pitch.e5, duration: 0.07)]
        case .toolSucceeded:
            [Note(frequency: Pitch.c5, duration: 0.07, gapAfter: 0.02), Note(frequency: Pitch.g5, duration: 0.09)]
        case .toolFailed:
            [Note(frequency: Pitch.g4, duration: 0.09, gapAfter: 0.02), Note(frequency: Pitch.eFlat4, duration: 0.11)]
        case .turnFinished:
            [
                Note(frequency: Pitch.g4, duration: 0.06, gapAfter: 0.015),
                Note(frequency: Pitch.c5, duration: 0.06, gapAfter: 0.015),
                Note(frequency: Pitch.e5, duration: 0.06),
            ]
        case .permissionNeeded:
            [Note(frequency: Pitch.d5, duration: 0.06, gapAfter: 0.06), Note(frequency: Pitch.d5, duration: 0.06)]
        }
    }
}

/// Renders cues as 16-bit mono PCM WAV data in memory.
enum ToneSynthesizer {
    static let sampleRate = 44_100.0
    /// Each note's loudest point as a fraction of full scale, about −12 dBFS:
    /// a cue sits under VoiceOver's speech rather than over it.
    static let peakAmplitude = 0.25
    /// Rise time at a note's start; any shorter and the onset clicks.
    static let attack: TimeInterval = 0.006
    /// Fade at a note's end, so it stops without a click.
    static let release: TimeInterval = 0.02
    /// How far a note sags between attack and release, as a fraction of its
    /// peak: a little decay sounds struck rather than buzzed.
    static let sustainDecay = 0.35

    static func samples(for notes: [CueTone.Note]) -> [Int16] {
        var output: [Int16] = []
        for note in notes {
            let count = Int((note.duration * sampleRate).rounded())
            for index in 0..<count {
                let time = Double(index) / sampleRate
                let level = envelope(at: time, duration: note.duration) * peakAmplitude
                let value = sin(2 * .pi * note.frequency * time) * level
                output.append(Int16((value * Double(Int16.max)).rounded()))
            }
            output += Array(repeating: 0, count: Int((note.gapAfter * sampleRate).rounded()))
        }
        return output
    }

    /// 0 at the edges, 1 at the end of the attack, sagging toward the release.
    static func envelope(at time: TimeInterval, duration: TimeInterval) -> Double {
        let rise = min(1, time / attack)
        let sag = 1 - sustainDecay * min(1, time / duration)
        let remaining = duration - time
        let fall = remaining < release ? max(0, remaining / release) : 1
        // Raised-cosine edges are gentler than straight ramps.
        let smooth = { (x: Double) in 0.5 - 0.5 * cos(.pi * x) }
        return smooth(rise) * sag * smooth(fall)
    }

    static func wav(for cue: SoundCue) -> Data {
        wav(samples: samples(for: CueTone.notes(for: cue)))
    }

    static func wav(samples: [Int16]) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                                  // fmt chunk size
        append(UInt16(1))                                   // PCM
        append(UInt16(1))                                   // mono
        append(UInt32(sampleRate))
        append(UInt32(Int(sampleRate) * bytesPerSample))    // byte rate
        append(UInt16(bytesPerSample))                     // block align
        append(UInt16(bytesPerSample * 8))                  // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize))
        for sample in samples { append(sample) }
        return data
    }
}

/// Plays cues one after another, never on top of each other.
@MainActor
final class SoundCuePlayer {
    static let shared = SoundCuePlayer()

    /// Silence between two cues that would otherwise overlap.
    static let gapBetweenCues: TimeInterval = 0.05
    /// A cue that would have to wait longer than this is dropped: late, it
    /// would describe something that already moved on.
    static let maximumWait: TimeInterval = 0.6
    /// The system's alert volume ("Alert volume" in Sound settings), 0 to 1.
    static let alertVolumeKey = "com.apple.sound.beep.volume"

    private var sounds: [SoundCue: Data] = [:]
    /// Players stay referenced until they finish; a released player stops.
    private var active: [(player: AVAudioPlayer, endsAt: TimeInterval)] = []
    /// When, on the audio device's clock, the last scheduled cue ends.
    private var freeAt: TimeInterval = 0
    private var lesson: Task<Void, Never>?

    /// Follows the alert volume when the system has one saved; full volume
    /// otherwise (the tones themselves are quiet).
    static var volume: Float {
        let saved = UserDefaults.standard.object(forKey: alertVolumeKey) as? Double
        return Float(min(1, max(0, saved ?? 1)))
    }

    nonisolated static func duration(of cue: SoundCue) -> TimeInterval {
        CueTone.notes(for: cue).reduce(0) { $0 + $1.duration + $1.gapAfter }
    }

    func play(_ cue: SoundCue) {
        let data = sounds[cue] ?? ToneSynthesizer.wav(for: cue)
        sounds[cue] = data
        guard let player = try? AVAudioPlayer(data: data) else { return }
        player.volume = Self.volume
        player.prepareToPlay()
        let now = player.deviceCurrentTime
        active.removeAll { $0.endsAt < now || !$0.player.isPlaying }
        guard let start = Self.start(now: now, freeAt: freeAt, earlierStillPlaying: !active.isEmpty) else { return }
        guard player.play(atTime: start) else { return }
        freeAt = start + player.duration + Self.gapBetweenCues
        active.append((player, freeAt))
    }

    /// When a cue starts, on the device's clock: after the one still
    /// playing, or nil if that's more than `maximumWait` away. With nothing
    /// playing it's now: `freeAt` belongs to the clock of the device that
    /// played the last cue, and after a switch of output (AirPods
    /// connecting) it could sit far ahead of the new one's, dropping every
    /// cue from then on.
    static func start(now: TimeInterval, freeAt: TimeInterval, earlierStillPlaying: Bool) -> TimeInterval? {
        guard earlierStillPlaying else { return now }
        let start = max(now, freeAt)
        return start - now <= maximumWait ? start : nil
    }

    /// Wait after a tone before its explanation, so the words don't clip it.
    static let pauseBeforeWords: TimeInterval = 0.3
    /// Time allowed for VoiceOver to say each word of an explanation, and a
    /// fixed margin on top, before the next tone. Generous: a tone over the
    /// words would defeat the lesson.
    static let speechTimePerWord: TimeInterval = 0.35
    static let speechMargin: TimeInterval = 0.8
    /// Lets VoiceOver finish reading the closed menu before the first tone.
    static let lessonLeadIn: TimeInterval = 1.0

    /// Plays each cue, then says what it means. Plays whether or not cues
    /// are turned on: this is how to hear them before deciding.
    func playLesson() {
        lesson?.cancel()
        lesson = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(Self.lessonLeadIn))
                for cue in SoundCue.allCases {
                    play(cue)
                    try await Task.sleep(for: .seconds(Self.duration(of: cue) + Self.pauseBeforeWords))
                    Announcer.announce(cue.meaning)
                    let words = cue.meaning.split(separator: " ").count
                    try await Task.sleep(for: .seconds(Double(words) * Self.speechTimePerWord + Self.speechMargin))
                }
            } catch {
                // Cancelled by starting the lesson again.
            }
        }
    }
}

/// The View menu's Sound Cues toggle (off until the user turns it on) and a
/// way to hear every cue with its meaning.
struct SoundCueCommands: Commands {
    @AppStorage(SoundCuePolicy.defaultsKey) private var enabled = false
    @AppStorage(FinishAnnouncement.defaultsKey) private var announceFinish = true
    @AppStorage(ActivityAnnouncements.defaultsKey) private var announceActivity = false

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Toggle("Sound Cues", isOn: Binding(
                get: { enabled },
                set: { on in
                    enabled = on
                    Announcer.announce(on ? "Sound cues on." : "Sound cues off.")
                }
            ))
            Button("Play the Sound Cues") { SoundCuePlayer.shared.playLesson() }
            // Spoken "Claude finished." ends VoiceOver's reading of the
            // reply once its current line is done (measured), while the
            // finished sound plays alongside it. On by default.
            Toggle("Announce When Claude Finishes", isOn: Binding(
                get: { announceFinish },
                set: { on in
                    announceFinish = on
                    Announcer.announce(on ? "Claude finished will be announced." : "Claude finished won't be announced.")
                }
            ))
            // "Compacting conversation.", "Running echo hi.": spoken
            // wherever focus is, as the Claude app does. Off by default:
            // each line cuts into what VoiceOver is reading.
            Toggle("Announce What Claude Is Doing", isOn: Binding(
                get: { announceActivity },
                set: { on in
                    announceActivity = on
                    Announcer.announce(on ? "What Claude is doing will be announced." : "What Claude is doing won't be announced.")
                }
            ))
        }
    }
}

/// Whether "Claude finished." is spoken when a reply ends.
enum FinishAnnouncement {
    static let defaultsKey = "announceFinish"

    static var isOn: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }
}
