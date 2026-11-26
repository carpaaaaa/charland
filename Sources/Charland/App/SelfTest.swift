import Foundation
import CharlandCore

/// La prova di sé: recita ogni transizione senza schermo, a 60 fotogrammi al secondo,
/// e cerca saltini, code, contenuti tagliati e contenitori che cambiano misura.
/// `Charland --selftest` esce con 0 se non trova niente.
enum SelfTest {
    static func run() -> Bool {
        var failures = 0
        func check(_ name: String, _ metrics: IslandMetrics, _ script: [(IslandEvent, Double)]) {
            let findings = play(script, metrics: metrics)
            if findings.isEmpty {
                print("ok   \(name)")
            } else {
                failures += findings.count
                print("NO   \(name)")
                for f in findings { print("       \(f)") }
            }
        }

        let music = IslandActivity(id: "musica", priority: 1, leadingWidth: 26, trailingWidth: 26, expandedWidth: 320, expandedHeight: 104)
        let timer = IslandActivity(id: "timer", leadingWidth: 22, trailingWidth: 44, expandedWidth: 300, expandedHeight: 96)
        let agent = IslandActivity(id: "agente", priority: 5, leadingWidth: 22, trailingWidth: 26, expandedWidth: 372, expandedHeight: 138)
        // La Concentrazione (`FocusMonitor`): con le misure vere del nome di Non disturbare e di «Spento».
        let focusOn = IslandActivity(id: "concentrazione", priority: 2, leadingWidth: 30,
                                     trailingWidth: FocusLabel.width(for: FocusNames.doNotDisturb),
                                     expandedWidth: 320, expandedHeight: 86, allowsMinimal: false)
        let focusOff = IslandActivity(id: "concentrazione-spenta", priority: 2, leadingWidth: 30,
                                      trailingWidth: FocusLabel.width(for: String(localized: "Spento")),
                                      expandedWidth: 320, expandedHeight: 86, allowsMinimal: false)

        for (label, metrics) in [("MacBook Air 15", IslandMetrics.air15),
                                 ("Mac senza notch", IslandMetrics.notchless(screenWidth: 1920))] {
            check("\(label): riposo, compatto, espanso, ritorno", metrics, [
                (.started(music), 2.1), (.expand(id: nil), 2.1), (.collapse, 2.1), (.ended(id: "musica"), 2.1),
            ])
            check("\(label): la casa al passaggio del puntatore", metrics, [
                (.pointerEntered, 2.1), (.collapse, 2.1), (.expand(id: nil), 2.1), (.collapse, 2.1),
            ])
            check("\(label): due gocce e riassorbimento", metrics, [
                (.started(music), 2.1), (.started(timer), 2.1), (.ended(id: "timer"), 2.1), (.ended(id: "musica"), 2.1),
            ])
            check("\(label): tre attività, cambio di priorità", metrics, [
                (.started(music), 2.1), (.started(timer), 2.1), (.started(agent), 2.1), (.expand(id: "agente"), 2.1),
                (.ended(id: "agente"), 2.1), (.ended(id: "timer"), 2.1), (.ended(id: "musica"), 2.1),
            ])
            check("\(label): volume e luminosità", metrics, [
                (.transientBegan(.slider(.volume)), 2.1), (.transientEnded, 2.1),
                (.transientBegan(.slider(.brightness)), 2.1), (.transientEnded, 2.1),
                (.started(music), 2.1), (.transientBegan(.slider(.volume)), 2.1), (.transientEnded, 2.1), (.ended(id: "musica"), 2.1),
            ])
            // Come `FocusMonitor.announce`: il nuovo momento comincia e l'altro finisce nello stesso fotogramma.
            let swap = 0.0
            check("\(label): Full immersion accesa, spenta, spenta mentre è nell'isola", metrics, [
                (.started(focusOn), 2.1), (.ended(id: "concentrazione"), 2.1),
                (.started(focusOff), 2.1), (.ended(id: "concentrazione-spenta"), 2.1),
                (.started(focusOn), 1.1), (.started(focusOff), swap), (.ended(id: "concentrazione"), 2.1),
                (.started(focusOn), swap), (.ended(id: "concentrazione-spenta"), 2.1), (.ended(id: "concentrazione"), 2.1),
            ])
            check("\(label): Full immersion sopra la musica", metrics, [
                (.started(music), 2.1), (.started(focusOn), 2.1), (.started(focusOff), swap), (.ended(id: "concentrazione"), 2.1),
                (.ended(id: "concentrazione-spenta"), 2.1), (.ended(id: "musica"), 2.1),
            ])
            for style in DictationStyle.allCases {
                check("\(label): dettatura \(style.rawValue)", metrics, [
                    (.transientBegan(.dictation(style: style, liveText: false, handsFree: false)), 2.1),
                    (.transientBegan(.dictation(style: style, liveText: true, handsFree: false)), 2.1),
                    (.transientEnded, 2.1),
                ])
            }
        }
        // I gruppi delle sessioni avviate da un'altra sessione, coi titoli letti nella barra di Claude il 19 novembre 2026:
        // senza riconoscerli una risposta dall'isola a una sessione così non partiva mai.
        let names: Set<String> = ["Testo a tempo in Dynamic: analisi e piano", "Loth screen testo dinamico bug", "piano"]
        let groupCases: [(String, ClaudeWindow.GroupToggle?)] = [
            ("Mostra 1 sessione annidata, 1 richiede input Testo a tempo in Dynamic: analisi e piano",
             .init(parent: "Testo a tempo in Dynamic: analisi e piano", open: false, needsInput: true)),
            ("Nascondi sessioni annidate Loth screen testo dinamico bug",
             .init(parent: "Loth screen testo dinamico bug", open: true, needsInput: false)),
            ("Testo a tempo in Dynamic: analisi e piano Avviata da Claude da Loth screen testo dinamico bug", nil),
            ("Mostra azioni messaggio per Claude ha risposto: piano", nil),
        ]
        for (title, expected) in groupCases {
            let got = ClaudeWindow.groupToggle(title, names: names)
            if got == expected {
                print("ok   gruppo nella barra di Claude: «\(title.prefix(50))»")
            } else {
                failures += 1
                print("NO   gruppo nella barra di Claude: «\(title)» → \(String(describing: got)), atteso \(String(describing: expected))")
            }
        }
        print(failures == 0 ? "Tutto a posto." : "Difetti trovati: \(failures)")
        return failures == 0
    }

    static func play(_ script: [(IslandEvent, Double)], metrics: IslandMetrics) -> [MotionAudit.Finding] {
        var state = IslandState()
        state.setHome(Home.activity)
        var motion = IslandMotion(metrics: metrics)
        var findings: [MotionAudit.Finding] = []
        let dt = 1.0 / 60.0
        var tape = [MotionAudit.sample(motion.frame)]
        for (index, (event, hold)) in script.enumerated() {
            state.handle(event, now: motion.now)
            motion.apply(state.mode, state: state)
            // Tempo zero: l'evento dopo arriva nello stesso fotogramma (come una fine e un inizio mandati insieme).
            if hold == 0 { continue }
            var settledAfter: Int?
            let frames = max(1, Int(hold / dt))
            let first = tape.count
            for f in 1...frames {
                let moving = motion.step(dt: dt)
                tape.append(MotionAudit.sample(motion.frame))
                if !moving, settledAfter == nil { settledAfter = f }
            }
            if let settledAfter {
                if Double(settledAfter) * dt > 2.0 {
                    findings.append(.init(kind: .tooLong, frame: first, track: "passo \(index)", detail: "\(settledAfter) fotogrammi"))
                }
                let rest = Array(tape[(first + settledAfter - 1)...])
                findings += MotionAudit.check(rest, settledFrom: 0).filter { $0.kind == .tail }
            } else {
                findings.append(.init(kind: .tooLong, frame: first, track: "passo \(index)", detail: "non si è fermato"))
            }
            findings += MotionAudit.checkClipping(motion.frame)
        }
        findings += MotionAudit.check(tape)
        return findings
    }
}
