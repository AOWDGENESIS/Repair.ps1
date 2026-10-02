# Mitwirken

Danke für dein Interesse. Ein paar Regeln halten das Projekt berechenbar.

## Regel Nr. 1: Jede Fehlerbehebung erhöht die Versionsnummer

Kein Fix ohne Versionssprung – auch nicht der kleinste. Sonst lässt sich
hinterher nicht mehr sagen, welcher Stand beim Nutzer läuft.

```powershell
# Fehler behoben? Dann so abschließen:
.\tools\Update-Version.ps1 -BumpPatch -Reason "Absturz beim Formatieren behoben"

# Neue Funktion, abwärtskompatibel:
.\tools\Update-Version.ps1 -BumpMinor -Reason "..."

# Bestimmte Version setzen:
.\tools\Update-Version.ps1 -Version 1.3.0
```

Das Werkzeug setzt die Nummer an **allen 21 Stellen** gleichzeitig
(Module, Server, Kommandozeile, Auftragsskripte, `package.json`,
Inno-Setup, `Install.cmd`, Oberfläche, beide READMEs, Testerwartung) und
legt auf Wunsch den CHANGELOG-Eintrag an.

Kontrolle – und zugleich ein Test, der jeden Lauf scheitern lässt, sobald
etwas auseinanderläuft:

```powershell
.\tools\Update-Version.ps1 -Check      # Exitcode 1 bei Abweichung
```

Zählweise: `1.2.3 → 1.2.4` Fehlerbehebung · `→ 1.3.0` neue Funktion ·
`→ 2.0.0` Bruch mit bisherigem Verhalten.

## Grundsätze

1. **Reparieren und warten – nicht „tunen".** Beiträge, die Registry-Werte verbiegen,
   Dienste abschalten oder Sicherheitsfunktionen deaktivieren, werden nicht übernommen.
2. **Keine Abhängigkeiten.** Kein NuGet, kein npm, keine PowerShell-Galerie zur Laufzeit.
   Alles muss auf einem frischen Windows 10/11 ohne Internet laufen.
3. **Jeder Eingriff ist simulierbar.** Neue verändernde Funktionen brauchen
   `SupportsShouldProcess` und müssen mit `-WhatIf` sauber nichts tun.
4. **Zweisprachig.** Neue Texte in der Oberfläche gehören in `web/i18n/de.json`
   **und** `web/i18n/en.json`. Der Selbsttest prüft, dass beide dieselben Schlüssel haben.

## Zielversion

Alles muss unter **Windows PowerShell 5.1** laufen. PowerShell 7 ist erlaubt, aber nie
Voraussetzung. Konkret verboten:

- `break`, `continue` oder `return` direkt in einem `finally`-Block (`ControlLeavingFinally`)
- `??`, `?.`, `??=`, Ternäroperator
- Pipeline-Ketten `&&` und `||`
- `ForEach-Object -Parallel`, `$PSStyle`

Die Prüfung dafür ist eingebaut:

```powershell
.\tests\Test-Compat51.ps1
```

## Vor jedem Pull Request

```powershell
.\tests\Test-RepairCenter.ps1          # 101 Tests
npm test                                # 83 Oberflächentests
.\tests\Test-Compat51.ps1              # ohne Befund
.\tools\Update-Version.ps1 -Check      # Version überall gleich
.\tools\Invoke-Analyzer.ps1              # statische Prüfung
```

Bitte den Analyzer über dieses Werkzeug aufrufen, nicht direkt: ein nackter
`Invoke-ScriptAnalyzer` meldet **„keine Befunde", wenn das Modul gar nicht
geladen ist** – die Prüfung besteht dann scheinbar. Das Werkzeug bricht
stattdessen ab und prüft sich zusätzlich an einer absichtlich fehlerhaften
Datei selbst.

Die Einstellungsdatei schaltet genau zwei Regeln ab und begründet das darin.
Alles andere bleibt scharf – insbesondere
`PSUseShouldProcessForStateChangingFunctions`, weil dieses Werkzeug
Datenträger löscht.

## Stil

- Deutsche Kommentare, deutsche Ausgaben im Backend; die Oberfläche ist über die
  Sprachpakete zweisprachig.
- Keine Umlaute in Quelltextkommentaren (`ae`, `oe`, `ue`) – das vermeidet
  Kodierungsprobleme zwischen Windows PowerShell und PowerShell 7.
- Genehmigte PowerShell-Verben (`Get-`, `Invoke-`, `Test-`, `Clear-` …).
- Vier Leerzeichen Einrückung, keine Tabs, keine Backtick-Zeilenumbrüche,
  wo Splatting möglich ist.

## Commit-Nachrichten

Kurze Zusammenfassung in der ersten Zeile, dann Details. Beispiel:

```
Engine: RestoreHealth nur bei Bedarf ausfuehren

CheckHealth vorab entscheidet, ob die Reparatur ueberhaupt noetig ist.
Spart im Normalfall mehrere Minuten Laufzeit.
```
