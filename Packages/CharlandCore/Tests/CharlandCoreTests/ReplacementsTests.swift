import Testing
@testable import CharlandCore

@Suite("Voce: sostituzioni")
struct ReplacementsTests {
    let gta = [Replacement(spoken: "gta 6", written: "GTA VI")]

    @Test("la frase detta diventa quella scritta, anche coi numeri in lettere e senza spazio")
    func variants() {
        #expect(Replacements.apply("ho comprato gta 6 ieri", gta) == "ho comprato GTA VI ieri")
        #expect(Replacements.apply("Ho comprato Gta sei ieri.", gta) == "Ho comprato GTA VI ieri.")
        #expect(Replacements.apply("GTA6 esce a maggio", gta) == "GTA VI esce a maggio")
        #expect(Replacements.apply("aspetto gta 6.", gta) == "aspetto GTA VI.")
    }

    @Test("solo parole intere: gta 60 resta com'è")
    func wholeWords() {
        #expect(Replacements.apply("gta 60 non esiste", gta) == "gta 60 non esiste")
        #expect(Replacements.apply("megagta 6", gta) == "megagta 6")
    }

    @Test("più volte nello stesso testo, la più lunga vince, accenti e maiuscole non contano")
    func several() {
        let rules = [Replacement(spoken: "char studio", written: "Char Studio"),
                     Replacement(spoken: "char", written: "Charcal"),
                     Replacement(spoken: "perché", written: "perché")]
        #expect(Replacements.apply("char studio e char", rules) == "Char Studio e Charcal")
        #expect(Replacements.apply("PERCHE no", rules) == "perché no")
    }

    @Test("senza sostituzioni il testo non cambia")
    func empty() {
        #expect(Replacements.apply("ciao", []) == "ciao")
        #expect(Replacements.apply("ciao", [Replacement(spoken: "", written: "x")]) == "ciao")
    }

    @Test("parole intere davvero: niente decimali, lettere staccate o parole incollate")
    func strictWords() {
        #expect(Replacements.apply("gta 6.5 e gta 6,5", gta) == "gta 6.5 e gta 6,5")
        #expect(Replacements.apply("gta 6-0", gta) == "gta 6-0")
        #expect(Replacements.apply("g ta6 e g t a 6", gta) == "g ta6 e g t a 6")
        #expect(Replacements.apply("gta 6a", gta) == "gta 6a")
        let apostrophe = [Replacement(spoken: "don't", written: "do not")]
        #expect(Replacements.apply("dont stop", apostrophe) == "dont stop")
        #expect(Replacements.apply("Don't stop", apostrophe) == "do not stop")
    }

    @Test("applicate due volte danno lo stesso testo, anche quando la frase scritta contiene quella detta")
    func twice() {
        // La dettatura le applica due volte (dopo le regole e dopo la pulizia): la seconda non deve riscrivere
        // dentro quello che la prima ha già scritto.
        let rules = [Replacement(spoken: "mia mail", written: "mia mail: mario@esempio.it"),
                     Replacement(spoken: "charland", written: "Charland (charstudio.app)"),
                     Replacement(spoken: "ok", written: "ok ok")]
        for text in ["scrivimi alla mia mail domani", "Charland esce a novembre", "ok", "la mia mail e Charland, ok?"] {
            let once = Replacements.apply(text, rules)
            #expect(Replacements.apply(once, rules) == once, "seconda passata diversa per «\(text)»")
        }
        #expect(Replacements.apply("scrivimi alla mia mail domani", rules) == "scrivimi alla mia mail: mario@esempio.it domani")
        #expect(Replacements.apply("Charland esce a novembre", rules) == "Charland (charstudio.app) esce a novembre")
        // Detta di nuovo più avanti nella stessa frase, la regola vale ancora.
        #expect(Replacements.apply("la mia mail: mario@esempio.it è la mia mail", rules)
                == "la mia mail: mario@esempio.it è la mia mail: mario@esempio.it")
    }

    @Test("una regola che è solo un numero non tocca i numeri in lettere")
    func bareNumber() {
        let six = [Replacement(spoken: "6", written: "VI")]
        #expect(Replacements.apply("sei bravo, six times, 6 volte", six) == "sei bravo, six times, VI volte")
    }

    @Test("cinese e giapponese, senza spazi: ogni carattere è una parola")
    func ideographs() {
        let zh = [Replacement(spoken: "明天", written: "TOMORROW")]
        #expect(Replacements.apply("明天我们看项目", zh) == "TOMORROW我们看项目")
        let ja = [Replacement(spoken: "東京", written: "Tokyo")]
        #expect(Replacements.apply("明日は東京に行きます", ja) == "明日はTokyoに行きます")
    }
}
