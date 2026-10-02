# Echtbetrieb – RepairCenter gegen echte Datenträger

Alles, was in der Vorschau zu sehen ist, läuft dort im **Demomodus**: die Werte
sind erfunden, damit man die Oberfläche gefahrlos ausprobieren kann. Auf deinem
Windows ist der Echtbetrieb die **Voreinstellung** – Demomodus muss man
ausdrücklich einschalten.

## Woran du erkennst, was gerade läuft

| Merkmal | Demomodus | Echtbetrieb |
|---|---|---|
| Kennzeichen oben rechts | gelbes **DEMO** | keines |
| Reiter *Planung* → Betriebsart | „Demomodus" | „produktiv" |
| Startzeile des Dienstes | `Modus: DEMO (keine echten Eingriffe)` | `Modus: produktiv` |

## Starten

```powershell
# Echtbetrieb – so ist es gedacht
RepairCenter.cmd

# Demomodus, wenn du nur zeigen oder üben willst
RepairCenter.cmd -Demo
```

`RepairCenter.cmd` fordert selbst Administratorrechte an (UAC) und umgeht die
Ausführungsrichtlinie nur für diesen Start. Ohne Administratorrechte sind
Rohzugriff auf Datenträger, SFC, DISM und sämtliche Datenträgervorgänge nicht
möglich.

## Vor dem ersten Lauf: Bereitschaft prüfen

Reiter **System** → **Bereitschaft für den Echtbetrieb** → *Prüfen*.

Die Prüfung sagt dir, welche Messquellen dieser Rechner tatsächlich hergibt:

| Punkt | Was er bedeutet, wenn er fehlt |
|---|---|
| **Administratorrechte** | Ohne sie geht fast nichts – Start über `RepairCenter.cmd` wiederholen. |
| **SMART-Werte** | Über **USB-Gehäuse, Kartenleser und RAID-Controller** werden sie oft nicht durchgereicht. Die Analyse stützt sich dann auf Ereignisprotokoll und Oberflächenprüfung – beides funktioniert weiterhin. |
| **Zuverlässigkeitszähler** | Fehlt bei älteren Windows-Fassungen oder Fremdtreibern. |
| **Ereignisprotokoll** | Ohne Zugriff bleiben Lesefehler aus der Vergangenheit unsichtbar. |
| **Rohzugriff** | Nötig für Oberflächenprüfung und Überschreiben mit Nullen. |
| **Schattenkopien** | Ohne sie kann die Dateireparatur nur Systemdateien (über SFC) wiederherstellen. |

Ein Punkt in Gelb ist kein Fehler, sondern eine Einschränkung – sie wird im
Klartext benannt, statt dass hinterher leere Felder rätseln lassen.

## Was im Echtbetrieb anders ist

- **Datenträgeranalyse** liest echte SMART-Rohwerte, echte Ereignisse und liest
  wirklich über die Oberfläche. Eine Prüfung mit 64 Proben dauert je nach
  Laufwerk ein bis zwei Minuten, mit 1024 Proben entsprechend länger.
- **Dateiprüfung** liest echte Dateien. Ohne *Jede Datei vollständig lesen*
  werden nur Kopf und Ende geprüft – das schafft zehntausende Dateien in
  Minuten. Mit Tiefenprüfung läuft es mit der Lesegeschwindigkeit des
  Laufwerks, also bei 500 GB durchaus eine Stunde.
- **Reparatur** ersetzt Systemdateien über SFC und holt andere Dateien aus
  Schattenkopien zurück. Die beschädigte Fassung bleibt als `*.beschaedigt`
  daneben liegen – es wird nichts weggeworfen.
- **Datenträgervorgänge** (Formatieren, Löschen) verlangen weiterhin den
  Bestätigungsschlüssel und verweigern den Systemdatenträger.

## Empfohlene Reihenfolge beim ersten Mal

1. `RepairCenter.cmd` starten, **Bereitschaft prüfen**.
2. Reiter **Analyse**, Datenträger wählen, 64 Proben, *Analyse starten*.
   Ergebnis in Ruhe lesen – die Begründungen nennen jeden Messwert.
3. Bei Verdacht: Reiter **Dateien**, Ordner wählen, erst **ohne** Tiefenprüfung
   suchen. Das findet kaputte Strukturen in Minuten.
4. Erst danach mit Tiefenprüfung – und nur auf dem verdächtigen Laufwerk.
5. Reparieren: zuerst mit **Nur melden**, dann mit **Automatisch**.

## Wenn eine Platte als „Akut" gemeldet wird

In dieser Reihenfolge, nicht anders:

1. **Nichts weiter darauf schreiben.** Jeder Schreibvorgang kann den Schaden
   vergrößern.
2. **Daten retten**: Reiter *Datenträger* → *Löschen …* → **Daten vorher
   sichern** mit **Kopieren** (nicht Verschieben) auf ein gesundes Laufwerk.
   Das Löschen danach kannst du abbrechen – die Sicherung läuft zuerst.
3. Erst dann entscheiden, ob das Laufwerk ersetzt wird.

Eine Oberflächenprüfung oder gar ein Nulllauf auf einer sterbenden Platte kann
ihr den Rest geben. Deshalb: **erst sichern, dann messen.**
