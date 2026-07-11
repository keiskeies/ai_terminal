<p align="center">
  <img src="./docs/logo.png" width="128" height="128" alt="AI Terminal Logo" />
  <h1 align="center">⚡ AI Terminal</h1>
  <p align="center">
    <strong>Steuern Sie Ihre Server mit natürlicher Sprache. AI führt die Befehle für Sie aus.</strong>
  </p>
  <p align="center">
    <a href="https://ai-terminal.keiskei.top" target="_blank">🌐 Webseite</a> ·
    <a href="https://github.com/keiskeies/ai_terminal/releases" target="_blank">📦 Download</a> ·
    <a href="./QUESTION.md">❓ FAQ</a>
  </p>
  <p align="center">
    <img src="https://img.shields.io/badge/Flutter-3.16+-02569B?style=flat-square&logo=flutter" alt="Flutter" />
    <img src="https://img.shields.io/badge/Platform-macOS%20%7C%20Linux%20%7C%20Windows%20%7C%20Android%20%7C%20iOS-green?style=flat-square" alt="Plattform" />
    <img src="https://img.shields.io/badge/License-MIT-blue?style=flat-square" alt="Lizenz" />
    <img src="https://img.shields.io/badge/version-1.3.5-orange?style=flat-square" alt="Version" />
  </p>
</p>

---

**🌍 Sprache:**
[中文](./README.md) | [English](./README_EN.md) | [日本語](./README_JA.md) | **Deutsch** | [Français](./README_FR.md) | [Español](./README_ES.md) | [한국어](./README_KO.md) | [Русский](./README_RU.md) | [Português](./README_PT.md) | [Italiano](./README_IT.md)

---

## Ein Satz zur Erklärung

> **Nie ein Terminal benutzt? Kein Problem.** Öffnen Sie AI Terminal, sagen Sie in einfachen Worten, was Sie wollen — es verbindet sich mit Ihrem Server, führt Befehle aus, installiert Software und behebt Probleme. Alles sicher und unter Ihrer Kontrolle.

## 🎯 Klingt das vertraut?

### 😫 Anfänger / Nicht-Technische Benutzer

- Sie haben einen VPS gemietet, das Terminal geöffnet und starrten auf einen **schwarzen Bildschirm**, ohne zu wissen, was eingeben soll
- Ein Freund sagte "installieren Sie einfach Nginx" — Sie haben 10 Tutorials gegoogelt, jedes mit anderen Befehlen
- Sie haben versucht, Java einzurichten, `PATH` falsch bearbeitet und Ihr gesamtes Terminal kaputt gemacht
- Jemand hat Sie vor einer Server-Sicherheitslücke gewarnt — Sie wissen nicht einmal, wie Sie prüfen sollen
- Nach 3 Stunden Herumprobieren funktioniert nichts. Sie sind fertig.

### 👨‍💻 Entwickler

- Sie googeln jedes Mal dieselben `chmod` / `systemctl` Befehle
- SSH auf einen Server, blank zu den genauen `grep`-Flaggen, die Sie brauchen
- Wollen Sie Protokolle prüfen? Zuerst finden Sie dieses Lesezeichen von vor 6 Monaten
- 15 Browser-Tabs geöffnet, zwischen Servern wechseln, den Überblick verlieren

### 🔧 DevOps / Systemadministratoren

- Dieselbe Software auf 10 Servern? Bei jedem per SSH einloggen und wiederholen. Wieder.
- "Wer hat diese Konfiguration geändert?" — niemand erinnert sich, nichts ist protokolliert
- Neuer Mitarbeiter fragt "wie richte ich die Umgebung ein?" — Sie haben es diesen Monat schon 5 Mal erklärt
- Wollen Sie einen Batch-Gesundheitscheck durchführen? Das Skript schreiben dauert länger als die manuelle Ausführung

### 🧑‍💼 Produktmanager / Solo-Gründer

- Ihr einziger Entwickler ist weg. Der Server ist jetzt eine Black Box.
- Sie müssen einige Daten prüfen, können aber kein SQL schreiben. Sie müssen jemanden fragen.
- Eine Konfigurationsänderung bereitzustellen erfordert einen Entwicklungs-Sprint. Es ist buchstäblich eine Zeile.
- Sie tragen 5 Hüte. Sie haben keine Zeit, `vi` zu lernen.

**Jedes oben genannte Szenario? Ein Satz an AI Terminal löst es.**

## 🆕 Neu in v1.3.5

v1.3.5 ist ein wichtiges Update mit **5 neuen Kernfähigkeiten**: Server-Überwachung, Änderungsprotokoll, Ops-Runbooks, Benachrichtigungszentrum und Glassmorphismus UI — ein komplettes Upgrade für die DevOps-Effizienz.

### 📊 Echtzeit-Server-Überwachungs-Dashboard

> Kein manuelles Eingeben von `top`, `df`, `free` mehr — alle Metriken auf einen Blick

| Echtzeit-Überwachungsübersicht | Pro-Host-Umschalter |
|:---:|:---:|
| <img src="./ai_terminal/doc/主界面.jpg" width="400" /> | <img src="./ai_terminal/doc/设置页面.jpg" width="400" /> |

- **CPU / Speicher / Festplatte / Netzwerk** — vier Kernmetriken werden in Echtzeit aktualisiert
- **Mehrhost-Parallelüberwachung** — alle Ihre Server von einem Dashboard aus anzeigen
- **Pro-Host-unabhängiger Umschalter** — Überwachung für jede Maschine jederzeit ausschalten
- Automatische Hervorhebung abnormaler Metriken — Probleme sofort erkennen

### 📝 Änderungsprotokoll & Audit-Logs

> Wer hat was wann geändert? Vollständig nachverfolgbar. Forensik nach Vorfällen leicht gemacht.

- **Automatische Protokollierung aller Agent-Operationen**: Befehlsausführung, Dateiänderungen, Konfigurationsmodifikationen
- **Änderungsfenster-Verwaltung**: geplante vs. Notfalländerungen, kategorisiert
- **Vollständige Audit-Logs**: Bediener, Zeitstempel, Befehl, Ergebnis, Exit-Code — alles abfragbar
- **Rollback-Vorschläge**: AI analysiert Änderungsauswirkungen und empfiehlt Rollback-Pläne

### 📋 Ops-Runbooks

| Runbook-Liste | Ausführung |
|:---:|:---:|
| <img src="./ai_terminal/doc/运维工作流.jpg" width="400" /> | <img src="./ai_terminal/doc/多机编排.jpg" width="400" /> |

- **Integrierte gängige Ops-Vorlagen**: Systeminspektion, Sicherheits-Härtung, Protokollbereinigung, Dienstbereitstellung und mehr
- **Ein-Klick-Ausführung**: keine schrittweise Eingabe von Befehlen mehr — Runbooks werden automatisch ausgeführt
- **Mehrhost-Orchestrierung**: denselben Workflow auf mehreren Servern parallel oder sequenziell ausführen
- **Benutzerdefinierte Runbooks**: Erstellen Sie Ihre eigenen Ops-Playbooks und kodifizieren Sie Teamwissen

### 🔔 Benachrichtigungszentrum

- **Benachrichtigungen zum Abschluss von Aufgaben** — werden benachrichtigt, sobald langlaufende Aufgaben beendet sind
- **Anomaliewarnungen** — Verstöße gegen Überwachungsschwellen, Befehlsfehler, sofort zugestellt
- **Sicherheitserinnerungen** — risikoreiche Operationen, verdächtiges Verhalten, Frühwarnungen
- **Konfigurierbare Benachrichtigungsrichtlinien** — Sie bestimmen, welche Ereignisse Benachrichtigungen auslösen

### 🎨 Glassmorphismus UI-Neugestaltung

| Einstellungen (Chinesisch) | Einstellungen (Englisch) |
|:---:|:---:|
| <img src="./ai_terminal/doc/设置页面.jpg" width="400" /> | <img src="./ai_terminal/doc/设置页面_英文版.jpg" width="400" /> |

- Brandneues **GlassCard Glassmorphismus-Kartendesign** mit klarerer visueller Hierarchie
- **Themensystem-Refaktorisierung** — benutzerdefinierte Themenfarben, Eckradius, Unschärfeintensität
- Flüssigere animierte Übergänge, verfeinertes Interaktionsfeedback
- **15+ Sprachen** mit Ein-Klick-Umschaltung

| Mehrsprachige Einstellungen |
|:---:|
| <img src="./ai_terminal/doc/多语言设置.jpg" width="400" /> |

## 💡 Was kann es für Sie tun?

### Software installieren? Sagen Sie es einfach.

> 💬 "Installieren Sie Docker auf diesem Server"

AI erkennt Ihre OS-Version, passt zu offiziellen Dokumenten, führt die Installationsbefehle aus und überprüft, ob es funktioniert hat. Null Befehle zu auswendig lernen.

### Umgebungen konfigurieren? Keine PATH-Kopfschmerzen mehr.

> 💬 "Richten Sie Python 3.12 mit den richtigen Umgebungsvariablen ein"

AI weiß, dass Debian `apt`, CentOS `yum`, macOS `brew` verwendet. Es rät nicht — es folgt strikt der offiziellen Dokumentation.

### Nach Sicherheitslücken suchen? Es ist paranoider als Sie.

> 💬 "Scannen Sie meinen Server nach Sicherheitsproblemen"

AI führt automatisch Systemupdate-Prüfungen, Portscans und Prozessaudits durch. Sie erhalten einen vollständigen Bericht, was zu beheben ist.

### Protokolle lesen? Kein Graben in Lesezeichen mehr.

> 💬 "Zeigen Sie mir aktuelle Nginx-Fehler"

AI weiß, wo Protokolle liegen, wie man sie filtert und was wichtig ist. Wichtige Informationen, keine `tail -f` Gymnastik.

### Server verwalten? Mehrere Maschinen, eine Oberfläche.

SSH-Remoteverbindungen mit Verbindungspooling. Wechseln Sie zwischen Servern ohne Verzögerung. Mehrere Tabs, eine gemeinsame Verbindung.

## 🛡️ Sicherheit: Der Elefant im Raum

Ihren Server an eine AI zu übergeben klingt erschreckend. Drei berechtigte Bedenken:

### 🔐 "Wohin gehen meine Passwörter?"

```
Ihr Passwort → Systemebene sichere Speicherung (macOS Keychain / Android Keystore)
                       ↓
              Lokale Datenbank speichert nur „welcher Schlüssel verwendet wurde“, nie das Passwort selbst
                       ↓
              Passwörter erscheinen niemals im Klartext in Protokollen, Konfigurationsdateien oder auf der Festplatte
```

Selbst wenn jemand Ihr Gerät stiehlt, ohne Ihre Biometrie/Passcode bekommt er nur verschlüsseltes Kauderwelsch.

### 🤖 "Kann die AI aus dem Ruder laufen?"

**Nein.** Drei Verteidigungsebenen:

```
┌─────────────────────────────────────────────────────┐
│ Ebene 1: Verhaltensgrenzwerte                        │
│ AI-Systemanweisungen verbieten ausdrücklich:         │
│   ✗ Software ohne Fragen installieren/deinstallieren │
│   ✗ Umgebungsvariablen oder Systemkonfigurationen    │
│     ändern                                           │
│   ✗ Destruktive Operationen ausführen                │
│   ✓ „Prüfen/untersuchen“-Anfragen → Nur-Lesen-Befehle│
│   ✓ Gefundene Probleme → zuerst melden, nie selbst   │
│     beheben                                          │
└─────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────┐
│ Ebene 2: SafetyGuard Befehlsklassifizierung          │
│ Jeder Befehl wird vor der Ausführung überprüft:      │
│   🔴 blockiert → Sofort blockiert, wird nie ausgeführt│
│      (rm -rf /, chmod 777, Festplattenformatierung usw.) │
│   🟡 warnen → Popup-Warnung, erfordert BESTÄTIGUNG-Eingabe │
│      (apt install, systemctl stop, Firewall-Änderungen) │
│   🔵 info → Niedrigrisiko-Hinweis, läuft normal      │
│      (curl, wget, ls, cat usw.)                      │
└─────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────┐
│ Ebene 3: Sie sind das letzte Tor                     │
│ Sie sind immer die letzte Verteidigungslinie.        │
│ Befehl auf Warn-Ebene werden ohne BESTÄTIGUNG nicht  │
│ ausgeführt.                                          │
│ Sie können jederzeit unterbrechen, abbrechen oder    │
│ prüfen.                                              │
└─────────────────────────────────────────────────────┘
```

### 📋 Agent-Verhaltenscharta

| Was Sie fragen können | Was AI tun wird | Was AI nicht tun wird |
|:---|:---|:---|
| Software installieren | Offizielle Installationsbefehle generieren & ausführen | Selbst entscheiden, welche Version installiert werden soll |
| Sicherheit prüfen | Audit-Befehle ausführen & Ergebnisse melden | Probleme ohne Ihre Erlaubnis beheben |
| Umgebung konfigurieren | Offiziellen Dokumenten genau folgen | Systemparameter ändern, nach denen Sie nicht gefragt haben |
| Protokolle lesen | Schlüsselinformationen filtern & anzeigen | Protokolldateien löschen oder ändern |
| Dienste verwalten | Von Ihnen angegebene Dienste starten/stoppen | Andere Dienste starten, die Sie nicht erwähnt haben |
| Workflows ausführen | Vordefinierte Schritte automatisch ausführen | Kritische Schritte überspringen oder den Prozess ändern |

**TL;DR: AI ist Ihr Assistent, nicht Ihr Chef. Sie tut, was Sie verlangen. Nichts mehr.**

## ✨ Kernfunktionen

| Funktion | Beschreibung |
|:---|:---|
| 🤖 **Agent-Automatische Ausführung** | AI generiert Befehle und führt sie in einer Schleife aus, bis die Aufgabe abgeschlossen ist |
| 📊 **Server-Überwachung** | Echtzeit-CPU/Speicher/Festplatte/Netzwerk-Dashboard, Mehrhost-parallel |
| 📝 **Änderungsprotokoll** | Vollständige Audit-Logs, nachverfolgbare Operationen, rollback-bereit |
| 📋 **Ops-Runbooks** | Integrierte Runbook-Vorlagen, Ein-Klick gängige Ops-Aufgaben |
| 🔔 **Benachrichtigungszentrum** | Aufgabenabschluss, Anomaliewarnungen, Sicherheitserinnerungen — sofort zugestellt |
| 🛡️ **Dreifache Sicherheit** | Verhaltensgrenzwert-Prompts → SafetyGuard Befehlsklassifizierung → Gefährliche Operationen erfordern BESTÄTIGUNG |
| 🔐 **Null Klartext-Anmeldeinformationen** | Passwörter/private Schlüssel in System Keychain / Keystore, nie im Klartext auf der Festplatte |
| 🖥️ **5 Native Plattformen** | macOS / Linux / Windows / Android / iOS — vollständige native Unterstützung |
| 📡 **Lokal + Remote** | SSH-Remoteverbindungen + lokales PTY-Terminal; Agent funktioniert in beiden Modi |
| 🔄 **Verbindungspool** | SSH-Verbindungspooling — mehrere Tabs teilen eine Verbindung, null-Verzögerungswechsel |
| 🌊 **Streaming-Ausgabe** | AI-Antworten werden in Echtzeit gerendert; Terminalausgabe streamt live |
| 🧠 **Wissensgesteuert** | 150+ Software-Installations/Konfigurationsanleitungen integriert — folgt offiziellen Dokumenten, keine AI-Halluzination |
| 🌐 **20+ Anbieter** | DeepSeek / Qwen / Claude / Gemini / Ollama & mehr, mit Remote-Konfigurationsupdates |
| 🌍 **15+ Sprachen** | Chinesisch / Englisch / Japanisch / Koreanisch / Französisch / Deutsch / Spanisch / Russisch / Portugiesisch & mehr |

## 🏗️ Technologie-Stack

```
Flutter 3.16+ (Dart 3.2+)
├── Zustandsverwaltung: Riverpod
├── Routing: GoRouter
├── Lokaler Speicher: Hive + flutter_secure_storage
├── SSH: dartssh2
├── Lokales Terminal: flutter_pty
├── Terminal-UI: xterm.dart
├── AI-Schnittstelle: OpenAI-kompatibel (20+ Anbieter)
├── Überwachung: Server-Dashboard (CPU/Speicher/Festplatte/Netzwerk)
├── Ops: Änderungsprotokoll + Audit-Logs + Runbook-Workflows
└── UI: GlassCard Glassmorphismus + Multi-Theme + 15+ Sprachen
```

## 🚀 Erste Schritte

### Voraussetzungen

- Flutter 3.16.0+
- Dart 3.2.0+
- Plattformspezifische Entwicklerwerkzeuge (Xcode / Android Studio / VS Code usw.)

### Installieren & Ausführen

```bash
# Repository klonen
git clone https://github.com/keiskeies/ai_terminal.git
cd ai_terminal/ai_terminal

# Abhängigkeiten installieren
flutter pub get

# Hive-Adapter generieren (nur beim ersten Mal)
dart run build_runner build --delete-conflicting-outputs

# Ausführen
flutter run
```

### Für Release bauen

```bash
# macOS
flutter build macos --release

# Windows
flutter build windows --release

# Linux
flutter build linux --release

# Android APK
flutter build apk --release

# iOS (erfordert macOS + Entwicklerzertifikat)
flutter build ios --release
```

> 📥 Oder laden Sie vorgefertigte Binärdateien von [Releases](https://github.com/keiskeies/ai_terminal/releases) herunter.

## 🔧 AI-Modelle konfigurieren

Die App wird mit **20+ AI-Anbieter-Voreinstellungen** geliefert und unterstützt jede **OpenAI-kompatible API**:

| Kategorie | Anbieter |
|:---|:---|
| 🏠 Lokal | Ollama (völlig kostenlos, kein API-Schlüssel erforderlich) |
| 🇨🇳 China Cloud | DeepSeek / Qwen / GLM / Kimi / Doubao / MiMo / MiniMax / SiliconFlow / StepFun / Baichuan / Spark / Hunyuan |
| 🌍 Globale Cloud | OpenAI / Claude / Gemini / xAI Grok / Mistral / OpenRouter / Groq |
| 🔧 Benutzerdefiniert | Jeder OpenAI-kompatible API-Endpunkt |

Einrichtungsschritte:

1. App öffnen → Einstellungen → AI-Modell-Konfiguration
2. Auf `+` klicken, um ein Modell hinzuzufügen
3. Einen Anbieter auswählen (Basis-URL und empfohlene Modelle werden automatisch ausgefüllt)
4. Ihren API-Schlüssel eingeben und ein Modell auswählen
5. Als Standardmodell festlegen

> 💡 Anbieterliste unterstützt Remote-Updates: Klicken Sie auf die 🔄-Schaltfläche neben dem Anbieter-Dropdown, um die neuesten Anbieter und Modelle vom Server abzurufen — kein App-Update erforderlich

## 📱 Screenshots

| Haupt-UI (Monitor + Terminal) | Mehrhost-Orchestrierung |
|:---:|:---:|
| <img src="./ai_terminal/doc/主界面.jpg" width="400" /> | <img src="./ai_terminal/doc/多机编排.jpg" width="400" /> |

| Ops-Runbooks | Einstellungsseite |
|:---:|:---:|
| <img src="./ai_terminal/doc/运维工作流.jpg" width="400" /> | <img src="./ai_terminal/doc/设置页面.jpg" width="400" /> |

| Mehrsprachige Einstellungen |
|:---:|
| <img src="./ai_terminal/doc/多语言设置.jpg" width="400" /> |

> 🤖 AI-Funktionen angetrieben durch <b>Xiaomi MiMo</b> LLM

## 📖 Demo: Wissensgesteuerte automatische Installation

v1.3.0 führte eine **Befehlshandbuch-Wissensdatenbank** ein — 150+ offizielle Installations-/Deinstallations-/Update-Anleitungen. Der Agent passt automatisch zur Wissensdatenbank und folgt strikt offiziellen Methoden, **wodurch AI-Halluzinationen eliminiert werden**.

Unten: Eingabe von "install openclaw" nach SSH auf einem Ubuntu-Server:

| ① Befehl eingeben | ② Wissensdatenbank-Abgleich, Befehle generieren |
|:---:|:---:|
| <img src="./ai_terminal/doc/at_130_1.webp" width="400" /> | <img src="./ai_terminal/doc/at_130_2.webp" width="400" /> |

| ③ Installation automatisch ausführen | ④ Installation überprüfen |
|:---:|:---:|
| <img src="./ai_terminal/doc/at_130_3.webp" width="400" /> | <img src="./ai_terminal/doc/at_130_4.webp" width="400" /> |

**Ablaufaufschlüsselung:**

1. Benutzer gibt "install openclaw" ein → Agent extrahiert Operation (installieren) und Plattform (linux)
2. Wissensdatenbank passt `openclaw` für `linux-debian` (strikter Modus), injiziert offizielle Installationsbefehle
3. Agent folgt der Wissensdatenbank genau: installiert Node.js 22, dann `npm install -g openclaw`
4. Post-Installationsprüfung: führt `openclaw --version` aus, um den Erfolg zu bestätigen

> 💡 Wissensdatenbank unterstützt plattformspezifischen Abgleich (`linux-debian` vs `linux-rhel` ergeben verschiedene Paketmanager-Befehle), mit Ein-Klick-Remote-Updates

## 🗺️ Roadmap

- [x] v1.0.0 — Kernfunktionsveröffentlichung
  - [x] SSH-Remote-Terminal + lokales PTY-Terminal
  - [x] AI-Chat + Befehlsgenerierung + automatische Ausführung
  - [x] SafetyGuard Befehlssicherheitsprüfung
  - [x] Verschlüsselte Anmeldeinformationsspeicherung
  - [x] Mehrmodell-Konfiguration
- [x] v1.1.0 — UI-Verbesserung
  - [x] AI-Panel-Layout-Neugestaltung
  - [x] Mobile automatische Ausrichtung
  - [x] Agent-Modus grünes Thema
- [x] v1.2.0 — Agent-Intelligenz-Schub
  - [x] Persistenter Gesprächsverlauf über Aufgaben hinweg
  - [x] Abfragebefehlsausgabe nicht mehr abgeschnitten
  - [x] Unbegrenzte Ausführungsschritte standardmäßig
  - [x] SFTP-Dateiverwaltung + Remote-Bearbeitung
- [x] v1.3.0 — Wissensgesteuert
  - [x] 🧠 SQLite FTS5 Volltextsuche Wissensdatenbank (150+ Software-Anleitungen)
  - [x] 🔄 Remote-Wissensdatenbank Auto-Sync (Updates von GitHub beim Start)
  - [x] 🎯 Plattformspezifischer Abgleich (linux-debian / linux-rhel / macos)
  - [x] 🛡️ LLM-Sicherheitsregeln (strikte Durchsetzung + Suchbefehlsverbot)
  - [x] 🔧 Wissensdatenbank-Erstellungswerkzeug (CSV → SQLite)
  - [x] 💬 Freundliche API-Fehlermeldungen (401/429/timeout)
- [x] v1.3.1 — Anbieter-Ökosystem
  - [x] 🌐 20+ AI-Anbieter-Voreinstellungen (12 China + 8 Global + Ollama + Benutzerdefiniert)
  - [x] 🔄 Remote-Anbieter-Konfigurationsupdates (kein App-Update nötig)
  - [x] 🏷️ Anbieterbeschreibungen und Preisinformationen
  - [x] 🤖 Voreingestellte Modell-Schnellauswahl (Ein-Klick)
  - [x] 🦙 Ollama lokale Bereitstellung (kein API-Schlüssel, völlig kostenlos)
  - [x] 📐 Dialog zum Hinzufügen von Modellen optimiert (Breitbild-Zweispalten-Layout)
- [x] v1.3.5 — Ops-Fähigkeiten Mega-Upgrade
  - [x] 📊 Echtzeit-Server-Überwachung (CPU/Speicher/Festplatte/Netzwerk, Mehrhost-parallel)
  - [x] 📝 Änderungsprotokoll & Audit-Logs (vollständige Betriebsgeschichte, nachverfolgbar & rollback-bereit)
  - [x] 📋 Ops-Runbooks (integrierte Vorlagen + benutzerdefiniert, Ein-Klick-Ausführung)
  - [x] 🔔 Benachrichtigungszentrum (Aufgabenabschluss, Anomaliewarnungen, Sicherheitserinnerungen)
  - [x] 🎨 Glassmorphismus UI-Neugestaltung (GlassCard-Design, Themensystem-Upgrade)
  - [x] 🌍 15+ Sprachen Lokalisierung
  - [x] 📺 Mehrhost-Orchestrierung (Workflows über Server hinweg parallel/sequenziell ausführen)

## 🤝 Mitwirken

Beiträge willkommen! Fehlerberichte, Funktionsvorschläge oder Code.

1. Forken Sie dieses Repository
2. Erstellen Sie einen Feature-Branch (`git checkout -b feature/amazing-feature`)
3. Committen Sie Ihre Änderungen (`git commit -m 'Add amazing feature'`)
4. Pushen Sie zum Branch (`git push origin feature/amazing-feature`)
5. Öffnen Sie eine Pull Request

## 📄 Lizenz

[MIT-Lizenz](./LICENSE)

---

## ⭐ Star-Verlauf

[![Star History Chart](https://api.star-history.com/svg?repos=keiskeies/ai_terminal&type=Date)](https://star-history.com/#keiskeies/ai_terminal&Date)

---

<p align="center">
  Wenn dieses Projekt Ihnen hilft, geben Sie ihm bitte ein ⭐ Star!
</p>
