# La dettatura di Charland

Scritto il 17 novembre 2026, dopo aver smontato OpenWhispr 1.11.0 e misurato tutto su questo Mac (MacBook Air M5, macOS 27.3). I numeri sono misure, non stime; dove una cosa non è stata provata lo dice.

## Che cosa fa meglio OpenWhispr, e che cosa no

- **Il motore è lo stesso.** OpenWhispr fa girare Orukeet con sherpa-onnx in modalità greedy, senza vocabolario e senza altro: gli stessi errori di Charland, parola per parola. Anche lei scriveva «c'è GPT e Cloud» al posto di «ChatGPT e Claude» (è nel suo storico, grezzo e pulito).
- **La sua differenza era la pulizia**: un modello nel cloud (OpenWhispr Cloud) che toglie le false partenze, sistema la grammatica e la punteggiatura. Il suo dizionario personale arriva solo a quel modello, mai al motore vocale.
- **Per il resto**: apre il microfono al tasto come noi, taglia le dettature oltre i 15 secondi (ma solo alla fine), riprova una volta se una frase esce vuota.

## La catena di Charland, dal tasto al testo

1. **Microfono preparato, ma spento.** La presa è montata e il motore dell'audio è pronto da prima (`AudioCapture.warmUp`); il microfono resta spento e il sistema non lo segna in uso. Al tasto si accende in 50 ms invece di 200: l'attacco della prima parola non si perde. Con un microfono Bluetooth non si prepara niente (certe cuffie passerebbero alla modalità chiamata).
2. **Pezzi mentre parli.** Ogni mezzo secondo `LiveTranscript` guarda l'audio non ancora trascritto: oltre i 17 secondi lo taglia nel punto più silenzioso fra 9 e 17 (`AudioSegmenter.cut`) e trascrive il pezzo. Al rilascio resta solo la coda.
3. **Due letture della stessa analisi.** Il motore (sherpa-onnx con la modifica di Charland) analizza l'audio una volta e lo legge in due modi: la passata sicura (greedy) e la ricerca a fascio che favorisce le parole del vocabolario.
4. **Unione.** `Vocabulary.merge` tiene la passata sicura e prende dall'altra solo i pezzi cambiati che portano un termine del vocabolario e che somigliano a quello che c'era.
5. **Grafia.** `Vocabulary.canonicalize`: «test flight», «chat gpt», «X Code» diventano «TestFlight», «ChatGPT», «Xcode» (stesse lettere, scritte staccate o con altre maiuscole). `Vocabulary.nearMisses`: una parola che il dizionario del Mac non conosce, a una lettera da un termine, è il termine («OpenAy», «Outrook», «C at GPT»).
6. **Regole, sostituzioni, pulizia.** `TextRules` (esitazioni, punteggiatura dettata, apostrofi persi, frasi ripetute per falsa partenza, maiuscole), `Replacements`, poi il modello di Apple (vedi «La pulizia»). Ogni pezzo chiuso mentre parli viene anche finito: al rilascio resta da pulire solo l'ultimo.
7. **Nel campo.** Appunti e ⌘V finto, o tasto per tasto dove serve. Senza Accessibilità il testo va negli appunti e l'isola dice come dare il permesso.

## Il vocabolario

- **Personale** (Impostazioni › Voce › Vocabolario): le parole di chi usa l'app, punteggio 2,0.
- **Di serie** (`Vocabulary.common`, un'ottantina di nomi: ChatGPT, Claude, iPhone, TestFlight, GitHub, WhatsApp…), punteggio 1,5, si spegne con un interruttore. Solo nomi propri: un marchio che è anche una parola comune in italiano o in inglese («Slack», «Notion», «Zoom», «Outlook», le «API») non c'è, chi lo usa lo aggiunge al suo.
- Vale anche per le parole dal vivo nell'isola, e col riconoscimento di Apple vale la sola grafia.

### Perché due letture e non la ricerca a fascio da sola

Misurato su 44 frasi normali, 40 con nomi di app e servizi (pronuncia italiana), 22 di controllo senza nomi e 6 registrazioni vere di carpa:

| | Errori sulle frasi normali | Nomi scritti giusti | Frasi vuote |
|---|---|---|---|
| Passata sicura (com'era) | 35 su 535 parole | 28 su 51 | 0 |
| Ricerca a fascio da sola | 42 su 535 | 26 su 51 | 2 |
| Ricerca a fascio col vocabolario | 39 su 535 | 41 su 51 | 0 |
| **Unione, grafia e quasi uguali** | **35 su 535** | **45 su 51** | **0** |

La ricerca a fascio sbaglia più della passata sicura sulle parole normali, ogni tanto restituisce una frase vuota, e col vocabolario a volte inventa un termine («con un team» diventato «con YouTube»). L'unione prende il meglio delle due: stessi errori di prima sulle frasi normali (una sola delle 66 cambia, in meglio: «Vercell» diventa «Vercel»), e i nomi giusti quasi sempre. I sei che restano sono frasi che la voce sintetica storpia («Midboot» per MacBook) più «Slack», che nell'elenco di serie non c'è apposta.

La registrazione vera del 17 novembre, «Allora analizziam c'è GPT e Cloud.», esce «Allora analizziam ChatGPT e Claude.».

### Perché la libreria è modificata

La libreria ufficiale decide il modo di leggere quando carica il modello, e non lo cambia più (provato: `SherpaOnnxOfflineRecognizerSetConfig` con i modelli NeMo non cambia decodificatore, e un flusso con le parole su un riconoscitore greedy fa cadere il processo). Per avere le due letture servirebbero due modelli in memoria: 950 MB l'uno. La modifica (`Scripts/sherpa-onnx-charland.patch`, una cinquantina di righe) dà allo stesso modello i due decodificatori: un flusso senza parole usa solo il greedy, un flusso con le parole restituisce la lettura a fascio in `text` e quella greedy in `lang`. L'analisi dell'audio si fa una volta: le due letture costano circa 30 ms in più su una frase di 4 secondi.

- Si compila con `Scripts/compila-sherpa.sh` (lo chiama `Scripts/scarica-dipendenze.sh`); serve cmake, che lo script si procura da solo in un ambiente Python suo.
- ONNX Runtime resta quello dell'archivio ufficiale: quello che scarica cmake è lo stesso numero di versione ma occupa 700 MB in più di memoria.
- La libreria modificata si riconosce dalla versione, `2.0.1+charland.1`. Senza (o con un modello senza `bpe.vocab`) Charland torna da sola alla sola passata sicura, più la grafia.
- Il modello deve avere accanto `bpe.vocab`: Orukeet lo porta, a Parakeet v3 originale lo mette `ModelStore.ensureVocabulary` (stessi pezzi, stessa impronta di `tokens.txt`).
- Una parola con caratteri che il modello non sa scrivere (giapponese, emoji) non si manda al motore: verrebbe tagliata a metà e favorirebbe un pezzo qualunque.

## La pulizia

La cosa che OpenWhispr faceva meglio. Charland la fa sul Mac, col modello di Apple (Foundation Models), e ogni uscita passa da un controllo: se non lo supera, o arriva tardi, vale il testo a regole.

Misurato il 17 novembre 2026 su 65 frasi (le cinque coppie vere grezzo/pulito di OpenWhispr, esitazioni, autocorrezioni, domande e ordini che non vanno eseguiti, numeri, indirizzi, italiano con termini inglesi, inglese, spagnolo, francese, tedesco, dettature lunghe):

| | Com'era | Adesso |
|---|---|---|
| Frasi uscite migliori | 12 su 65 | 46 su 65 |
| Restituite uguali | 42 | 11 |
| Rifiuti del modello («contenuto pericoloso») | 2 | 0 |
| Uscite che rompono una regola | 4 (fermate dal controllo) | 0 accettate |
| Fuori tempo | 5 (tetto fisso di 1,3 s) | 1 |

Che cosa è cambiato:

- **Istruzioni in inglese con nove esempi**, quasi tutti in italiano (`ModelCleaner.instructions`). Le stesse in italiano davano 33 frasi migliori invece di 47 e traducevano l'inglese; senza esempi il modello rispondeva alle domande («La capitale della Francia è Parigi.»).
- **Il trascritto fra due etichette e nient'altro.** Le regole ripetute dopo il testo, com'era prima, facevano ricopiare l'ingresso: 42 frasi su 65 tornavano uguali.
- **Filtri per le trasformazioni** (`.permissiveContentTransformations`): con quelli di serie «questo cazzo di bug» e «mi sono tagliato un dito e sanguina» venivano rifiutati.
- **Tempo in proporzione alle parole**: `max(1,2; 0,7 + 0,045 × parole)` secondi. Il modello ci mette circa 0,28 s più 22 ms a parola a Mac tranquillo, il doppio o il triplo a Mac occupato.
- **Sessione pronta**: al tasto una sessione legge già le istruzioni (617 token su 650 restano in memoria), e mentre un pezzo si pulisce si prepara quella per il successivo. Una frase normale torna in circa mezzo secondo.
- **Testi lunghi a gruppi di frasi intere** (`TextChunker`, al massimo 55 parole), uno dopo l'altro, ognuno col suo controllo. A pezzi di lunghezza fissa il testo si rovinava nei tagli; in parallelo non si guadagna niente.
- **I termini del vocabolario** arrivano al modello già scritti giusti, e solo quelli che nel testo ci sono, come parole da non toccare. Con l'elenco fisso nelle istruzioni, com'era prima, una volta il modello ne ha aggiunto uno in fondo alla frase («GTA VI.»).
- **Nell'app di Claude ora si pulisce.** Era nell'elenco delle app «alla lettera» insieme a Xcode e ai terminali: lì le dettature uscivano senza maiuscole, senza punto e senza pulizia.

Le registrazioni vere, com'erano e come escono adesso:

| Grezzo | OpenWhispr (cloud) | Charland |
|---|---|---|
| leggi su charm leggi su Charmail le ultime l'ultima mail che mi ha risposto | Leggi su Charm, leggi su Charmail, l'ultima mail che mi ha risposto. | Leggi su Charmail l'ultima mail che mi ha risposto. |
| Analizzami Charcal, dimmi cosa manca per metterlo su test flight. | …su Test Flight. | Analizzami Charcal. Dimmi cosa manca per metterlo su TestFlight. |
| La scritta oggi praticamente va sopra e cambia, diventa più piccola. Appare uno sfondo blurrato e poi però scompare quel blur, tipo. fa un effetto un po' glitchy. | La scritta oggi va sopra e cambia, diventando più piccola. Appare uno sfondo blurrato e poi, però, scompare quel blur, tipo, facendo un effetto un po' glitchy. | La scritta oggi va sopra e cambia, diventa più piccola. Appare uno sfondo blurrato, poi scompare quel blur. Fa un effetto un po' glitchy. |
| Allora analizzami c'è GPT e Cloud. | Allora, analizzami: c'è GPT e Cloud. | Allora analizziamo ChatGPT e Claude. |

### Il controllo (`CleanupGuard`)

Allinea parola per parola il testo a regole e l'uscita del modello e giudica ogni parola tolta e ogni parola aggiunta, invece di contare percentuali. Passano le esitazioni tolte, le false partenze, la parte sbagliata di un'autocorrezione, la punteggiatura rifatta, un errore di battitura corretto. Si fermano: una risposta, un ordine eseguito, una traduzione, un numero o un nome cambiato, perso o aggiunto, una negazione che sparisce, una parolaccia tolta, un termine del vocabolario comparso dove non era stato detto, un pezzo di frase perso. Su uscite vere del modello: 92 buone su 92 accettate (quello di prima ne scartava 13), 56 su 58 che rompono una regola fermate (prima ne passavano 14); le 85 coppie scritte a mano sono nei test.

Il modello certi ordini li esegue sempre («traduci in inglese…», «correggi la grammatica di questa frase…»): li ferma solo il controllo.

### Che cosa non ha funzionato

Istruzioni in italiano o nella lingua del testo, niente esempi, esempi come turni di conversazione (ha tradotto il tedesco in italiano), regole ripetute dopo il testo, `prewarm(promptPrefix:)` (non più veloce), pezzi di lunghezza fissa, pezzi in parallelo. Non provati: generazione guidata, altri modi di campionare, riuso della stessa sessione.

## Dettature lunghe

Il motore legge tutto l'audio insieme, e il costo cresce molto più in fretta della durata:

| Durata | In un colpo solo (com'era) | A pezzi mentre parli |
|---|---|---|
| 5 s | 0,1 s | 0,1 s |
| 61 s | 2,1 s | **0,4 s** dopo il rilascio (1,2 s con la pulizia dell'ultimo pezzo) |
| 129 s | 5,3 s | resta solo la coda |
| 311 s | 25,9 s e 8,2 GB di memoria | resta solo la coda |

In un colpo solo sbaglia anche di più («Vercelle poi», «branchmine»). Dove il taglio cade in mezzo a una frase (nessuna pausa vera) `AudioSegmenter.join` toglie il punto che il motore mette a fine pezzo e la maiuscola del pezzo dopo, se è una parola comune e non un nome.

## Frasi vuote

Se il motore non scrive niente ma c'è voce, si riprova una volta con 0,6 s di silenzio ai due lati: con una voce che parte di colpo recupera 11 frasi su 12. Sempre no: sulle frasi normali il cuscino aggiunge qualche errore (misurato il 16 novembre).

## Prove

- `Scripts/build.sh`, poi `Charland --dictate-file <wav>...`: ogni file passa dalla catena intera, con e senza pulizia; stampa grezzo e finale.
- `CHARLAND_VOCE=1`: scrive nel terminale microfono, pezzi chiusi mentre si parla, tempi e testo di ogni dettatura.
- `CHARLAND_VOCABOLARIO="Charmail/Rossi"` al posto del vocabolario salvato, `-` per nessuno.
- `CHARLAND_MICROFONO_FINTO=<wav> CHARLAND_HOLD=<secondi> CHARLAND_NON_SCRIVERE=1 Charland --demo dalvivo`: una dettatura vera senza parlare e senza scrivere da nessuna parte.
- `Charland --voce`: solo la sezione Voce delle impostazioni in una finestra; `CHARLAND_PREPARAZIONE=modello,microfono,accessibilita` finge che quei passi manchino.
- I test: `swift test` in `Packages/CharlandCore` (`VocabularyTests`, `AudioSegmenterTests`, `TextChunkerTests`, `CleanupGuardTests` con le 85 coppie): 106 in tutto.
- Il banco della pulizia (65 frasi, tutte le varianti provate) non è nel progetto: era nello scratchpad della sessione del 17 novembre. Le istruzioni e il controllo che ne sono usciti sono nel codice.

## Trappole trovate

- Le voci «Eloquence» del Mac (Eddy, Reed, Sandy, Shelley, Flo, Rocko) sono robotiche: il motore le prende per inglese o non scrive niente. Per le prove coi nomi solo Alice, con la pronuncia italiana scritta a orecchio («ciat gi pi ti»).
- `SherpaOnnxOfflineRecognizerSetConfig` non cambia il decodificatore dei modelli NeMo; `SherpaOnnxCreateOfflineStreamWithHotwords` su un riconoscitore greedy fa cadere il processo.
- Nel silenzio assoluto la somma che scorre delle energie può scendere sotto zero per arrotondamento, e la radice dà «non un numero»: l'energia della finestra scelta si ricalcola da capo.
- Spegnere `AVAudioEngine` libera quello che `prepare()` aveva preparato: va preparato di nuovo dopo ogni dettatura.
- La prima risposta del modello di Apple in un processo appena partito costa 1,5 s invece di 0,3: una prova con `--dictate-file` dà «timeout» sul primo file e basta.
- Con la sessione scaldata o no l'uscita del modello cambia, a parità di testo: le prove vanno fatte come nell'uso vero, scaldata.
- `TextRules.capitalizeSentences` metteva la maiuscola dopo ogni punto: «mario.Rossi@example.Com», «layout.Tsx». Ora solo se dopo il punto c'è uno spazio.
- Le parole doppie corte si toglievano anche quando erano cifre dette a voce («tre tre otto» diventava «tre otto»).
