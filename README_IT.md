<p align="center">
  <img src="./docs/logo.png" width="128" height="128" alt="AI Terminal Logo" />
  <h1 align="center">⚡ AI Terminal</h1>
  <p align="center">
    <strong>Controlla i tuoi server con il linguaggio naturale. L'AI esegue i comandi per te.</strong>
  </p>
  <p align="center">
    <a href="https://ai-terminal.keiskei.top" target="_blank">🌐 Sito web</a> ·
    <a href="https://github.com/keiskeies/ai_terminal/releases" target="_blank">📦 Download</a> ·
    <a href="./QUESTION.md">❓ FAQ</a>
  </p>
  <p align="center">
    <img src="https://img.shields.io/badge/Flutter-3.16+-02569B?style=flat-square&logo=flutter" alt="Flutter" />
    <img src="https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20Windows%20%7C%20Android%20%7C%20iOS-green?style=flat-square" alt="Platform" />
    <img src="https://img.shields.io/badge/License-MIT-blue?style=flat-square" alt="License" />
    <img src="https://img.shields.io/badge/version-1.3.6-orange?style=flat-square" alt="Version" />
  </p>
</p>

---

**🌍 Lingua:**
[中文](./README.md) | [English](./README_EN.md) | [日本語](./README_JA.md) | [Deutsch](./README_DE.md) | [Français](./README_FR.md) | [Español](./README_ES.md) | [한국어](./README_KO.md) | [Русский](./README_RU.md) | [Português](./README_PT.md) | **Italiano**

---

## Una frase per spiegarlo

> **Mai usato un terminale? Nessun problema.** Apri AI Terminal, dì cosa vuoi in italiano semplice — si connette al tuo server, esegue i comandi, installa il software e risolve i problemi. Tutto in sicurezza e sotto il tuo controllo.

## 🎯 Ti risulta familiare?

### 😫 Principianti / Utenti non tecnici

- Hai noleggiato un VPS, hai aperto il terminale e hai fissato uno **schermo nero** senza sapere cosa digitare
- Un amico ha detto "basta installare Nginx" — hai cercato su Google 10 tutorial, ognuno con comandi diversi
- Hai provato a configurare Java, hai modificato male `PATH` e hai rotto tutto il terminale
- Qualcuno ti ha avvisato di una vulnerabilità del server — non sai nemmeno come controllare
- Dopo 3 ore di tentativi, non funziona niente. Hai avuto abbastanza.

### 👨‍💻 Sviluppatori

- Cerchi su Google gli stessi comandi `chmod` / `systemctl` ogni singola volta
- Ti connetti in SSH a un server e non ricordi esattamente le opzioni di `grep` che ti servono
- Vuoi controllare i log? Prima di tutto, trova quel segnalibro di 6 mesi fa
- 15 schede del browser aperte, passi da un server all'altro, perdendo il filo di ciò che è dove

### 🔧 DevOps / Amministratori di sistema

- Stesso software su 10 server? Connettiti in SSH a ognuno e ripeti. Di nuovo.
- "Chi ha modificato quella configurazione?" — nessuno si ricorda, niente è registrato
- Un nuovo assunto chiede "come configuro l'ambiente?" — l'hai spiegato 5 volte questo mese
- Vuoi fare un controllo di salute in batch? Scrivere lo script impiega più tempo che farlo manualmente

### 🧑‍💼 Product Manager / Fondatori solisti

- Il tuo unico sviluppatore se n'è andato. Il server è ora una scatola nera.
- Devi controllare alcuni dati ma non sai scrivere SQL. Devi chiedere a qualcuno.
- Distribuire una modifica alla configurazione richiede uno sprint di sviluppo. È letteralmente una riga.
- Indossi 5 cappelli. Non hai tempo per imparare `vi`.

**Tutti gli scenari sopra? Una frase ad AI Terminal li risolve.**

## 🆕 Novità nella v1.3.6

La v1.3.6 è un aggiornamento importante che presenta **5 nuove funzionalità principali**: Monitoraggio del server, Registro delle modifiche, Runbook Ops, Centro notifiche e UI glassmorfismo — un aggiornamento completo per l'efficienza DevOps.

### 📊 Dashboard di Monitoraggio Server in Tempo Reale

> Non digitare più manualmente `top`, `df`, `free` — tutte le metriche a colpo d'occhio

| Panoramica Monitoraggio in Tempo Reale | Interruttore per Host |
|:---:|:---:|
| <img src="./ai_terminal/doc/主界面.jpg" width="400" /> | <img src="./ai_terminal/doc/设置页面.jpg" width="400" /> |

- **CPU / Memoria / Disco / Rete** — quattro metriche principali aggiornate in tempo reale
- **Monitoraggio parallelo multi-host** — visualizza tutti i tuoi server da un'unica dashboard
- **Interruttore indipendente per host** — disattiva il monitoraggio per qualsiasi macchina in qualsiasi momento
- Evidenziazione automatica delle metriche anomale — rilevi i problemi istantaneamente

### 📝 Registro delle Modifiche e Log di Audit

> Chi ha cambiato cosa, e quando? Completamente tracciabile. Analisi post-incidente resa semplice.

- **Registrazione automatica di tutte le operazioni dell'Agente**: esecuzione di comandi, modifiche di file, modifiche di configurazione
- **Gestione delle finestre di modifica**: modifiche pianificate vs di emergenza, categorizzate
- **Log di audit completi**: operatore, timestamp, comando, risultato, codice di uscita — tutto interrogabile
- **Suggerimenti di rollback**: l'AI analizza l'impatto delle modifiche e raccomanda piani di rollback

### 📋 Runbook Ops

| Elenco Runbook | In Esecuzione |
|:---:|:---:|
| <img src="./ai_terminal/doc/运维工作流.jpg" width="400" /> | <img src="./ai_terminal/doc/多机编排.jpg" width="400" /> |

- **Modelli operativi comuni integrati**: ispezione del sistema, rafforzamento della sicurezza, pulizia dei log, distribuzione di servizi e altro
- **Esecuzione con un clic**: non digitare più comandi passo dopo passo — i runbook si eseguono automaticamente
- **Orchestrazione multi-host**: esegui lo stesso flusso di lavoro su più server in parallelo o in sequenza
- **Runbook personalizzati**: crea i tuoi playbook operativi e codifica la conoscenza del team

### 🔔 Centro Notifiche

- **Avvisi di completamento attività** — ricevi una notifica nel momento in cui le attività a lunga esecuzione terminano
- **Avvisi di anomalia** — superamento delle soglie di monitoraggio, fallimenti dei comandi, inviati istantaneamente
- **Promemoria di sicurezza** — operazioni ad alto rischio, comportamento sospetto, avvisi tempestivi
- **Politiche di notifica configurabili** — decidi tu quali eventi attivano le notifiche

### 🎨 Riprogettazione UI Glassmorfismo

| Impostazioni (Cinese) | Impostazioni (Inglese) |
|:---:|:---:|
| <img src="./ai_terminal/doc/设置页面.jpg" width="400" /> | <img src="./ai_terminal/doc/设置页面_英文版.jpg" width="400" /> |

- Nuovo design di card **GlassCard in glassmorfismo** con gerarchia visiva più chiara
- **Rifattorizzazione del sistema di temi** — colori del tema personalizzati, raggio degli angoli, intensità della sfocatura
- Transizioni animate più fluide, feedback di interazione più raffinato
- **15+ lingue** con commutazione con un clic

| Impostazioni Multilingua |
|:---:|
| <img src="./ai_terminal/doc/多语言设置.jpg" width="400" /> |

## 💡 Cosa può fare per te?

### Installare software? Basta dirlo.

> 💬 "Installa Docker su questo server"

L'AI rileva la versione del tuo sistema operativo, corrisponde alla documentazione ufficiale, esegue i comandi di installazione e verifica che abbiano funzionato. Zero comandi da memorizzare.

### Configurare ambienti? Non più mal di testa con PATH.

> 💬 "Configura Python 3.12 con le variabili d'ambiente appropriate"

L'AI sa che Debian usa `apt`, CentOS usa `yum`, macOS usa `brew`. Non fa ipotesi — segue strettamente la documentazione ufficiale.

### Controllare le vulnerabilità? È più paranoica di te.

> 💬 "Scansiona il mio server per problemi di sicurezza"

L'AI esegue automaticamente controlli di aggiornamento del sistema, scansioni delle porte e audit dei processi. Ottieni un rapporto completo di cosa correggere.

### Leggere i log? Non più scavare tra i segnalibri.

> 💬 "Mostrami gli errori recenti di Nginx"

L'AI sa dove risiedono i log, come filtrarli e cosa conta. Informazioni chiave, senza acrobazie con `tail -f`.

### Gestire server? Più macchine, un'unica interfaccia.

Connessioni remote SSH con pool di connessioni. Passa da un server all'altro con zero ritardo. Più schede, una connessione condivisa.

## 🛡️ Sicurezza: L'elefante nella stanza

Affidare il tuo server a un'AI suona terrificante. Tre preoccupazioni valide:

### 🔐 "Dove vanno le mie password?"

```
La tua password → Archiviazione sicura a livello di sistema (macOS Keychain / Android Keystore)
                       ↓
              Il database locale memorizza solo "quale chiave è stata usata", mai la password stessa
                       ↓
              Le password non appaiono mai in chiaro nei log, nei file di configurazione o su disco
```

Anche se qualcuno ruba il tuo dispositivo, senza i tuoi dati biometrici/codice di accesso, tutto ciò che ottiene è un codice cifrato incomprensibile.

### 🤖 "L'AI può impazzire?"

**No.** Tre livelli di difesa:

```
┌─────────────────────────────────────────────────────┐
│ Livello 1: Prompt di Confine Comportamentale        │
│ Le istruzioni di sistema dell'AI proibiscono        │
│ esplicitamente:                                     │
│   ✗ Installare/disinstallare software senza chiedere│
│   ✗ Modificare variabili d'ambiente o configurazioni│
│      di sistema                                     │
│   ✗ Eseguire operazioni distruttive                 │
│   ✓ Richieste "controlla/ispeziona" → comandi in    │
│      sola lettura                                   │
│   ✓ Problemi trovati → segnala prima, non ripara    │
│      mai da solo                                    │
└─────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────┐
│ Livello 2: Classificazione Comandi SafetyGuard      │
│ Ogni comando viene esaminato prima dell'esecuzione: │
│   🔴 bloccato → Bloccato immediatamente, non viene  │
│      mai eseguito                                   │
│      (rm -rf /, chmod 777, formattazione dischi, ecc.)│
│   🟡 avviso → Popup di avviso, richiede input CONFERMA│
│      (apt install, systemctl stop, modifiche firewall)│
│   🔵 info → Avviso a basso rischio, eseguito normalmente│
│      (curl, wget, ls, cat, ecc.)                    │
└─────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────┐
│ Livello 3: Tu Sei il Cancello Finale                │
│ Tu sei sempre l'ultima linea di difesa.             │
│ I comandi di livello avviso non vengono eseguiti    │
│ senza CONFERMA.                                     │
│ Puoi interrompere, annullare o rivedere in qualsiasi│
│ momento.                                            │
└─────────────────────────────────────────────────────┘
```

### 📋 Carta di Comportamento dell'Agente

| Cosa puoi chiedere | Cosa farà l'AI | Cosa non farà l'AI |
|:---|:---|:---|
| Installare software | Genererà comandi di installazione ufficiali e li eseguirà | Deciderà da sola quale versione installare |
| Controllare la sicurezza | Eseguirà comandi di audit e segnalerà i risultati | Risolverà i problemi senza il tuo permesso |
| Configurare l'ambiente | Seguirà esattamente la documentazione ufficiale | Cambierà parametri di sistema che non hai chiesto |
| Leggere i log | Filtra e mostra le informazioni chiave | Eliminerà o modificherà i file di log |
| Gestire i servizi | Avvierà/fermerà i servizi che hai specificato | Avvierà altri servizi che non hai menzionato |
| Eseguire flussi di lavoro | Eseguirà automaticamente i passaggi predefiniti | Salterà passaggi critici o modificherà il processo |

**In sintesi: l'AI è il tuo assistente, non il tuo capo. Fa quello che chiedi. Niente di più.**

## ✨ Funzionalità Principali

| Funzionalità | Descrizione |
|:---|:---|
| 🤖 **Esecuzione Automatica Agente** | L'AI genera comandi e li esegue in loop fino al completamento dell'attività |
| 📊 **Monitoraggio Server** | Dashboard CPU/memoria/disco/rete in tempo reale, multi-host parallelo |
| 📝 **Registro delle Modifiche** | Log di audit completi, operazioni tracciabili, pronte per il rollback |
| 📋 **Runbook Ops** | Modelli Runbook integrati, attività operative comuni con un clic |
| 🔔 **Centro Notifiche** | Completamento attività, avvisi di anomalia, promemoria di sicurezza — inviati istantaneamente |
| 🛡️ **Tripla Sicurezza** | Prompt di confine comportamentale → classificazione comandi SafetyGuard → operazioni pericolose richiedono CONFERMA |
| 🔐 **Zero Credenziali in Chiaro** | Password/chiavi private nel Keychain / Keystore di sistema, mai su disco in chiaro |
| 🖥️ **5 Piattaforme Native** | macOS / Linux / Windows / Android / iOS — supporto nativo completo |
| 📡 **Locale + Remoto** | Connessioni remote SSH + terminale PTY locale; l'Agente funziona in entrambe le modalità |
| 🔄 **Pool di Connessioni** | Pool di connessioni SSH — più schede condividono una connessione, commutazione a zero ritardo |
| 🌊 **Output in Streaming** | Le risposte dell'AI vengono renderizzate in tempo reale; l'output del terminale scorre in diretta |
| 🧠 **Guidato dalla Conoscenza** | Oltre 150 guide di installazione/configurazione software integrate — segue la documentazione ufficiale, nessuna allucinazione AI |
| 🌐 **20+ Fornitori** | DeepSeek / Qwen / Claude / Gemini / Ollama e altri, con aggiornamenti di configurazione remoti |
| 🌍 **15+ Lingue** | Cinese / Inglese / Giapponese / Coreano / Francese / Tedesco / Spagnolo / Russo / Portoghese e altre |

## 🏗️ Stack Tecnologico

```
Flutter 3.16+ (Dart 3.2+)
├── Gestione dello stato: Riverpod
├── Routing: GoRouter
├── Archiviazione locale: Hive + flutter_secure_storage
├── SSH: dartssh2
├── Terminale locale: flutter_pty
├── UI Terminale: xterm.dart
├── Interfaccia AI: Compatibile OpenAI (20+ fornitori)
├── Monitoraggio: Dashboard server (CPU/memoria/disco/rete)
├── Ops: Registro delle modifiche + Log di audit + Flussi di lavoro Runbook
└── UI: Glassmorfismo GlassCard + Temi multipli + 15+ lingue
```

## 🚀 Per Iniziare

### Prerequisiti

- Flutter 3.16.0+
- Dart 3.2.0+
- Strumenti di sviluppo specifici della piattaforma (Xcode / Android Studio / VS Code, ecc.)

### Installazione ed Esecuzione

```bash
# Clona il repository
git clone https://github.com/keiskeies/ai_terminal.git
cd ai_terminal/ai_terminal

# Installa le dipendenze
flutter pub get

# Genera gli adattatori Hive (solo la prima volta)
dart run build_runner build --delete-conflicting-outputs

# Esegui
flutter run
```

### Build per il Rilascio

```bash
# macOS
flutter build macos --release

# Windows
flutter build windows --release

# Linux
flutter build linux --release

# Android APK
flutter build apk --release

# iOS (richiede macOS + certificato sviluppatore)
flutter build ios --release
```

> 📥 Oppure scarica i binari precompilati da [Releases](https://github.com/keiskeies/ai_terminal/releases).

## 🔧 Configurazione dei Modelli AI

L'app viene fornita con **oltre 20 preimpostazioni di fornitori AI** e supporta qualsiasi **API compatibile OpenAI**:

| Categoria | Fornitori |
|:---|:---|
| 🏠 Locale | Ollama (completamente gratuito, nessuna chiave API necessaria) |
| 🇨🇳 Cloud Cina | DeepSeek / Qwen / GLM / Kimi / Doubao / MiMo / MiniMax / SiliconFlow / StepFun / Baichuan / Spark / Hunyuan |
| 🌍 Cloud Globale | OpenAI / Claude / Gemini / xAI Grok / Mistral / OpenRouter / Groq |
| 🔧 Personalizzato | Qualsiasi endpoint API compatibile OpenAI |

Passaggi di configurazione:

1. Apri l'app → Impostazioni → Configurazione Modello AI
2. Clicca `+` per aggiungere un modello
3. Seleziona un fornitore (Base URL e modelli consigliati vengono compilati automaticamente)
4. Inserisci la tua chiave API e seleziona un modello
5. Imposta come modello predefinito

> 💡 L'elenco dei fornitori supporta aggiornamenti remoti: clicca sul pulsante 🔄 accanto al menu a discesa del fornitore per recuperare gli ultimi fornitori e modelli dal server — nessun aggiornamento dell'app richiesto

## 📱 Screenshot

| UI Principale (Monitor + Terminale) | Orchestrazione Multi-Host |
|:---:|:---:|
| <img src="./ai_terminal/doc/主界面.jpg" width="400" /> | <img src="./ai_terminal/doc/多机编排.jpg" width="400" /> |

| Runbook Ops | Pagina Impostazioni |
|:---:|:---:|
| <img src="./ai_terminal/doc/运维工作流.jpg" width="400" /> | <img src="./ai_terminal/doc/设置页面.jpg" width="400" /> |

| Impostazioni Multilingua |
|:---:|
| <img src="./ai_terminal/doc/多语言设置.jpg" width="400" /> |

> 🤖 Funzionalità AI alimentate da <b>Xiaomi MiMo</b> LLM

## 📖 Demo: Installazione Automatica Guidata dalla Conoscenza

La v1.3.0 ha introdotto una **Base di Conoscenza Manuale Comandi** — oltre 150 guide ufficiali di installazione/disinstallazione/aggiornamento. L'Agente corrisponde automaticamente alla base di conoscenza e segue strettamente i metodi ufficiali, **eliminando l'allucinazione AI**.

Di seguito: digitare "installa openclaw" dopo essersi connessi in SSH a un server Ubuntu:

| ① Inserisci comando | ② Corrispondenza base di conoscenza, genera comandi |
|:---:|:---:|
| <img src="./ai_terminal/doc/at_130_1.webp" width="400" /> | <img src="./ai_terminal/doc/at_130_2.webp" width="400" /> |

| ③ Esegui installazione automaticamente | ④ Verifica installazione |
|:---:|:---:|
| <img src="./ai_terminal/doc/at_130_3.webp" width="400" /> | <img src="./ai_terminal/doc/at_130_4.webp" width="400" /> |

**Analisi del flusso:**

1. L'utente digita "installa openclaw" → l'Agente estrae l'operazione (installa) e la piattaforma (linux)
2. La base di conoscenza corrisponde a `openclaw` per `linux-debian` (modalità stretta), iniettando i comandi di installazione ufficiali
3. L'Agente segue esattamente la base di conoscenza: installa Node.js 22, poi `npm install -g openclaw`
4. Verifica post-installazione: esegue `openclaw --version` per confermare il successo

> 💡 La base di conoscenza supporta la corrispondenza specifica per piattaforma (`linux-debian` vs `linux-rhel` producono diversi comandi di gestione pacchetti), con aggiornamenti remoti con un clic

## 🗺️ Roadmap

- [x] v1.0.0 — Rilascio funzionalità core
  - [x] Terminale remoto SSH + terminale PTY locale
  - [x] Chat AI + generazione comandi + esecuzione automatica
  - [x] Controllo sicurezza comandi SafetyGuard
  - [x] Archiviazione credenziali crittografata
  - [x] Configurazione multi-modello
- [x] v1.1.0 — Miglioramento UI
  - [x] Riprogettazione layout pannello AI
  - [x] Orientamento automatico mobile
  - [x] Tema verde modalità Agente
- [x] v1.2.0 — Potenziamento intelligenza Agente
  - [x] Cronologia conversazioni persistente tra le attività
  - [x] Output comando di query non più troncato
  - [x] Passaggi di esecuzione illimitati per impostazione predefinita
  - [x] Gestione file SFTP + modifica remota
- [x] v1.3.0 — Guidato dalla conoscenza
  - [x] 🧠 Base di conoscenza ricerca full-text SQLite FTS5 (oltre 150 guide software)
  - [x] 🔄 Sincronizzazione automatica base di conoscenza remota (aggiornamenti da GitHub all'avvio)
  - [x] 🎯 Corrispondenza specifica per piattaforma (linux-debian / linux-rhel / macos)
  - [x] 🛡️ Regole di sicurezza LLM (applicazione stretta + proibizione comando di ricerca)
  - [x] 🔧 Strumento di build base di conoscenza (CSV → SQLite)
  - [x] 💬 Messaggi di errore API amichevoli (401/429/timeout)
- [x] v1.3.1 — Ecosistema fornitori
  - [x] 🌐 20+ preimpostazioni fornitori AI (12 Cina + 8 Globale + Ollama + Personalizzato)
  - [x] 🔄 Aggiornamenti configurazione fornitori remoti (nessun aggiornamento app necessario)
  - [x] 🏷️ Descrizioni fornitori e informazioni sui prezzi
  - [x] 🤖 Selezione rapida modelli preimpostati (con un clic)
  - [x] 🦙 Distribuzione locale Ollama (nessuna chiave API, completamente gratuito)
  - [x] 📐 Ottimizzazione dialogo aggiungi modello (layout a due colonne per schermi larghi)
- [x] v1.3.6 — Aggiornamento Massivo Capacità Ops
  - [x] 📊 Monitoraggio server in tempo reale (CPU/memoria/disco/rete, multi-host parallelo)
  - [x] 📝 Registro delle modifiche e log di audit (cronologia operazioni completa, tracciabile e pronta per il rollback)
  - [x] 📋 Runbook Ops (modelli integrati + personalizzati, esecuzione con un clic)
  - [x] 🔔 Centro Notifiche (completamento attività, avvisi di anomalia, promemoria di sicurezza)
  - [x] 🎨 Riprogettazione UI glassmorfismo (design GlassCard, aggiornamento sistema temi)
  - [x] 🌍 Localizzazione in 15+ lingue
  - [x] 📺 Orchestrazione multi-host (esegui flussi di lavoro su più server in parallelo/serie)

## 🤝 Contribuire

I contributi sono benvenuti! Segnalazioni di bug, suggerimenti di funzionalità o codice.

1. Fai un fork di questo repository
2. Crea un branch per la funzionalità (`git checkout -b feature/funzionalita-straordinaria`)
3. Committa le tue modifiche (`git commit -m 'Aggiungi funzionalità straordinaria'`)
4. Pusha il branch (`git push origin feature/funzionalita-straordinaria`)
5. Apri una Pull Request

## 📄 Licenza

[Licenza MIT](./LICENSE)

---

## ⭐ Storia delle Stelle

[![Grafico Storia delle Stelle](https://api.star-history.com/svg?repos=keiskeies/ai_terminal&type=Date)](https://star-history.com/#keiskeies/ai_terminal&Date)

---

<p align="center">
  Se questo progetto ti aiuta, per favore dagli una ⭐ Stella!
</p>
