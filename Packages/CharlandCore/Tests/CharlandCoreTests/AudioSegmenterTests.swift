import Testing
import Foundation
@testable import CharlandCore

@Suite("Voce: dettature lunghe a pezzi")
struct AudioSegmenterTests {
    /// Voce finta: un tono con qualche pausa. `pauses` sono (secondo, durata).
    func speech(seconds: Double, pauses: [(Double, Double)] = [], level: Float = 0.1) -> [Float] {
        let n = Int(seconds * AudioSegmenter.sampleRate)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / AudioSegmenter.sampleRate
            let silent = pauses.contains { t >= $0.0 && t < $0.0 + $0.1 }
            out[i] = silent ? 0 : level * Float(sin(t * 2 * .pi * 220))
        }
        return out
    }

    @Test("sotto la soglia non si taglia")
    func shortStaysWhole() {
        #expect(AudioSegmenter.cut(speech(seconds: 12)) == nil)
        #expect(AudioSegmenter.split(speech(seconds: 12)).count == 1)
        #expect(AudioSegmenter.split([]).isEmpty)
    }

    @Test("si taglia nella pausa, non in mezzo alla voce")
    func cutsInThePause() throws {
        let cut = try #require(AudioSegmenter.cut(speech(seconds: 20, pauses: [(12.0, 0.5)])))
        let second = Double(cut.index) / AudioSegmenter.sampleRate
        #expect(second > 12.0 && second < 12.5)
        #expect(cut.pause)
    }

    @Test("senza pause si taglia lo stesso, ma si sa che il taglio è in mezzo a una frase")
    func cutsWithoutPause() throws {
        let cut = try #require(AudioSegmenter.cut(speech(seconds: 20)))
        let second = Double(cut.index) / AudioSegmenter.sampleRate
        #expect(second >= 9 && second <= 17)
        #expect(!cut.pause)
    }

    @Test("un minuto e mezzo diventa pezzi corti che coprono tutto, senza buchi")
    func splitsLongAudio() {
        let gaps = stride(from: 5.0, to: 90.0, by: 6.5).map { ($0, 0.4) }
        let audio = speech(seconds: 90, pauses: gaps)
        let parts = AudioSegmenter.split(audio)
        #expect(parts.count >= 6 && parts.count <= 10)
        #expect(parts.first?.range.lowerBound == 0)
        #expect(parts.last?.range.upperBound == audio.count)
        for (a, b) in zip(parts, parts.dropFirst()) { #expect(a.range.upperBound == b.range.lowerBound) }
        let longest = parts.map { Double($0.range.count) / AudioSegmenter.sampleRate }.max() ?? 0
        #expect(longest <= 17.5)
        let pauses = parts.dropLast().filter(\.pauseAfter).count
        #expect(pauses == parts.count - 1)
    }

    @Test("la voce si distingue dal silenzio e dal rumore di fondo")
    func audible() {
        #expect(AudioSegmenter.isAudible(speech(seconds: 2)))
        #expect(!AudioSegmenter.isAudible(speech(seconds: 2, level: 0.002)))
        #expect(!AudioSegmenter.isAudible([Float](repeating: 0, count: 32000)))
        #expect(!AudioSegmenter.isAudible(speech(seconds: 0.2)))
    }

    @Test("i testi dei pezzi tornano una frase sola dove il taglio era in mezzo")
    func joins() {
        let common: (String) -> Bool = { ["e", "poi", "quindi", "la"].contains($0.lowercased()) }
        #expect(AudioSegmenter.join([.init(text: "Vado a casa.", pauseAfter: false), .init(text: "Poi ti chiamo.", pauseAfter: true)], lowercase: common)
                == "Vado a casa poi ti chiamo.")
        // un nome resta con la maiuscola, una pausa vera tiene il punto
        #expect(AudioSegmenter.join([.init(text: "Ho chiesto a.", pauseAfter: false), .init(text: "Claude di farlo.", pauseAfter: true)], lowercase: common)
                == "Ho chiesto a Claude di farlo.")
        #expect(AudioSegmenter.join([.init(text: "Vado a casa.", pauseAfter: true), .init(text: "Poi ti chiamo.", pauseAfter: true)], lowercase: common)
                == "Vado a casa. Poi ti chiamo.")
        #expect(AudioSegmenter.join([.init(text: "Davvero?", pauseAfter: false), .init(text: "", pauseAfter: false), .init(text: "E poi", pauseAfter: true)], lowercase: common)
                == "Davvero? e poi")
        #expect(AudioSegmenter.join([], lowercase: common) == "")
    }
}
