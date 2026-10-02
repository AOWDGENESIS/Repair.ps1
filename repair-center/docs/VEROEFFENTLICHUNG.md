# Veröffentlichung auf GitHub

> **Status: NICHT veröffentlicht.**
> Es wurde nichts hochgeladen, kein Repository angelegt, kein Remote gesetzt.
> Dieser Leitfaden wird erst ausgeführt, wenn du ausdrücklich „posten" sagst.

## Vorher erledigen

- [ ] **Screenshots** aufnehmen (`docs/screenshots/ui-dark.png`, `ui-light.png`,
      `system.png`) und in beiden READMEs einbinden. Am einfachsten im Demomodus:
      `RepairCenter.cmd` starten, in der Oberfläche Demomodus anhaken, Lauf starten,
      dann mit `Win`+`Shift`+`S` aufnehmen.
- [ ] Setup bauen und einmal auf einem frischen Windows testen:
      `iscc installer\RepairCenter.iss` → `dist\RepairCenter-Setup-1.2.0.exe`
- [ ] `.\tests\Test-RepairCenter.ps1` auf Windows laufen lassen (hier bisher nur
      unter PowerShell 7 geprüft, dort 13/13).
- [ ] Einen echten, nicht simulierten Lauf auf einem Testrechner durchführen
      (`-Mode Diagnose` genügt für den Anfang).
- [ ] **Datenträgerverwaltung an echter Hardware prüfen** – mit einem USB-Stick
      oder einer Platte, deren Inhalt egal ist:
      Bestandsaufnahme · Formatieren NTFS/exFAT/FAT32 · FAT32 auf einem Medium
      über 32 GB · Wechsel FAT32 → NTFS · Löschen mit `Zero` (Durchsatz notieren)
      · Abbruch mitten im Lauf · Verweigerung des Systemdatenträgers
      · **Datensicherung vor dem Löschen** (kopieren und verschieben, Durchsatz
      notieren) · Verhalten bei zu kleinem Ziel · USB-Stick und Speicherkarte
      einstecken und prüfen, ob sie richtig benannt werden.
- [ ] Entscheiden: öffentlich oder privat.

## Repository anlegen und hochladen

```bash
cd repair-center

git init -b main
git add .
git commit -m "RepairCenter 1.2.0 - Windows reparieren, warten und Datentraeger verwalten (offline)"

# Variante A: mit GitHub CLI
gh repo create AOWDGENESIS/repair-center --public --source=. --remote=origin \
  --description "Lokale Windows-Reparatur mit Oberflaeche: DISM, SFC, chkdsk, gestufte Wartung - 100 % offline. | Local Windows repair suite - 100 % offline."
git push -u origin main

# Variante B: ohne CLI (Repository vorher auf github.com anlegen)
git remote add origin https://github.com/AOWDGENESIS/repair-center.git
git push -u origin main
```

## Release mit Setup-Datei

```bash
git tag -a v1.2.0 -m "RepairCenter 1.2.0"
git push origin v1.2.0

gh release create v1.2.0 dist/RepairCenter-Setup-1.2.0.exe \
  --title "RepairCenter 1.2.0" \
  --notes-file CHANGELOG.md
```

## Empfohlene Repository-Einstellungen

- **Themen (Topics):** `windows`, `powershell`, `dism`, `sfc`, `chkdsk`,
  `system-repair`, `maintenance`, `offline`, `german`, `english`, `disk-management`,
  `format`, `fat32`, `secure-erase`, `disk-wipe`
- **Beschreibung:** siehe `gh repo create` oben
- **Website:** leer lassen (keine Cloud-Komponente)
- **Issues:** an · **Wiki:** aus · **Discussions:** nach Bedarf
- **Branch-Schutz** für `main`, sobald ein zweiter Mitwirkender dazukommt

## Nach der Veröffentlichung

- [ ] Prüfen, ob die Badges in beiden READMEs korrekt anzeigen
- [ ] `../../releases`-Links im README zeigen automatisch auf das richtige Repository
- [ ] Bei `AllSigned`-Umgebungen: Signatur-Hinweis im README ergänzen oder
      signierte Skripte im Release mitliefern
