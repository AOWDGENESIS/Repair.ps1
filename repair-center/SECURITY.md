# Sicherheit / Security

## Kurzfassung

RepairCenter verändert das Betriebssystem – bewusst und dokumentiert. Deshalb hier
offen, was es tut, welche Rechte es braucht und wo Daten liegen.

## Rechte

- Der Dienst und die Kommandozeile benötigen **Administratorrechte**, weil DISM, SFC,
  chkdsk und die Wartungsaufgaben ohne sie nicht funktionieren.
- Die Rechteerhöhung erfolgt über die reguläre **UAC-Abfrage**. Es wird nichts
  umgangen, nichts registriert, kein Dienst installiert.
- `installer\Install.cmd` bzw. das Setup benötigen Administratorrechte, um nach
  `%ProgramFiles%` zu schreiben und den Eintrag in „Apps & Features" anzulegen.

## Netzwerk

- Der Webdienst bindet standardmäßig auf **`localhost:8720`**. Er ist damit **nicht**
  aus dem Netzwerk erreichbar.
- Eine Bindung an alle Schnittstellen (`-BindAddress '*'`) ist technisch möglich,
  aber **nicht empfohlen**: die API kann Reparatur- und Wartungsläufe auslösen und
  besitzt bewusst keine Benutzerverwaltung.
- Es gibt **keine ausgehenden Verbindungen**: keine Updateprüfung, keine Telemetrie,
  keine Cloud, keine Schriftarten oder Skripte von Fremdservern. Die Oberfläche
  verwendet ausschließlich mitgelieferte Dateien.

## Schutz vor Anfragen fremder Webseiten (seit 1.2.1)

Ein lokaler Webdienst ist aus dem Browser des Nutzers erreichbar – auch von
einer beliebigen fremden Seite, die im Hintergrund ein Formular abschickt.
Bei einem Werkzeug, das Datenträger löscht, wäre das fatal. Deshalb:

- **Jede schreibende Anfrage** (POST, DELETE) muss den Zusatzkopf
  `X-RepairCenter: 1` tragen. Einen solchen Kopf kann eine fremde Seite nur
  nach einer Vorabanfrage (CORS-Preflight) setzen –
- **Vorabanfragen werden nicht beantwortet** (`OPTIONS` → 405). Damit scheitert
  der Versuch schon im Browser.
- Ist ein `Origin`-Kopf gesetzt, muss er auf den eigenen Dienst zeigen,
  sonst **403**.
- **Alle Felder werden gegen Positivlisten geprüft**, bevor daraus
  Prozessargumente werden: Laufwerksbuchstabe genau ein Zeichen, Dateisystem
  aus fester Liste, Zahlen mit Ober- und Untergrenze, Pfade ohne `..` und ohne
  Anführungszeichen, unbekannte Felder führen zu **400**.
- **Nur ein Datenträgervorgang gleichzeitig** (sonst **409**). Die Sperre gilt
  ab dem Startzeitpunkt, nicht erst wenn der Auftragsprozess läuft.
- Der Anfragekörper ist auf 64 KB begrenzt.

Diese Punkte sind als Negativtests hinterlegt: der Selbsttest prüft, dass die
Angriffe tatsächlich mit 403, 400 und 409 abgewiesen werden.

## Daten

- Berichte, Protokolle und Zustandsdaten liegen unter `C:\RepairLogs\runs\<Zeitstempel>\`
  und verlassen den Rechner nicht.
- Berichte enthalten Gerätenamen, Betriebssystemversion, Datenträgerbezeichnungen,
  Namen von Autostart-Einträgen sowie Dateipfade aus CBS.log. **Vor dem Weitergeben
  eines Berichts bitte kurz hineinsehen.**
- Die Deinstallation entfernt das Programm, **nicht** die Berichte. Diese müssen
  bei Bedarf von Hand gelöscht werden.

## Eingriffe ins System

| Stufe | Eingriff | Rückholbar |
|---|---|---|
| jede | DISM/SFC-Reparatur von Systemdateien | durch Windows selbst verwaltet |
| Sicher | Löschen temporärer Dateien, DNS-Cache leeren | Dateien sind temporär, Cache baut sich neu auf |
| Standard | WinSxS-Bereinigung, Update-Cache, Fehlerberichte, Thumbnails, TRIM/Defrag | Caches bauen sich neu auf |
| Aggressiv | `/ResetBase`, Papierkorb leeren, Update-Komponenten- und Netzwerk-Reset | **teilweise nicht**: nach `/ResetBase` sind Updates nicht mehr einzeln deinstallierbar, geleerte Papierkörbe sind endgültig |

Vor den Stufen *Standard* und *Aggressiv* wird automatisch ein Wiederherstellungspunkt
angelegt (sofern die Systemwiederherstellung aktiviert ist). Jede Stufe lässt sich
vorher mit `-WhatIf` bzw. der Option „Nur simulieren" vollständig durchspielen.

## Schutz vor Anfragen fremder Webseiten (seit 1.2.1)

Ein lokaler Webdienst ist aus dem Browser des Nutzers erreichbar – auch von
einer beliebigen fremden Seite, die im Hintergrund ein Formular abschickt.
Bei einem Werkzeug, das Datenträger löscht, wäre das fatal. Deshalb:

- **Jede schreibende Anfrage** (POST, DELETE) muss den Zusatzkopf
  `X-RepairCenter: 1` tragen. Einen solchen Kopf kann eine fremde Seite nur
  nach einer Vorabanfrage (CORS-Preflight) setzen –
- **Vorabanfragen werden nicht beantwortet** (`OPTIONS` → 405). Damit scheitert
  der Versuch schon im Browser.
- Ist ein `Origin`-Kopf gesetzt, muss er auf den eigenen Dienst zeigen,
  sonst **403**.
- **Alle Felder werden gegen Positivlisten geprüft**, bevor daraus
  Prozessargumente werden: Laufwerksbuchstabe genau ein Zeichen, Dateisystem
  aus fester Liste, Zahlen mit Ober- und Untergrenze, Pfade ohne `..` und ohne
  Anführungszeichen, unbekannte Felder führen zu **400**.
- **Nur ein Datenträgervorgang gleichzeitig** (sonst **409**). Die Sperre gilt
  ab dem Startzeitpunkt, nicht erst wenn der Auftragsprozess läuft.
- Der Anfragekörper ist auf 64 KB begrenzt.

Diese Punkte sind als Negativtests hinterlegt: der Selbsttest prüft, dass die
Angriffe tatsächlich mit 403, 400 und 409 abgewiesen werden.

## Datenträgerverwaltung (ab 1.1.0)

Diese Funktionen **vernichten Daten endgültig**. Deshalb gilt:

- Der **Systemdatenträger** und schreibgeschützte Medien werden abgelehnt –
  geprüft in der Oberfläche, in der REST-API und noch einmal in der Engine.
- Jeder Vorgang verlangt das **exakte Eintippen eines Bestätigungsschlüssels**
  (`DISK1` für Datenträger 1, `E:` für ein Volume). Ohne ihn bleibt die
  Schaltfläche gesperrt und die Engine verweigert den Dienst.
- **`CryptoErase`** vernichtet den BitLocker-Schlüssel. Die Daten liegen danach
  physisch noch auf dem Medium, sind aber ohne Schlüssel wertlos. Wer eine
  physische Vernichtung braucht, nimmt `Zero`.
- **`Trim`** meldet dem Laufwerk alle Blöcke als frei. Bei SSDs ist das die
  vom Hersteller vorgesehene Methode; eine zertifizierte Sanitisierung nach
  BSI oder NIST Purge ist es nicht – dafür braucht es ein Secure-Erase-
  Werkzeug des Herstellers.
- **`Zero`** überschreibt den gesamten Datenträger einmal mit Nullen. Für
  magnetische Laufwerke gilt das seit NIST SP 800-88 als ausreichend.
- Der Datenträger wird vor dem Überschreiben offline genommen und das Volume
  ausgehängt, damit Windows nicht dazwischenschreibt.

### Schutz vor Anfragen fremder Webseiten (seit 1.2.1)

Ein lokaler Webdienst ist aus dem Browser des Nutzers erreichbar – auch von
einer beliebigen fremden Seite, die im Hintergrund ein Formular abschickt.
Bei einem Werkzeug, das Datenträger löscht, wäre das fatal. Deshalb:

- **Jede schreibende Anfrage** (POST, DELETE) muss den Zusatzkopf
  `X-RepairCenter: 1` tragen. Einen solchen Kopf kann eine fremde Seite nur
  nach einer Vorabanfrage (CORS-Preflight) setzen –
- **Vorabanfragen werden nicht beantwortet** (`OPTIONS` → 405). Damit scheitert
  der Versuch schon im Browser.
- Ist ein `Origin`-Kopf gesetzt, muss er auf den eigenen Dienst zeigen,
  sonst **403**.
- **Alle Felder werden gegen Positivlisten geprüft**, bevor daraus
  Prozessargumente werden: Laufwerksbuchstabe genau ein Zeichen, Dateisystem
  aus fester Liste, Zahlen mit Ober- und Untergrenze, Pfade ohne `..` und ohne
  Anführungszeichen, unbekannte Felder führen zu **400**.
- **Nur ein Datenträgervorgang gleichzeitig** (sonst **409**). Die Sperre gilt
  ab dem Startzeitpunkt, nicht erst wenn der Auftragsprozess läuft.
- Der Anfragekörper ist auf 64 KB begrenzt.

Diese Punkte sind als Negativtests hinterlegt: der Selbsttest prüft, dass die
Angriffe tatsächlich mit 403, 400 und 409 abgewiesen werden.

## Datensicherung vor dem Löschen

- **Verschieben** (`/MOVE`) löscht die Quelldateien, sobald sie erfolgreich
  kopiert wurden. Wer auf Nummer sicher gehen will, nimmt **Kopieren** – die
  Quelle verschwindet dann ohnehin beim anschließenden Löschen.
- Die Sicherung läuft mit den Rechten des Dienstes (Administrator). Dateirechte
  werden mit `/COPY:DAT` **nicht** übernommen: kopiert werden Daten, Attribute
  und Zeitstempel, nicht die Zugriffsrechte. Das ist Absicht – so lassen sich
  die geretteten Daten hinterher ohne Rechteprobleme lesen.
- Das Ziel wird vorher auf freien Platz geprüft. Schlägt die Sicherung fehl,
  wird der Löschvorgang **nicht** gestartet.

## Was ausdrücklich nicht passiert

- keine Registry-„Bereinigung", keine Tuning-Tweaks
- kein Abschalten von Diensten, kein eigenmächtiges Deaktivieren von Autostart-Einträgen
- kein Löschen von `Windows.old`, Benutzerprofilen oder Dokumenten
- keine Deaktivierung von Windows Defender oder Sicherheitsfunktionen

## Ausführungsrichtlinie

Die mitgelieferten Starter rufen PowerShell mit `-ExecutionPolicy Bypass` **für genau
diesen Start** auf. Die systemweite Richtlinie wird **nicht** verändert. Gilt per
Gruppenrichtlinie `AllSigned`, muss das Paket signiert werden – siehe README.

## Schwachstellen melden

Bitte ein Issue ohne Ausnutzungsdetails eröffnen oder den Maintainer direkt
kontaktieren. Ich melde mich zurück, sobald ich den Punkt nachvollzogen habe.
