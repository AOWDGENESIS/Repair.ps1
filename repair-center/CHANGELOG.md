# Changelog

Alle nennenswerten Änderungen an diesem Projekt. Das Format orientiert sich an
[Keep a Changelog](https://keepachangelog.com/de/1.1.0/), die Versionierung an
[Semantic Versioning](https://semver.org/lang/de/).

## [1.5.1] – noch nicht veröffentlicht

### Behoben
- **Wettlauf im Oberflächentest.** Der Test prüfte die Freigabe der
  Vorgangssperre in dem Moment, in dem die Oberfläche „Fertig" anzeigt – der
  Auftragsprozess braucht danach aber noch einen Augenblick zum Beenden.
  Jetzt wird auf die Freigabe gewartet statt sie sofort zu erwarten.

## [1.5.0] – noch nicht veröffentlicht

Aus dem Echtbetrieb gemeldet: leere Datenträgerauswahl, kein erkennbarer
Fortschritt, und kein Beleg dafür, dass der Demomodus aus ist.

### Behoben
- **Die Datenträgerauswahl blieb leer – ohne jeden Hinweis.** Schlug
  `Get-Disk` fehl, lieferte der Dienst eine leere Liste und die Oberfläche
  verschluckte den Fehler in einem leeren `catch`. Jetzt meldet der Dienst
  den Grund (samt Hinweis auf Administratorrechte und den Dienst „Virtueller
  Datenträger"), und die Oberfläche zeigt ihn dort an, wo die Auswahl wäre –
  mit Schaltfläche **Erneut versuchen**. Die Liste wird außerdem schon beim
  Start geladen, nicht erst beim Wechsel in den Reiter.
- **„Analyse starten" ohne Auswahl** führte zu einem Aufruf mit leerer
  Datenträgernummer, der still hängen blieb. Jetzt ist der Knopf gesperrt,
  solange nichts auswählbar ist, und sagt es auch.
- **Ein scheiternder Prüfpunkt riss die ganze Bereitschaftsprüfung mit.**
  Unter Nicht-Windows warf die Werkzeugprüfung eine Ausnahme (leeres
  `SystemRoot`) und der Aufruf endete mit 500. Jeder Punkt hat jetzt seinen
  eigenen Schutzmantel und meldet im Zweifel „Prüfung nicht möglich: …".

### Neu
- **Betriebsart dauerhaft in der Kopfzeile**: grün **ECHTBETRIEB – echte
  Datenträger** oder gelb **DEMOMODUS – erfundene Werte**, dazu im
  Fenstertitel. Vorher war der Echtbetrieb nur am *Fehlen* eines Abzeichens
  erkennbar – also gar nicht.
- **Lebendanzeige in allen Bereichen**: Laufrad, Tätigkeit und mitlaufende
  Dauer in der Kopfzeile, sichtbar auch nach einem Reiterwechsel; dazu je
  Bereich Laufrad, Prozentwert und verstrichene Zeit.
- **Bereitschaftsprüfung läuft schrittweise**: alle neun Punkte stehen sofort
  als „wird geprüft" da und füllen sich einzeln (`/api/readiness?step=…`).
- Tests auf **184** erweitert (101 PowerShell, 69 Oberfläche, 14 gegen den
  echten Dienst) – darunter: Betriebsart in beiden Zuständen, Lebendanzeige
  überdauert den Reiterwechsel, Fehler beim Lesen der Datenträger wird
  angezeigt, Bereitschaft füllt sich Zeile für Zeile.

## [1.4.4] – noch nicht veröffentlicht

### Behoben
- **Der Dienst startete nicht: „Der Wert '-Port' kann nicht in den Typ
  'System.Int32' konvertiert werden".** Der Starter übergab die Parameter als
  **Array** an das Dienstskript. Beim Splatting mit `@` werden Arrays
  *positionsweise* übergeben – damit landete die Zeichenkette `-Port` als
  Wert im Parameter `Port`. Für benannte Parameter braucht es eine
  Hashtabelle. Betroffen war genau eine Stelle; die beiden anderen
  Splatting-Aufrufe im Projekt sind korrekt (Hashtabelle bzw. native
  Befehlsargumente).

### Neu
- **Ein Test, der den Dienst wirklich über den Starter hochfährt** und prüft,
  dass Port und Betriebsart ankommen. Bisher wurde nur der Fehlerweg geprüft –
  deshalb blieb dieser Fehler unbemerkt. Genau die Lücke, die den Fehler
  durchgelassen hat, ist damit geschlossen.
- Der Pfad zur PowerShell wird in der Testhülle ganz zu Beginn bestimmt;
  vorher stand er erst weiter unten und frühere Tests liefen ins Leere.

## [1.4.3] – noch nicht veröffentlicht

Aus dem Echtbetrieb gemeldet: der Dienst schrieb im Sekundentakt
„Zustandsdatei … ist nicht lesbar". Dahinter steckten drei Fehler.

### Behoben
- **Die erste Zustandsdatei wurde nicht atomar geschrieben.** Sowohl bei
  Reparaturläufen als auch bei Datenträgeraufträgen ging sie direkt nach
  `state.json`. Wird der Dienst genau dabei beendet, bleibt eine leere oder
  halbe Datei zurück – genau das war passiert (0 Byte bzw. 65 Byte). Jetzt
  wird über eine Nebendatei geschrieben und umbenannt; das Umbenennen ist
  auf NTFS unteilbar.
- **Beschädigte Läufe verschwanden aus dem Verlauf.** Sie werden jetzt
  angezeigt – mit Zustand „unlesbar", dem genauen Grund (Meldung und
  Dateigröße) und einer Schaltfläche **Entfernen**. Wegsehen war die
  schlechteste Lösung: so wundert man sich nur, wo der Lauf geblieben ist.
- **Die Meldung wiederholte sich bei jeder Verlaufsabfrage.** Bei
  eingeschalteter automatischer Aktualisierung alle paar Sekunden erneut.
  Jetzt einmal je Lauf und Dienststart – im Versuch: **2 statt 12 Meldungen
  bei sechs Abfragen**.

### Neu
- `DELETE /api/run/{id}` entfernt einen Lauf samt Verzeichnis; in der
  Oberfläche über die Schaltfläche am beschädigten Eintrag.
- Leere Umwandlungsergebnisse werden nie geschrieben – eine gute Datei kann
  so nicht mehr von einem Fehlschlag überschrieben werden.

## [1.4.2] – noch nicht veröffentlicht

**Start und Installation gingen auf und sofort wieder zu.** Gemeldet aus der
Praxis, hier nachgestellt und auf drei Ursachen zurückgeführt.

### Behoben
- **Kein `pause` auf den Fehlerwegen.** Schlug irgendetwas fehl – Port belegt,
  Datei fehlt, Richtlinie greift –, schloss sich das Fenster, bevor man die
  Meldung lesen konnte. Jetzt hält **jeder** Fehlerweg das Fenster offen und
  nennt den nächsten Schritt.
- **Leere Argumentliste bei der Rechteerhöhung.** Beim Doppelklick ist `%*`
  leer, der Aufruf lautete `-ArgumentList ''` – unter Windows PowerShell 5.1
  bricht das ab. Die Erhöhung läuft jetzt über das PowerShell-Skript selbst,
  mit ordentlich aufgebauter Argumentliste.
- **Fortsetzungszeichen `^` in Klammerblöcken.** In cmd.exe eine berüchtigte
  Falle. Es gibt jetzt **kein einziges** mehr in den Startdateien.
- **Das Setup-Skript kopierte `tools\` nicht.** Eine mit Inno Setup gebaute
  Installation hätte den Starter nicht gehabt und wäre sofort unbrauchbar
  gewesen. Zusätzlich fehlten `Install.ps1`, `Uninstall.ps1` und `package.json`.

### Geändert
- **Die gesamte Logik wanderte aus Batch nach PowerShell**:
  `tools/Start-RepairCenter.ps1`, `installer/Install.ps1`,
  `installer/Uninstall.ps1`. Die `.cmd`-Dateien stoßen nur noch an und fangen
  Fehler ab. Der Starter prüft außerdem vorher, ob der Port schon belegt ist,
  und sagt dann, dass RepairCenter vermutlich bereits läuft.
- Umgebungsvariable `RC_NONINTERACTIVE=1` unterdrückt alle Wartefragen – für
  Tests und Automatisierung.

### Neu
- Sechs Tests rund um Start und Installation: Startdateien nur ASCII, mit
  CRLF, ohne Fortsetzungszeichen und ohne leere Argumentliste · **jeder
  Fehlerweg endet mit `pause`** · Installation kopiert alles und ist
  wiederholbar · unvollständige Quelle wird mit Hinweis abgelehnt · der
  Starter meldet eine fehlende Dienstdatei, statt sich zu schließen · **das
  Setup-Skript nimmt alles mit, was zum Start nötig ist**.

## [1.4.1] – noch nicht veröffentlicht

### Behoben
- **Sporadisch scheiternder Oberflächentest.** Die Tests gegen den echten
  Dienst wählten einen Zufallsport aus 8600–8899 – demselben Bereich, den die
  PowerShell-Tests benutzen. Eine Kollision sah aus wie ein Zufallsfehler.
  Jetzt vergibt das Betriebssystem einen garantiert freien Port.

## [1.4.0] – noch nicht veröffentlicht

Zwei Dinge, die den Schritt von der Vorschau auf echte Hardware ausmachen.

### Neu
- **Bereitschaftsprüfung für den Echtbetrieb** (Reiter *System*): prüft
  Administratorrechte, Betriebsart, SMART-Lesbarkeit je Datenträger,
  Zuverlässigkeitszähler, Ereignisprotokoll, Rohzugriff, Schattenkopien und die
  Bordwerkzeuge. Sagt im Klartext, was dieser Rechner hergibt – SMART wird von
  USB-Gehäusen und RAID-Controllern oft nicht durchgereicht, und das sollte man
  **vorher** wissen, nicht hinterher raten.
- **Aktualisierung einspielen** (`tools/Apply-Update.ps1` und
  `POST /api/update/apply`): Sicherung anlegen → Paket prüfen → einspielen →
  Dienst neu starten. Schlägt etwas fehl, wird die Sicherung zurückgespielt;
  eine halb eingespielte Fassung kann nicht zurückbleiben. Ein laufender Dienst
  kann sich nicht selbst überschreiben, deshalb läuft das Einspielen als
  eigener Prozess.
- **`docs/ECHTBETRIEB.md`**: Anleitung für echte Datenträger – Start,
  Bereitschaft, Laufzeiten, empfohlene Reihenfolge und die Regel bei einer
  sterbenden Platte: **erst sichern, dann messen**.
- Startmenü-Eintrag **„RepairCenter (Demomodus)"** im Installer, damit der
  Echtbetrieb die Voreinstellung bleibt und der Demomodus trotzdem griffbereit ist.
- Tests auf **164** erweitert (90 PowerShell, 63 Oberfläche, 11 gegen den
  echten Dienst) – darunter das vollständige Einspielen eines Pakets samt
  Sicherung und der Nachweis, dass ein unvollständiges Paket **nichts** verändert.

### Behoben
- Beim Einbau der Abschaltung nach dem Einspielen war ein `break` in einem
  `finally`-Block gelandet – genau die Falle, für die dieses Projekt einen
  eigenen Linter hat. Der hat sie auch prompt gefunden.

## [1.3.0] – noch nicht veröffentlicht

Drei neue Fähigkeiten: eine Datenträgeranalyse, die Fehler tatsächlich findet,
die Suche nach defekten Dateien samt Reparatur, und Aktualisierung überall.

### Neu
- **`DiskAnalysis.psm1` – Datenträgeranalyse.** Liest die SMART-Rohwerte
  (wartende, nicht korrigierbare und ersetzte Sektoren, CRC, Betriebsstunden,
  Temperatur, Abnutzung) über Zuverlässigkeitszähler **und** rohe WMI-Daten,
  zählt die einschlägigen Einträge im Ereignisprotokoll und liest
  stichprobenartig ungepuffert über die gesamte Oberfläche. Daraus eine
  Bewertung in vier Stufen mit Begründung je Punkt.
  *Hintergrund:* `HealthStatus` meldet fast immer „Healthy" – auch bei
  hunderten wartenden Sektoren. Genau deshalb wirkten Fehler bisher unerkannt.
- **Ereignisse werden dem verursachenden Datenträger zugeordnet** (über
  `\Device\HarddiskN` im Ereignistext), statt alle Laufwerke in Sippenhaft zu
  nehmen.
- **`FileIntegrity.psm1` – defekte Dateien finden und reparieren.** Drei
  Schadensarten (nicht lesbar, Struktur beschädigt, leer), Formatprüfung für
  JPEG, PNG, GIF, PDF, ZIP/Office, GZIP, SQLite und EXE/DLL anhand von Kopf und
  Ende. Reparatur über SFC (ein Lauf für alle Systemdateien) oder
  Vorgängerversionen aus Schattenkopien; die beschädigte Fassung bleibt daneben
  liegen.
- **Aktualisierung in allen Bereichen**: eigener Knopf je Reiter, globaler Knopf
  in der Kopfzeile, Schalter **Auto** (alle 5 Sekunden, Auswahl wird gemerkt).
- **Aktualisierungsprüfung für das Programm** unter „Info": prüft einen Ordner
  auf `RepairCenter-X.Y.Z.zip`. Ohne Internet, ohne Selbstinstallation.
- **Neue Endpunkte**: `/api/disk/analyze`, `/api/files/scan`, `/api/files/repair`,
  `/api/update/check`.
- Tests auf **155** erweitert (85 PowerShell, 59 Oberfläche, 11 gegen den
  echten Dienst).

### Geändert
- Die Dateisuche läuft plattformneutral wirklich (vorher fiel sie außerhalb von
  Windows in den Demobetrieb und war damit gar nicht prüfbar).
- Das Versionswerkzeug pflegt jetzt **28 Stellen** statt 21 – beim Einbau fiel
  prompt auf, dass zwei davon zurückgeblieben waren.

## [1.2.10] – noch nicht veröffentlicht

### Behoben
- **Testdaten verschmolzen zu einer einzigen Zeichenkette.** In PowerShell
  binden `+` und `,` in einer Zeile anders als erwartet – aus zwei
  Prüffällen wurde einer mit unsinnigem Inhalt. Der Umlaut-Test prüfte
  dadurch gar nichts. Werte werden jetzt erst gebildet, dann in die Liste
  gelegt, und der Test zählt seine eigenen Einträge nach.
- Fehlgeschlagene Anfragen in Tests nennen jetzt die **Begründung des
  Dienstes** statt nur „400" – erst dadurch war der Fehler zu finden.

## [1.2.9] – noch nicht veröffentlicht

### Behoben
- **Argumente mit Leerzeichen gingen beim Start des Auftragsprozesses
  verloren.** Aus `D:\Rettung Büro Ordner` wurde `D:\Rettung` – die
  Anführungszeichen wurden nur unter Windows gesetzt, obwohl
  `Start-Process` die Argumentliste auf **jeder** Plattform zu einer
  Kommandozeile zusammensetzt und an Leerzeichen trennt. Nachgemessen und
  jetzt durchgängig in Anführungszeichen.

## [1.2.8] – noch nicht veröffentlicht

### Behoben
- **Umlaute in Bezeichnungen und Zielpfaden wurden abgewiesen.** Der
  Positivfilter kannte nur `A-Z`, sodass ein deutschsprachiges Werkzeug an
  „Büro Ärger Straße" scheiterte. Jetzt `\p{L}` – Buchstaben heißt
  Buchstaben, auch mit Umlaut oder Akzent. Anführungszeichen, Striche und
  Rohrzeichen bleiben verboten.
- Unlesbare Zustandsdateien werden im Dienstprotokoll **gemeldet**, statt
  stillschweigend aus dem Verlauf zu verschwinden.

### Neu
- **`tests/ui/e2e.test.mjs`**: acht Tests, in denen die echte Oberfläche
  gegen den **echten Dienst** läuft – kein Mock. Genau diese Art Test hätte
  den Listen-Fehler aus 1.2.5 sofort gezeigt.

## [1.2.7] – noch nicht veröffentlicht

### Behoben
- **In zwei neuen Tests wurde `$args` überschrieben** – eine automatische
  Variable von PowerShell. Gefunden hat das erst der Analyzer, nachdem er
  überhaupt wieder lief (siehe nächster Punkt).
- **Die statische Prüfung meldete Erfolg, obwohl das Analyzer-Modul fehlte.**
  Ein nacktes `Invoke-ScriptAnalyzer` schreibt bei fehlendem Modul eine
  Fehlermeldung nach stderr und liefert *nichts* zurück – die Abfrage
  „keine Befunde?" ist dann wahr. Genau so bestand die Prüfung monatelang
  scheinbar.

### Neu
- **`tools/Invoke-Analyzer.ps1`**: bricht ab, wenn das Modul fehlt, nennt die
  geladene Version und **prüft sich an einer absichtlich fehlerhaften Datei
  selbst**. Liefert diese keine Befunde, arbeitet die Prüfung nicht und das
  Werkzeug schlägt fehl. CI und Selbsttest rufen jetzt dieses Werkzeug auf.

## [1.2.6] – noch nicht veröffentlicht

### Behoben
- **Ein abgebrochener Reparaturlauf sah aus wie ein erfolgreicher.** Der Abbruch
  setzt eine Steuerdatei; die Engine bemerkt sie und läuft geordnet zu Ende –
  meldete danach aber ein ganz normales Ergebnis (`REPAIRED`). Jetzt wird der
  Lauf als `CANCELLED` gekennzeichnet, überspringt die restlichen Abschnitte,
  erhält einen eigenen Schritt „Abbruch" im Bericht und liefert Exitcode 2.

## [1.2.5] – noch nicht veröffentlicht

Gefunden durch Prüfung der Pfade, die noch nie gelaufen waren: Kommandozeile,
reine Datenrettung und die beiden Abbruchwege.

### Behoben
- **Listen-Endpunkte lieferten bei genau einem Eintrag ein Objekt statt einer
  Liste** (`/api/runs`, `/api/disks`, `/api/disk/targets`) und bei null
  Einträgen `null`. `ConvertTo-Json` packt einelementige Arrays aus – die
  Oberfläche ruft darauf aber `forEach` auf. Der Fehler wäre erst beim
  allerersten Lauf auf einem frischen Rechner aufgetreten.
- **Abgebrochene Vorgänge blieben für immer auf „läuft" stehen.** Nach dem
  Abschuss des Prozesses schreibt niemand mehr in die Zustandsdatei; der Dienst
  trägt den Abbruch jetzt selbst nach. Dabei zeigte sich ein zweiter Fehler:
  das Setzen eines Feldes, das es in der jeweiligen Zustandsdatei nicht gibt,
  wirft bei `PSCustomObject` eine Ausnahme – die mein `catch` verschluckt hat.
  Felder werden jetzt angelegt statt vorausgesetzt.
- **Doppelt vergebene Nummer 59** im Testbericht.
- **`/api/health` fehlte** in den Endpunkt-Tabellen beider READMEs.

### Neu
- Tests für Pfade, die bisher nur von Hand geprüft waren: **Kommandozeile
  end-to-end** (zwei Fälle, inklusive Exitcode 1 bei REPARIERT und 0 bei
  SAUBER), **Abbruch eines Datenträgervorgangs**, **Abbruch eines
  Reparaturlaufs**, **Listen-Endpunkte liefern immer ein Array**.

## [1.2.4] – noch nicht veröffentlicht

Gefunden durch einen **Lasttest**: sechs Testläufe gleichzeitig. Was einzeln
nie auffiel, trat unter Last sofort zutage.

### Behoben
- **404-Fenster nach dem Start eines Reparaturlaufs.** Zwischen `POST /api/run`
  und dem ersten Lebenszeichen des Laufprozesses antwortete `GET /api/run/{id}`
  mit 404 – unter Last mehrere Sekunden lang. Der Dienst legt den Zustand jetzt
  sofort selbst an, so wie es bei Datenträgeraufträgen seit 1.2.1 schon war.
- **Kennungen von Reparaturläufen bestanden nur aus dem Zeitstempel.** Zwei
  Läufe in derselben Sekunde hätten sich dasselbe Verzeichnis geteilt und ihre
  Zustandsdateien gegenseitig überschrieben. Jetzt mit Zufallsanteil
  (`New-RunIdentifier`).
- **Zufallsraum der Auftragskennungen war zu klein.** Vier Zeichen aus 36
  ergeben 1.679.616 Möglichkeiten – nach dem Geburtstagsparadoxon rund 7 %
  Kollisionswahrscheinlichkeit bei 500 Ziehungen, und genau das ist im Test
  eingetreten. Jetzt acht Hexzeichen aus einer GUID: 5000 von 5000 Ziehungen
  im selben Sekundentakt eindeutig.

### Geändert
- Der Eindeutigkeitstest zieht jetzt **2000 Kennungen beider Arten** statt 500.
- Neuer Test: ein frisch gestarteter Lauf ist **ohne Wartezeit** abfragbar.

## [1.2.3] - 2026-09-30

### Behoben
- Testhuelle nannte am Ende nicht, welcher Test gescheitert war - sporadische Fehler liessen sich dadurch nicht zuordnen

## [1.2.2] – noch nicht veröffentlicht

### Behoben
- **Sporadisch scheiternde Tests.** Die neue Vorgangssperre aus 1.2.1 ließ
  Tests gelegentlich am `409` des Vorgängers scheitern. Die Tests warten jetzt
  über `Wait-DiskJobFree`, bis kein Vorgang mehr läuft. Zur Absicherung viermal
  hintereinander ausgeführt: 4 × 58/58.
- **Die Oberfläche zeigte nur eine Statusnummer.** Bei `409`, `400` oder `403`
  stand dort „HTTP 409" statt der Begründung des Dienstes. Jetzt wird der
  Klartext angezeigt, bei Eingabefehlern zusätzlich die Liste der beanstandeten
  Felder. Außerdem wird der Startknopf nach einem Fehlschlag wieder freigegeben.

### Neu
- `GET /api/disk/active` meldet, ob gerade ein Datenträgervorgang läuft – für
  die Oberfläche und für Tests.

## [1.2.1] – noch nicht veröffentlicht

Tiefenprüfung des gesamten Projekts. Gefunden wurden sechs echte Mängel –
alle behoben, alle mit Test abgesichert.

### Behoben
- **Anfragen fremder Webseiten konnten Vorgänge auslösen.** Ein lokaler Dienst
  ist aus jedem Browserfenster erreichbar; ohne Schutz hätte eine beliebige
  Seite im Hintergrund einen Löschauftrag starten können. Jetzt wird der
  Zusatzkopf `X-RepairCenter` verlangt, Vorabanfragen werden abgelehnt und
  fremde `Origin`-Angaben abgewiesen.
- **Eingaben wanderten ungeprüft in Prozessargumente.** Jetzt Positivlisten für
  jedes Feld; unbekannte Felder, unsinnige Zahlen und Pfade mit `..` werden mit
  400 abgelehnt.
- **Zwei Datenträgervorgänge konnten gleichzeitig laufen.** Jetzt gesperrt (409)
  – und zwar ab dem Startzeitpunkt, nicht erst wenn der Auftragsprozess seine
  Zustandsdatei angelegt hat.
- **Auftrags-IDs kollidierten im selben Sekundentakt** und hätten sich dieselbe
  Ablage geteilt. `New-DiskJobId` hängt jetzt vier Zufallszeichen an; gegen
  500 Erzeugungen in einer Schleife geprüft.
- **Die Installationsroutine trug noch Version 1.0.0** und hätte das falsch in
  „Apps & Features" eingetragen.
- **PSScriptAnalyzer war nie über die neuen Dateien gelaufen.** Die Prüfung
  meldete 85 Befunde; jetzt läuft sie über `src`, `tools` und `tests` ohne
  Befund. Die Behauptung in der Dokumentation war vorher schlicht falsch.

### Neu
- **`tools/Update-Version.ps1`**: setzt die Versionsnummer an allen 21 Stellen
  zugleich, legt den CHANGELOG-Eintrag an und prüft mit `-Check` auf
  Abweichungen. Dazu die Projektregel: **jede Fehlerbehebung erhöht die
  Versionsnummer** – abgesichert durch einen Test, der bei Abweichung scheitert,
  und durch einen eigenen CI-Schritt.
- **`PSScriptAnalyzerSettings.psd1`**: zwei Regeln begründet abgeschaltet, alle
  übrigen scharf gestellt.
- Anfragekörper auf 64 KB begrenzt.
- Tests auf **107** erweitert (57 PowerShell, 50 Oberfläche).

### Geändert
- Funktionen, die etwas verändern, unterstützen jetzt durchgängig
  `ShouldProcess`; reine Buchhaltungsfunktionen sind mit Begründung ausgenommen.
- Parameter `$WhatIf` in `New-RepairState` heißt jetzt `$WhatIfMode` – der alte
  Name kollidierte mit dem eingebauten Mechanismus.

## [1.2.0] – noch nicht veröffentlicht

Daten retten, bevor gelöscht wird. Und Wechselmedien beim Namen nennen.

### Neu
- **Datensicherung vor dem Löschen**: Kopieren oder Verschieben aller Volumes
  eines Datenträgers auf ein frei wählbares Ziel. Oberfläche und Auftrag
  verketten beides zu einem Vorgang mit zwei Abschnitten
  (`Daten sichern` → `Löschen`).
- **Scheitert die Sicherung, wird nichts gelöscht.** Der Auftrag bricht mit
  klarer Meldung ab.
- **Tempo beim Kopieren**: `robocopy` mit 32 Kopierfäden (`/MT:32`) und
  ungepufferter Ein-/Ausgabe (`/J`), ohne den bremsenden Wiederaufnahmemodus
  `/Z`. Fadenzahl und Puffermodus sind einstellbar.
- **Platz- und Zielprüfung**: Datenmenge und Dateizahl werden vorher ermittelt,
  der freie Platz am Ziel geprüft; ein Ziel auf dem zu löschenden Datenträger
  wird abgelehnt.
- **Erkennung von USB-Sticks und Speicherkarten** (SD/MMC, USB-Stick,
  USB-Festplatte, USB-SSD, NVMe, Festplatte) samt Kennzeichnung als
  Wechselmedium – aus `Get-Disk`, `Get-PhysicalDisk` und `Win32_DiskDrive`
  zusammengeführt.
- **Neue Endpunkte**: `/api/disk/targets`, `/api/disk/measure`, `/api/disk/rescue`;
  `/api/disk/wipe` nimmt jetzt die Sicherungsangaben entgegen.
- Tests auf **95** erweitert (48 PowerShell, 47 Oberfläche).

## [1.1.0] – noch nicht veröffentlicht

Datenträgerverwaltung: formatieren, Dateisystem wechseln, endgültig löschen.

### Neu
- **Modul `DiskManager.psm1`**: Bestandsaufnahme aller Datenträger samt Volumes,
  Anbindung, Medientyp, BitLocker-Status und Schutzkennzeichnung.
- **Schnelles Löschen** mit fünf Verfahren (`Auto`, `CryptoErase`, `Trim`,
  `Zero`, `ZeroVerify`). Der Nullschreiber arbeitet ungepuffert
  (`FILE_FLAG_NO_BUFFERING | FILE_FLAG_WRITE_THROUGH`), mit 32-MiB-Blöcken und
  vier gleichzeitig offenen Anforderungen – dadurch Gerätetempo statt
  Cache-Flut. BitLocker wird per Schlüsselvernichtung erledigt, SSDs per TRIM.
- **Eigener FAT32-Formatierer** nach Microsoft-Spezifikation: FAT32 auch
  oberhalb der 32-GB-Grenze von Windows, geprüft bis 2 TiB (512-Byte-Sektoren)
  und 14 TiB (4-KiB-Sektoren). Nach einem Nulllauf entfällt das erneute Nullen
  der FAT – die Formatierung ist dann sofort fertig.
- **Dateisystemwechsel**: FAT32 → NTFS verlustfrei über `convert.exe`; jeder
  verlustbehaftete Wechsel wird vorher benannt und braucht eine gesonderte
  Zustimmung.
- **Reiter „Datenträger"** in der Oberfläche mit Schutzkennzeichnung,
  Dauerschätzung, Bestätigungsschlüssel, Live-Durchsatz und Restzeit.
- **Neue Endpunkte**: `/api/disks`, `/api/disk/estimate`, `/api/disk/format`,
  `/api/disk/convert`, `/api/disk/wipe`, `/api/disk/job/{id}` samt Abbruch.
- **Dreifaches Sicherheitsnetz**: Systemdatenträger und schreibgeschützte
  Medien werden in Oberfläche, API und Engine abgelehnt.

### Geändert
- Tests auf **78** erweitert (38 PowerShell, 40 Oberfläche).
- `fmtBytes` in der Oberfläche zeigt Kilobyte jetzt mit einer Nachkommastelle.
- `scrollIntoView` wird abgesichert aufgerufen (fehlt in manchen Umgebungen).

## [1.0.0] – noch nicht veröffentlicht

Erste Fassung. Aus dem Einzelskript `Repair.ps1` 3.0.1 wurde eine vollständige
Anwendung mit Oberfläche, Backend und Installationsroutine.

### Neu
- **Engine als Modul** (`RepairEngine.psm1`): Preflight, Reparatur, Eskalation,
  Verifikation, gestufte Wartung und Berichtserstellung – von Oberfläche,
  Kommandozeile und Tests gemeinsam genutzt.
- **Backend** (`RepairCenter.Server.ps1`): lokaler Webdienst auf Basis von
  `HttpListener` mit REST-API; bindet ausschließlich an `localhost`.
- **Oberfläche** (`web/`): Einzelseiten-Anwendung ohne jede Abhängigkeit,
  **Deutsch und Englisch** zur Laufzeit umschaltbar, helles und dunkles Design,
  Live-Fortschritt, Schritt-Tabelle, Protokoll, Befunde, Systemübersicht, Verlauf.
- **Runner** (`RepairCenter.Runner.ps1`): jeder Lauf als eigener Prozess, damit die
  Oberfläche nie blockiert; Abbruch über Steuerdatei und Prozessende.
- **Demomodus**: kompletter Durchlauf ohne jeden Eingriff ins System – für
  Vorführungen, Tests und CI.
- **Installationsroutine**: Inno-Setup-Skript (`RepairCenter.iss`) für ein
  klassisches Windows-Setup mit Assistent (DE/EN), Startmenü, Deinstallation und
  optionaler wöchentlicher Wartungsaufgabe; alternativ `Install.cmd` ohne Setup-Programm.
- **Testumgebung**: fünf Demo-Szenarien (`Healthy`, `Repaired`, `Escalation`, `Failed`,
  `Preflight`) simulieren jeden Verlauf, ohne das System anzufassen – auch in der
  Oberfläche auswählbar.
- **Wiederherstellungspunkt** vor den Wartungsstufen Standard und Aggressiv,
  abwählbar über `-NoRestorePoint` bzw. die Oberfläche.
- **Berichtsansicht, Planung und Neustart** direkt in der Oberfläche
  (`/api/config`, `/api/schedule`, `/api/restart`, `?format=cbs|transcript`).
- **Selbsttest** (`Test-RepairCenter.ps1`): 23 Tests über Engine, Szenarien, API,
  Sprachpakete und Pfadsicherheit – ohne Fremdmodule.
- **Oberflächentests** (`tests/ui/ui.test.mjs`): 29 Tests mit jsdom gegen eine Attrappe
  des Backends. Node.js wird ausschließlich zum Testen gebraucht.
- **Kompatibilitätsprüfung** (`Test-Compat51.ps1`): findet per AST- und Token-Analyse
  Konstrukte, die PowerShell 7 erlaubt, Windows PowerShell 5.1 aber ablehnt.

### Übernommen aus Repair.ps1 3.0.1
- Bewertung des SFC-Ergebnisses über **CBS.log** statt über unzuverlässige Exitcodes;
  die Logdatei wird auch gelesen, während Windows sie geöffnet hält.
- **Automatische Eskalation**: DISM + zweiter SFC-Lauf, wenn Dateien nicht reparierbar waren.
- `RestoreHealth` **nur bei Bedarf** statt bei jedem Lauf.
- Neustart wird nur dann verlangt, wenn es Gründe dafür gibt – inklusive Begründungsliste.
- Preflight: Rechte, Werkzeuge, Speicherplatz, laufende Wartung, ausstehender Neustart, Akkubetrieb.
- Sysnative-Behandlung für 32-Bit-PowerShell auf 64-Bit-Windows.
- Exitcodes 0/1/2/3 für Automatisierung, zusätzlich 4 (keine Rechte) und 5 (UAC abgebrochen).
- Automatische Rechteerhöhung der Kommandozeile inklusive Weitergabe aller Parameter.

### Behoben (gegenüber Repair.ps1 2.1 / 3.0)
- `Stop-Transcript` wurde auch dann aufgerufen, wenn `Start-Transcript` fehlgeschlagen war.
- Werkzeugausgabe landete wegen `Start-Process` nicht im Protokoll.
- `sfc`-Ausgabe war wegen UTF-16 unlesbar.
- `$ErrorActionPreference = 'Stop'` ließ jede stderr-Zeile eines nativen Werkzeugs
  den Schritt abbrechen (`NativeCommandError`).
- `break` innerhalb eines `finally`-Blocks – von PowerShell 7 akzeptiert, von
  Windows PowerShell 5.1 mit `ControlLeavingFinally` abgelehnt.
- Pauschale Neustart-Empfehlung am Ende jedes Laufs.
