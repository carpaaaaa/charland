import Testing
@testable import CharlandCore

@Suite("Voce: vocabolario")
struct VocabularyTests {
    let terms = ["Charmail", "Charcal", "Char Studio"] + Vocabulary.common

    /// Un dizionario piccolo per le prove: le parole vere che compaiono nelle frasi.
    func known(_ word: String) -> Bool {
        let real: Set<String> = ["ho", "chiesto", "a", "di", "la", "chiave", "è", "scaduta", "canta", "bene", "at", "il", "codice",
                                 "con", "apri", "cloud", "sul", "salva", "versi", "e", "poi", "su", "amazzone"]
        return real.contains(word.lowercased())
    }

    // MARK: Unione

    @Test("dalla passata col vocabolario si prendono solo i termini: le parole attorno restano quelle sicure")
    func mergeTakesOnlyTerms() {
        // la registrazione vera di carpa del 17 novembre 2026
        #expect(Vocabulary.merge(base: "Allora analizziam c'è GPT e Cloud.", boosted: "Allora analizziami ChatGPT e Claude.", terms: terms)
                == "Allora analizziam ChatGPT e Claude.")
        #expect(Vocabulary.merge(base: "Leggi su charm l ultima mail che hai risposto di Fabrikam, poi leggi nel manuale.",
                                 boosted: "Leggi su Charmail l ultima mail che hai risposto di Fabrikam, poi leggi nel manuale.", terms: terms)
                == "Leggi su Charmail l ultima mail che hai risposto di Fabrikam, poi leggi nel manuale.")
        #expect(Vocabulary.merge(base: "Analizzami Charcal, dimmi cosa manca per metterlo su test flight.",
                                 boosted: "Analizzami Charcal, dimmi cosa manca per metterlo su TestFlight.", terms: terms)
                == "Analizzami Charcal, dimmi cosa manca per metterlo su TestFlight.")
    }

    @Test("un termine scritto in due parole, a cavallo di una parola rimasta uguale, si prende intero")
    func mergeTermAcrossEqualWord() {
        // «gpt» c'è in tutte e due: senza allargare il cambio si giudicherebbe solo «c'è» contro «Chat»
        let merged = Vocabulary.merge(base: "Allora, analizzami c'è Gpt e Cloud.", boosted: "Allora, analizzami Chat GPT e Claude.", terms: terms)
        #expect(merged == "Allora, analizzami Chat GPT e Claude.")
        #expect(Vocabulary.canonicalize(merged, terms: terms) == "Allora, analizzami ChatGPT e Claude.")
        // ma un termine già uguale nelle due passate non trascina dentro le parole vicine
        #expect(Vocabulary.merge(base: "apri Claude Code e legi tutto", boosted: "apri Claude Code e leggi tutto", terms: terms)
                == "apri Claude Code e legi tutto")
    }

    @Test("una parola normale scritta peggio nella seconda passata non passa")
    func mergeKeepsOrdinaryWords() {
        #expect(Vocabulary.merge(base: "leggi su Charmail le ultime mail", boosted: "legi su Charmail le ultime mail", terms: terms)
                == "leggi su Charmail le ultime mail")
        #expect(Vocabulary.merge(base: "Ho comprato il nuovo iPhone ieri pomeriggio.", boosted: "Ho comprato il nuovo iPhone ieri Pomeriggio.", terms: terms)
                == "Ho comprato il nuovo iPhone ieri pomeriggio.")
        #expect(Vocabulary.merge(base: "Il Moccup è su Figma, nella pagina delle icone.", boosted: "Il MUC PESU Figma, nella pagina delle icone.", terms: terms)
                == "Il Moccup è su Figma, nella pagina delle icone.")
    }

    @Test("un termine comparso dal nulla, o al posto di parole che non gli somigliano, è inventato")
    func mergeRejectsInventedTerms() {
        #expect(Vocabulary.merge(base: "con un team the design is postato", boosted: "con YouTube design is postato", terms: terms)
                == "con un team the design is postato")
        #expect(Vocabulary.merge(base: "Allora analizziamo e basta.", boosted: "Allora analizziamo e Python Claude basta.", terms: terms + ["Python"])
                == "Allora analizziamo e basta.")
        // la seconda passata vuota o uguale non cambia niente
        #expect(Vocabulary.merge(base: "ciao a tutti", boosted: "", terms: terms) == "ciao a tutti")
        #expect(Vocabulary.merge(base: "ciao a tutti", boosted: "ciao a tutti", terms: terms) == "ciao a tutti")
        #expect(Vocabulary.merge(base: "", boosted: "ChatGPT", terms: terms) == "")
    }

    @Test("una parola vera non si allunga in un termine: «link» resta «link»")
    func mergeKeepsRealWords() {
        let real: (String) -> Bool = { ["link", "cloud", "test", "flight", "the", "send", "me"].contains($0.lowercased()) }
        #expect(Vocabulary.merge(base: "send me the link.", boosted: "send me the LinkedIn.", terms: terms, isKnownWord: real)
                == "send me the link.")
        // anche senza dizionario: il termine è lungo il doppio di quello che sostituisce
        #expect(Vocabulary.merge(base: "send me the link.", boosted: "send me the LinkedIn.", terms: terms) == "send me the link.")
        // una parola vera che suona come il termine si cambia ancora
        #expect(Vocabulary.merge(base: "chiedi a Cloud di farlo", boosted: "chiedi a Claude di farlo", terms: terms, isKnownWord: real)
                == "chiedi a Claude di farlo")
        #expect(Vocabulary.merge(base: "su test flight.", boosted: "su TestFlight.", terms: terms, isKnownWord: real) == "su TestFlight.")
    }

    @Test("l'apostrofo non nasconde il termine, e gli spazi restano giusti")
    func mergeApostrophes() {
        #expect(Vocabulary.merge(base: "Pubblichiamo sull'ap stor lunedì.", boosted: "Pubblichiamo sull'App Store lunedì.", terms: terms)
                == "Pubblichiamo sull'App Store lunedì.")
        #expect(Vocabulary.merge(base: "un po' di clod oggi", boosted: "un po' di Claude oggi", terms: terms) == "un po' di Claude oggi")
    }

    // MARK: Grafia

    @Test("le stesse lettere, scritte staccate o con altre maiuscole, diventano il termine")
    func canonical() {
        #expect(Vocabulary.canonicalize("Usa chat GPT per tradurre.", terms: terms) == "Usa ChatGPT per tradurre.")
        #expect(Vocabulary.canonicalize("chat g p t e chatgpt", terms: terms) == "ChatGPT e ChatGPT")
        #expect(Vocabulary.canonicalize("metterlo su test flight.", terms: terms) == "metterlo su TestFlight.")
        #expect(Vocabulary.canonicalize("l'ho aperto con X Code.", terms: terms) == "l'ho aperto con Xcode.")
        #expect(Vocabulary.canonicalize("gira su NextJS con il wifi", terms: terms) == "gira su Next.js con il Wi-Fi")
        #expect(Vocabulary.canonicalize("versione sull'app store lunedì", terms: terms) == "versione sull'App Store lunedì")
        #expect(Vocabulary.canonicalize("Paga con Paypal", terms: terms) == "Paga con PayPal")
        #expect(Vocabulary.canonicalize("leggi su Char Mail e char studio", terms: terms) == "leggi su Charmail e Char Studio")
    }

    @Test("quello che è già giusto non cambia, e le frasi normali nemmeno")
    func canonicalLeavesTheRest() {
        let plain = "Domani alle dieci ho il dentista, ricordami di portare le lastre."
        #expect(Vocabulary.canonicalize(plain, terms: terms) == plain)
        #expect(Vocabulary.canonicalize("ChatGPT, Claude Code e Wi-Fi.", terms: terms) == "ChatGPT, Claude Code e Wi-Fi.")
        // «i cloud provider» non è iCloud; due parole separate da una virgola non sono un termine
        #expect(Vocabulary.canonicalize("i cloud provider costano", terms: terms) == "i cloud provider costano")
        #expect(Vocabulary.canonicalize("apri la chat, gpt non serve", terms: terms) == "apri la chat, gpt non serve")
        #expect(Vocabulary.canonicalize("", terms: terms) == "")
        #expect(Vocabulary.canonicalize("ciao", terms: []) == "ciao")
    }

    // MARK: Quasi uguali

    @Test("una parola che non esiste, a una lettera da un termine, è il termine")
    func near() {
        #expect(Vocabulary.nearMisses("La chiave di OpenAy è scaduta", terms: terms, isKnownWord: known) == "La chiave di OpenAI è scaduta")
        #expect(Vocabulary.nearMisses("Ho chiesto a C at GPT di", terms: terms, isKnownWord: known) == "Ho chiesto a ChatGPT di")
        #expect(Vocabulary.nearMisses("la canzone su Spotifi.", terms: terms, isKnownWord: known) == "la canzone su Spotify.")
        #expect(Vocabulary.nearMisses("database su Superbase", terms: terms, isKnownWord: known) == "database su Supabase")
    }

    @Test("le parole vere restano, e un termine già giusto non si allarga sulle parole vicine")
    func nearIsCareful() {
        #expect(Vocabulary.nearMisses("canta bene", terms: terms, isKnownWord: known) == "canta bene")
        #expect(Vocabulary.nearMisses("salva sul cloud", terms: terms, isKnownWord: known) == "salva sul cloud")
        #expect(Vocabulary.nearMisses("deploy su Vercel e poi apri", terms: terms, isKnownWord: known) == "deploy su Vercel e poi apri")
        #expect(Vocabulary.nearMisses("aperto con X codice", terms: terms, isKnownWord: known) == "aperto con X codice")
        // iniziale diversa o troppe lettere di differenza: non si indovina
        #expect(Vocabulary.nearMisses("su Wersel", terms: terms, isKnownWord: known) == "su Wersel")
        #expect(Vocabulary.nearMisses("il Midboot", terms: terms, isKnownWord: known) == "il Midboot")
    }

    // MARK: Parole per il motore

    @Test("le parole per il motore: una per riga, col punteggio, senza doppioni né segni che lo confondono")
    func hotwords() {
        let line = Vocabulary.hotwords(user: ["Charmail", "chatgpt", " :strano/ nome ", ""], common: ["ChatGPT", "Claude"])
        #expect(line == "Charmail :2.0/chatgpt :2.0/strano nome :2.0/Claude :1.5")
        #expect(Vocabulary.hotwords(user: ["日本語", "Perù"], common: [], encodable: { !$0.contains("日") }) == "Perù :2.0")
        #expect(Vocabulary.hotwords(user: [], common: []) == "")
    }

    @Test("i termini presenti nel testo, per dirli al modello che pulisce")
    func present() {
        #expect(Vocabulary.present(in: "Ho chiesto a chat gpt e a Claude.", terms: terms) == ["ChatGPT", "Claude"])
        #expect(Vocabulary.present(in: "Domani piove.", terms: terms).isEmpty)
    }

    @Test("il confronto fra due testi lunghi resta veloce: inizio e fine uguali si saltano")
    func diffSkipsEqualEnds() {
        let a = (0..<3000).map { "p\($0)" }
        var b = a
        b[1500] = "diversa"
        let ops = Diff.operations(a, b)
        #expect(ops?.count == 3)
        #expect(ops?[1] == Diff.Operation(a: 1500..<1501, b: 1500..<1501, equal: false))
    }
}
