import AVFoundation
import ClaudeNativeCore
import Foundation
import Testing
@testable import ClaudeNative

struct ToneSynthesizerTests {
    /// Short enough to mark a moment without talking over VoiceOver.
    static let longestCue: TimeInterval = 0.25
    /// About −10 dBFS: quiet beside VoiceOver at the same volume.
    static let loudestPeak = 0.3

    @Test(arguments: SoundCue.allCases)
    func everyCueIsAShortQuietWAVThatStartsAndEndsSilent(cue: SoundCue) throws {
        let data = ToneSynthesizer.wav(for: cue)
        let player = try AVAudioPlayer(data: data)
        #expect(player.duration > 0)
        #expect(player.duration <= Self.longestCue)
        #expect(abs(player.duration - SoundCuePlayer.duration(of: cue)) < 0.001)

        let samples = ToneSynthesizer.samples(for: CueTone.notes(for: cue))
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        let ceiling = Int(Self.loudestPeak * Double(Int16.max))
        #expect(peak <= ceiling)
        // Not so quiet it can't be heard under speech.
        #expect(peak > ceiling / 2)
        // Edges at zero: no click as the sound starts or stops.
        #expect(samples.first == 0)
        #expect(abs(Int(samples.last ?? 1)) < 50)
    }

    /// Two cues may share a pitch but never a shape: how many notes, and
    /// whether each step goes up, down or stays.
    @Test func everyCueHasItsOwnShape() {
        func shape(_ cue: SoundCue) -> [Int] {
            let notes = CueTone.notes(for: cue)
            let steps = zip(notes, notes.dropFirst()).map { a, b in
                b.frequency > a.frequency ? 1 : (b.frequency < a.frequency ? -1 : 0)
            }
            return [notes.count] + steps
        }
        let shapes = SoundCue.allCases.map(shape)
        #expect(Set(shapes.map { $0.description }).count == SoundCue.allCases.count)
    }

    @Test func wavHeaderDescribesMono16BitPCM() {
        let data = ToneSynthesizer.wav(samples: [0, 1, -1])
        #expect(data.count == 44 + 6)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(data[22] == 1)   // channels
        #expect(data[34] == 16)  // bits per sample
    }
}

/// When a cue starts. After the audio output changes, the new device's
/// clock can read far behind the old one's, and every cue was dropped
/// as too long to wait for.
@MainActor
struct CueStartTests {
    @Test func withNothingPlayingACueStartsNowWhateverTheOldClockSaid() {
        #expect(SoundCuePlayer.start(now: 5, freeAt: 10_000, earlierStillPlaying: false) == 5)
    }

    @Test func behindAPlayingCueItWaitsItsTurnOrIsDropped() {
        #expect(SoundCuePlayer.start(now: 5, freeAt: 5.2, earlierStillPlaying: true) == 5.2)
        #expect(SoundCuePlayer.start(now: 5, freeAt: 5 + SoundCuePlayer.maximumWait + 1, earlierStillPlaying: true) == nil)
        #expect(SoundCuePlayer.start(now: 5, freeAt: 1, earlierStillPlaying: true) == 5)
    }
}

