# Confronto della voce

(Per la pubblicazione tre frasi di prova sono state sostituite con frasi neutre, e nomi e cifre nelle trascrizioni di quelle frasi sono adattati di conseguenza; il numero di errori e i tempi sono quelli misurati.)

Fatto il 16 novembre 2026, 23:57 su questo Mac, con `Charland --bench-voice`.

Le stesse 44 frasi (38 in italiano, 6 in inglese), dette dalle voci di sistema, passano da ogni motore. Gli errori sono contati per parola, senza badare a maiuscole e punteggiatura, e con i numeri in cifre ("alle dieci" e "alle 10" valgono uguale). I tempi vanno dall'invio dell'audio al testo.

Limite di questa prova: le voci di sistema sono pulite e senza rumore, e pronunciano male le parole inglesi dentro le frasi italiane. Serve a confrontare i motori alla pari, non a dire quanto sbagliano con una voce vera.

| Motore | Errori in italiano | Errori in inglese | Tempo medio | Tempo peggiore |
|---|---|---|---|---|
| OpenWhispr (Orukeet) | 21 su 467 parole (4.5%) | 0 su 68 parole (0.0%) | 107 ms | 303 ms |
| Charland (Orukeet v0.1.0) | 21 su 467 parole (4.5%) | 0 su 68 parole (0.0%) | 90 ms | 148 ms |
| Charland (Parakeet v3) | 24 su 467 parole (5.1%) | 0 su 68 parole (0.0%) | 127 ms | 271 ms |

- Charland carica Orukeet v0.1.0 in 0.64 s.
- Charland carica Parakeet v3 in 0.65 s.
- Motore di Charland: sherpa-onnx 2.0.1, rete chiusa: sì.
- Provato e scartato: aggiungere 0,3 s di silenzio prima e dopo la frase non riduce gli errori, anzi ne aggiunge qualcuno.

## Frase per frase

**1.** Domani alle dieci ho il dentista, ricordami di portare le lastre. (3.9 s, voce Alice)

- OpenWhispr (Orukeet): Domani alle dieci ho il dentista, ricordami di portare le lastre. (giusta, 95 ms)
- Charland (Orukeet v0.1.0): Domani alle dieci ho il dentista, ricordami di portare le lastre. (giusta, 102 ms)
- Charland (Parakeet v3): Domani alle 10 ho il dentista, ricordami di portare le lastre. (giusta, 114 ms)

**2.** Ho parlato con Rossi e il fornitore: la consegna parte lunedì mattina. (4.8 s, voce Eddy (Italian (Italy)))

- OpenWhispr (Orukeet): Ho parlato con Rossi e il fornitore. La consegna parte lunedì mattina. (giusta, 96 ms)
- Charland (Orukeet v0.1.0): Ho parlato con Rossi e il fornitore. La consegna parte lunedì mattina. (giusta, 99 ms)
- Charland (Parakeet v3): Ho parlato con Rosi e il fornitore. La consegna parte il lunedì mattina. (2 errori, 131 ms)

**3.** Fai il deploy su Vercel e poi apri una pull request sul branch main. (3.8 s, voce Alice)

- OpenWhispr (Orukeet): File deploy su Vercell e poi apri una pull request sul branch main. (3 errori, 81 ms)
- Charland (Orukeet v0.1.0): File deploy su Vercell e poi apri una pull request sul branch main. (3 errori, 79 ms)
- Charland (Parakeet v3): Fai il deploy su Vercelle e poi apri una pull request sul branch main. (1 errori, 105 ms)

**4.** Il meeting con il team di design è spostato a giovedì alle quindici e trenta. (4.4 s, voce Reed (Italian (Italy)))

- OpenWhispr (Orukeet): con il team di design spostato a giovedì alle quinci e trenta. (4 errori, 92 ms)
- Charland (Orukeet v0.1.0): You're connuti spostato a giovedì alle quindice e trenta. (9 errori, 92 ms)
- Charland (Parakeet v3): You're in connutime design spostato a giovedì alle 1530. (10 errori, 135 ms)

**5.** Costa venticinque euro al mese e quaranta all'anno, con sette giorni di prova. (5.2 s, voce Eddy (Italian (Italy)))

- OpenWhispr (Orukeet): Costa venti cinque euro al mese e quaranta all'anno, con sette giorni di prova. (giusta, 105 ms)
- Charland (Orukeet v0.1.0): Costa 25 euro al mese e quaranta all'anno, con sette giorni di prova. (giusta, 105 ms)
- Charland (Parakeet v3): Costa 25 euro al mese e 40 all'anno, con 7 giorni di prova. (giusta, 147 ms)

**6.** Scrivi a Marco che arrivo tra venti minuti, traffico permettendo. (4.1 s, voce Alice)

- OpenWhispr (Orukeet): Scrivi a Marco che arrivo tra 20 minuti, traffico permettendo. (giusta, 85 ms)
- Charland (Orukeet v0.1.0): Scrivi a Marco che arrivo tra 20 minuti, traffico permettendo. (giusta, 86 ms)
- Charland (Parakeet v3): Scrivi a Marco che arrivo tra 20 minuti, traffico permettendo. (giusta, 115 ms)

**7.** Non so se convenga usare la finestra nuova o quella vecchia per le impostazioni. (4.8 s, voce Sandy (Italian (Italy)))

- OpenWhispr (Orukeet): Non so se come usare la finestra nuova o quella vecchia delle impostazioni. (3 errori, 96 ms)
- Charland (Orukeet v0.1.0): Non so se come cammare la finestra nuova o quella vecchia delle impostazioni. (4 errori, 103 ms)
- Charland (Parakeet v3): Non so se come camminare la finestra nuova o quella vecchia delle impostazioni. (4 errori, 139 ms)

**8.** Ricordati di comprare il latte, il pane e sei uova prima delle sette di sera. (4.5 s, voce Alice)

- OpenWhispr (Orukeet): Ricordati di comprare il latte, il pane e sei uova prima delle sette di sera. (giusta, 93 ms)
- Charland (Orukeet v0.1.0): Ricordati di comprare il latte, il pane e sei uova prima delle sette di sera. (giusta, 95 ms)
- Charland (Parakeet v3): Ricordati di comprare il latte, il pane e sei uova prima delle 7 di sera. (giusta, 129 ms)

**9.** La riunione del team è fissata per il due dicembre. (4.3 s, voce Shelley (Italian (Italy)))

- OpenWhispr (Orukeet): La riunione del team è fissata per il due dicembre. (giusta, 95 ms)
- Charland (Orukeet v0.1.0): La riunione del team è fissata per il 2 dicembre. (giusta, 94 ms)
- Charland (Parakeet v3): La riunione del team è fissata per il 2 dicembre. (giusta, 128 ms)

**10.** Il nuovo portatile ha uno schermo da quindici pollici e pesa un chilo e mezzo. (4.6 s, voce Eddy (Italian (Italy)))

- OpenWhispr (Orukeet): Il nuovo portatile ha uno schermo da quindici pollici e pesa un chilo e mezzo. (giusta, 93 ms)
- Charland (Orukeet v0.1.0): Il nuovo portatile ha uno schermo da quindici pollici e pesa un chilo e mezzo. (giusta, 99 ms)
- Charland (Parakeet v3): Il nuovo portatile ha uno schermo da 15 pollici e pesa un chilo e mezzo. (giusta, 135 ms)

**11.** Aggiungi una cosa da fare: chiamare il commercialista entro venerdì. (3.8 s, voce Alice)

- OpenWhispr (Orukeet): Aggiungi una cosa da fare, chiamare il commercialista entro venerdì. (giusta, 78 ms)
- Charland (Orukeet v0.1.0): Aggiungi una cosa da fare, chiamare il commercialista entro venerdì. (giusta, 79 ms)
- Charland (Parakeet v3): Aggiungi una cosa da fare, chiamare il commercialista entro venerdì. (giusta, 107 ms)

**12.** Secondo me la versione di ieri era più chiara, ma questa è più corta. (4.3 s, voce Reed (Italian (Italy)))

- OpenWhispr (Orukeet): Secondo me la versione di ieri era più chiara, ma questa è più corta. (giusta, 91 ms)
- Charland (Orukeet v0.1.0): Secondo me la versione di ieri era più chiara, ma questa è più corta. (giusta, 90 ms)
- Charland (Parakeet v3): Secondo me la versione di ieri era più chiara, ma questa è più corta. (giusta, 124 ms)

**13.** Mandami il preventivo entro stasera, così domattina lo giro al cliente. (4.3 s, voce Alice)

- OpenWhispr (Orukeet): Mandami il preventivo entro stasera, così domattina lo giro al cliente. (giusta, 88 ms)
- Charland (Orukeet v0.1.0): Mandami il preventivo entro stasera, così domattina lo giro al cliente. (giusta, 90 ms)
- Charland (Parakeet v3): Mandami il preventivo entro stasera, così domattina lo giro al cliente. (giusta, 124 ms)

**14.** Abbiamo prenotato un tavolo per quattro persone alle otto e mezza. (4.1 s, voce Sandy (Italian (Italy)))

- OpenWhispr (Orukeet): Abbiamo prenotato un tavolo per quattro persone alle otto e mezza. (giusta, 99 ms)
- Charland (Orukeet v0.1.0): Abbiamo prenotato un tavolo per quattro persone alle otto e mezza. (giusta, 88 ms)
- Charland (Parakeet v3): Abbiamo prenotato un tavolo per quattro persone alle otto e mezza. (giusta, 121 ms)

**15.** Ciao Marco, ti confermo l'appuntamento di domani pomeriggio alle quattro. (4.3 s, voce Alice)

- OpenWhispr (Orukeet): Ciao Marco, ti confermo l'appuntamento di domani pomeriggio alle 4. (giusta, 99 ms)
- Charland (Orukeet v0.1.0): Ciao Marco, ti confermo l'appuntamento di domani pomeriggio alle 4. (giusta, 93 ms)
- Charland (Parakeet v3): Ciao Marco, ti confermo l'appuntamento di domani pomeriggio alle 4. (giusta, 128 ms)

**16.** Ho finito la prima versione del progetto, te la mando appena torno a casa. (4.8 s, voce Eddy (Italian (Italy)))

- OpenWhispr (Orukeet): Ho finito la prima versione del progetto, te la mano appena torno a casa. (1 errori, 95 ms)
- Charland (Orukeet v0.1.0): Ho finito la prima versione del progetto, te la mando appena torno a casa. (giusta, 102 ms)
- Charland (Parakeet v3): Ho finito la prima versione del progetto, te la mando appena torno a casa. (giusta, 134 ms)

**17.** Potresti controllare se il pagamento è arrivato sul conto questa mattina? (4.1 s, voce Alice)

- OpenWhispr (Orukeet): Potresti controllare se il pagamento è arrivato sul conto questa mattina. (giusta, 84 ms)
- Charland (Orukeet v0.1.0): Potresti controllare se il pagamento è arrivato sul conto questa mattina. (giusta, 87 ms)
- Charland (Parakeet v3): Potresti controllare se il pagamento è arrivato sul conto questa mattina. (giusta, 118 ms)

**18.** Stasera non riesco a venire, ho un impegno che non posso spostare. (4.3 s, voce Eddy (Italian (Italy)))

- OpenWhispr (Orukeet): Stasera non riesco venire, con impegno che non posso spostare. (3 errori, 93 ms)
- Charland (Orukeet v0.1.0): Stasera non riesco a venire, con impegno che non posso spostare. (2 errori, 90 ms)
- Charland (Parakeet v3): Stasera non riesco a venire, con impegno che non posso spostare. (2 errori, 125 ms)

**19.** Il treno parte alle sette e venti dal binario tre, non fare tardi. (3.9 s, voce Alice)

- OpenWhispr (Orukeet): Il treno parte alle 7.20 dal binario 3, non fare tardi. (1 errori, 88 ms)
- Charland (Orukeet v0.1.0): Il treno parte alle 7.20 dal binario 3, non fare tardi. (1 errori, 88 ms)
- Charland (Parakeet v3): Il treno parte alle 7.20 dal binario 3, non fare tardi. (1 errori, 110 ms)

**20.** Grazie per la risposta, ci sentiamo la settimana prossima con più calma. (4.7 s, voce Eddy (Italian (Italy)))

- OpenWhispr (Orukeet): Grazie per la risposta, ci sentiamo la settimana prossima con più calma. (giusta, 96 ms)
- Charland (Orukeet v0.1.0): Grazie per la risposta, ci sentiamo la settimana prossima con più calma. (giusta, 99 ms)
- Charland (Parakeet v3): Grazie per la risposta, ci sentiamo la settimana prossima con più calma. (giusta, 133 ms)

**21.** Mi serve una copia del contratto firmato entro la fine del mese. (3.6 s, voce Alice)

- OpenWhispr (Orukeet): Mi serve una copia del contratto firmato entro la fine del mese. (giusta, 92 ms)
- Charland (Orukeet v0.1.0): Mi serve una copia del contratto firmato entro la fine del mese. (giusta, 81 ms)
- Charland (Parakeet v3): Mi serve una copia del contratto firmato entro la fine del mese. (giusta, 108 ms)

**22.** Abbiamo deciso di rimandare la presentazione a quando saranno pronti i dati. (4.7 s, voce Eddy (Italian (Italy)))

- OpenWhispr (Orukeet): Abbiamo deciso di rimandare la presentazione a quando saranno pronti i dati. (giusta, 118 ms)
- Charland (Orukeet v0.1.0): Abbiamo deciso di rimandare la presentazione a quando saranno pronti i dati. (giusta, 103 ms)
- Charland (Parakeet v3): Abbiamo deciso di rimandare la presentazione a quando saranno pron i dati. (1 errori, 133 ms)

**23.** Ricordami di chiamare la banca prima di mezzogiorno per sbloccare la carta. (4.2 s, voce Alice)

- OpenWhispr (Orukeet): Ricordami di chiamare la banca prima di mezzogiorno per sbloccare la carta. (giusta, 107 ms)
- Charland (Orukeet v0.1.0): Ricordami di chiamare la banca prima di mezzogiorno per sbloccare la carta. (giusta, 87 ms)
- Charland (Parakeet v3): Ricordami di chiamare la banca prima di mezzogiorno per sbloccare la carta. (giusta, 115 ms)

**24.** La nuova casa ha tre camere, due bagni e un giardino piccolo ma comodo. (4.6 s, voce Eddy (Italian (Italy)))

- OpenWhispr (Orukeet): La nuova casa ha tre camere, due vai e un giardino piccolo ma comodo. (1 errori, 121 ms)
- Charland (Orukeet v0.1.0): La nuova casa ha tre camere, due bai e un giardino piccolo ma comodo. (1 errori, 97 ms)
- Charland (Parakeet v3): La nuova casa ha tre camere, due vai e un giardino piccolo ma comodo. (1 errori, 128 ms)

**25.** Secondo te conviene partire venerdì sera oppure sabato mattina presto? (4.3 s, voce Alice)

- OpenWhispr (Orukeet): Secondo te conviene partire venerdì sera oppure sabato mattina presto? (giusta, 144 ms)
- Charland (Orukeet v0.1.0): Secondo te conviene partire venerdì sera oppure sabato mattina presto? (giusta, 103 ms)
- Charland (Parakeet v3): Secondo te conviene partire venerdì sera oppure sabato mattina presto? (giusta, 121 ms)

**26.** Ho letto il documento e ci sono un paio di punti che non mi convincono. (4.2 s, voce Eddy (Italian (Italy)))

- OpenWhispr (Orukeet): Ho letto il documento e ci sono un paio di punti che non mi convincono. (giusta, 108 ms)
- Charland (Orukeet v0.1.0): Ho letto il documento e ci sono un paio di punti che non mi convincono. (giusta, 89 ms)
- Charland (Parakeet v3): Ho letto il documento e ci sono un paio di punti che non mi convincono. (giusta, 120 ms)

**27.** Il medico ha detto di prendere una compressa dopo i pasti per dieci giorni. (4.1 s, voce Alice)

- OpenWhispr (Orukeet): Il medico ha detto di prendere una compressa dopo i pasti per dieci giorni. (giusta, 115 ms)
- Charland (Orukeet v0.1.0): Il medico ha detto di prendere una compressa dopo i pasti per dieci giorni. (giusta, 92 ms)
- Charland (Parakeet v3): Il medico ha detto di prendere una compressa dopo i pasti per dieci giorni. (giusta, 117 ms)

**28.** Possiamo vederci al bar sotto l'ufficio, quello con i tavoli fuori. (4.2 s, voce Eddy (Italian (Italy)))

- OpenWhispr (Orukeet): Possiamo vederci al bar sotto l'ufficio, quello con i tavoli fuori. (giusta, 110 ms)
- Charland (Orukeet v0.1.0): Possiamo vederci al bar sotto l'ufficio, quello con i tavoli fuori. (giusta, 90 ms)
- Charland (Parakeet v3): Possiamo vederci al bar sotto l'ufficio, quello con i tavoli fuori. (giusta, 128 ms)

**29.** Devo ancora rispondere a trenta messaggi e sono già le sei di sera. (3.6 s, voce Alice)

- OpenWhispr (Orukeet): Devo ancora rispondere a trenta messaggi e sono già le 6 di sera. (giusta, 86 ms)
- Charland (Orukeet v0.1.0): Devo ancora rispondere a trenta messaggi e sono già le 6 di sera. (giusta, 82 ms)
- Charland (Parakeet v3): Devo ancora rispondere a 30 messaggi e sono già le 6 di sera. (giusta, 120 ms)

**30.** Il corriere dovrebbe consegnare il pacco domani tra le nove e mezzogiorno. (4.5 s, voce Eddy (Italian (Italy)))

- OpenWhispr (Orukeet): Il Corriere dovrebbe consegnare il pacco domani tra le nove e mezzogiorno. (giusta, 99 ms)
- Charland (Orukeet v0.1.0): Il Corriere dovrebbe consegnare il pacco domani tra le nove e mezzogiorno. (giusta, 103 ms)
- Charland (Parakeet v3): Il Corriere dovrebbe consegnare il pacco domani tra le 9 e mezzogiorno. (giusta, 162 ms)

**31.** Ti scrivo per chiederti se hai ricevuto la fattura che ti ho mandato lunedì. (3.8 s, voce Alice)

- OpenWhispr (Orukeet): Ti scrivo per chiederti se hai ricevuto la fattura che ti ho mandato lunedì. (giusta, 106 ms)
- Charland (Orukeet v0.1.0): Ti scrivo per chiederti se hai ricevuto la fattura che ti ho mandato lunedì. (giusta, 83 ms)
- Charland (Parakeet v3): Ti scrivo per chiederti se hai ricevuto la fattura che ti ho mandato lunedì. (giusta, 124 ms)

**32.** Questa frase è più lunga delle altre perché voglio capire come se la cava il motore quando parlo a lungo senza fermarmi mai. (7.3 s, voce Eddy (Italian (Italy)))

- OpenWhispr (Orukeet): Questa frase è più lunga delle altre perché voglio capire come se la cava in motore quando parlo a lungo senza fermarmi mai. (1 errori, 183 ms)
- Charland (Orukeet v0.1.0): Questa frase è più lunga delle altre perché voglio capire come se la cava il motore quando parlo a lungo senza fermarmi mai. (giusta, 148 ms)
- Charland (Parakeet v3): Questa frase è più lunga delle altre perché voglio capire come se la cava il motore quando parlo a lubo senza fermarmi mai. (1 errori, 200 ms)

**33.** Va bene, facciamo così. (1.8 s, voce Alice)

- OpenWhispr (Orukeet): Va bene, facciamo così. (giusta, 68 ms)
- Charland (Orukeet v0.1.0): Va bene, facciamo così. (giusta, 50 ms)
- Charland (Parakeet v3): Va bene, facciamo così. (giusta, 76 ms)

**34.** No, aspetta. (1.4 s, voce Eddy (Italian (Italy)))

- OpenWhispr (Orukeet): No, aspetta. (giusta, 56 ms)
- Charland (Orukeet v0.1.0): No, aspetta. (giusta, 39 ms)
- Charland (Parakeet v3): No, aspetta. (giusta, 104 ms)

**35.** Per favore aggiungi alla lista della spesa pomodori, mozzarella, basilico e olio buono. (5.2 s, voce Alice)

- OpenWhispr (Orukeet): Per favore aggiungi alla lista della spesa pomodori, mozzarella, basilico e olio buono. (giusta, 134 ms)
- Charland (Orukeet v0.1.0): Per favore aggiungi alla lista della spesa pomodori, mozzarella, basilico e olio buono. (giusta, 112 ms)
- Charland (Parakeet v3): Per favore, aggiungi alla lista della spesa pomodori, mozzarella, basilico e olio buono. (giusta, 271 ms)

**36.** L'incontro con i soci è andato meglio del previsto, ne parliamo a voce. (4.5 s, voce Eddy (Italian (Italy)))

- OpenWhispr (Orukeet): incontro con il soci ha dato meglio del previsto, ne parliamo a voce. (4 errori, 170 ms)
- Charland (Orukeet v0.1.0): incontro con i soci è andato meglio del previsto, ne parliamo a voce. (1 errori, 90 ms)
- Charland (Parakeet v3): incontro con i Soci è andato meglio del previsto, ne parliamo a voce. (1 errori, 157 ms)

**37.** Non dimenticare di spegnere le luci e chiudere la finestra prima di uscire. (3.9 s, voce Alice)

- OpenWhispr (Orukeet): Non dimenticare di spegnere le luci e chiudere la finestra prima di uscire. (giusta, 303 ms)
- Charland (Orukeet v0.1.0): Non dimenticare di spegnere le luci e chiudere la finestra prima di uscire. (giusta, 85 ms)
- Charland (Parakeet v3): Non dimenticare di spegnere le luci e chiudere la finestra prima di uscire. (giusta, 116 ms)

**38.** Domenica andiamo al mare se il tempo regge, altrimenti restiamo in città. (4.8 s, voce Eddy (Italian (Italy)))

- OpenWhispr (Orukeet): Domenica andiamo al mare se il tempo regge, altrimenti restiamo in città. (giusta, 176 ms)
- Charland (Orukeet v0.1.0): Domenica andiamo al mare se il tempo regge, altrimenti restiamo in città. (giusta, 97 ms)
- Charland (Parakeet v3): Domenica andiamo al mare se il tempo regge, altrimenti restiamo in città. (giusta, 138 ms)

**39.** Please schedule the design review for next Tuesday at three thirty. (3.5 s, voce Samantha)

- OpenWhispr (Orukeet): Please schedule the design review for next Tuesday at 3 30. (giusta, 129 ms)
- Charland (Orukeet v0.1.0): Please schedule the design review for next Tuesday at 3 30. (giusta, 77 ms)
- Charland (Parakeet v3): Please schedule the design review for next Tuesday at 3 30. (giusta, 102 ms)

**40.** The build failed because the signing certificate expired last week. (3.9 s, voce Daniel)

- OpenWhispr (Orukeet): The build failed because the signing certificate expired last week. (giusta, 125 ms)
- Charland (Orukeet v0.1.0): The build failed because the signing certificate expired last week. (giusta, 88 ms)
- Charland (Parakeet v3): The build failed because the signing certificate expired last week. (giusta, 120 ms)

**41.** Send the invoice to the client and copy me on the email. (3.8 s, voce Reed (English (US)))

- OpenWhispr (Orukeet): Send the invoice to the client and copy me on the email. (giusta, 91 ms)
- Charland (Orukeet v0.1.0): Send the invoice to the client and copy me on the email. (giusta, 81 ms)
- Charland (Parakeet v3): Send the invoice to the client and copy me on the email. (giusta, 109 ms)

**42.** I think we should ship the beta before the end of November. (3.1 s, voce Samantha)

- OpenWhispr (Orukeet): I think we should ship the beta before the end of November. (giusta, 78 ms)
- Charland (Orukeet v0.1.0): I think we should ship the beta before the end of November. (giusta, 72 ms)
- Charland (Parakeet v3): I think we should ship the beta before the end of November. (giusta, 96 ms)

**43.** Open the settings window and turn off the live preview. (3.1 s, voce Daniel)

- OpenWhispr (Orukeet): Open the settings window and turn off the live preview. (giusta, 78 ms)
- Charland (Orukeet v0.1.0): Open the settings window and turn off the live preview. (giusta, 77 ms)
- Charland (Parakeet v3): Open the settings window and turn off the live preview. (giusta, 94 ms)

**44.** The quick brown fox jumps over the lazy dog near the river bank. (3.7 s, voce Samantha)

- OpenWhispr (Orukeet): The quick brown fox jumps over the lazy dog near the river bank. (giusta, 84 ms)
- Charland (Orukeet v0.1.0): The quick brown fox jumps over the lazy dog near the river bank. (giusta, 82 ms)
- Charland (Parakeet v3): The quick brown fox jumps over the lazy dog near the river bank. (giusta, 112 ms)
