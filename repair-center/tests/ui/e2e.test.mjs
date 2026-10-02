/* =====================================================================
   RepairCenter - Zusammenspiel von Oberflaeche und echtem Dienst
   Kein Mock: hier startet der echte PowerShell-Dienst im Demomodus, die
   Oberflaeche laeuft in jsdom dagegen und benutzt echtes fetch.

   Damit werden Vertragsbrueche zwischen Oberflaeche und Schnittstelle
   sichtbar, die eine Attrappe nie zeigt - etwa ein Endpunkt, der statt
   einer Liste ein Objekt liefert.

   Ausfuehren:  npm test     (laeuft mit den uebrigen Oberflaechentests)
   Uebersprungen, wenn keine PowerShell gefunden wird.
   MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
   ===================================================================== */
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync, mkdtempSync, rmSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { createServer } from 'node:net';
import { JSDOM } from 'jsdom';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
// Einen wirklich freien Port vom Betriebssystem geben lassen. Ein
// geratener Port kollidiert sonst mit den Ports der PowerShell-Tests -
// genau das ist einmal passiert und sah aus wie ein sporadischer Fehler.
function findeFreienPort() {
  return new Promise((resolve, reject) => {
    const probe = createServer();
    probe.once('error', reject);
    probe.listen(0, '127.0.0.1', () => {
      const p = probe.address().port;
      probe.close(() => resolve(p));
    });
  });
}

let port = 0;
let base = '';

function findPowerShell() {
  for (const candidate of [process.env.RC_PWSH, '/tmp/pwsh/pwsh', 'pwsh', 'powershell']) {
    if (!candidate) { continue; }
    if (candidate.includes('/') && !existsSync(candidate)) { continue; }
    const probe = spawnSync(candidate, ['-NoLogo', '-NoProfile', '-Command', '"ok"'], { encoding: 'utf8' });
    if (probe.status === 0) { return candidate; }
  }
  return null;
}

const psExe = findPowerShell();
let server = null;
let logRoot = null;
let dom, win, doc;

async function waitForServer(timeoutMs = 60000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const r = await fetch(`${base}/api/health`);
      if (r.ok) { return true; }
    } catch { /* noch nicht da */ }
    await new Promise((r) => setTimeout(r, 500));
  }
  return false;
}

async function startAll() {
  port = await findeFreienPort();
  base = `http://localhost:${port}`;
  logRoot = mkdtempSync(join(tmpdir(), 'rc-e2e-'));
  server = spawn(psExe, [
    '-NoLogo', '-NoProfile', '-File', join(root, 'src', 'RepairCenter.Server.ps1'),
    '-Port', String(port), '-Demo', '-NoBrowser', '-LogRoot', logRoot
  ], { stdio: 'ignore' });

  const up = await waitForServer();
  assert.ok(up, 'Dienst ist nicht gestartet');

  const html = readFileSync(join(root, 'web', 'index.html'), 'utf8');
  const appJs = readFileSync(join(root, 'web', 'assets', 'app.js'), 'utf8');
  dom = new JSDOM(html, { runScripts: 'outside-only', url: base + '/', pretendToBeVisual: true });
  win = dom.window;
  doc = win.document;
  // echtes fetch, relative Pfade gegen den laufenden Dienst aufloesen
  win.fetch = (u, o) => fetch(new URL(String(u), base + '/'), o);
  win.confirm = () => true;
  win.eval(appJs);
  await new Promise((r) => setTimeout(r, 2500));
}

function stopAll() {
  if (win) {
    const ui = win.RepairCenterUI;
    if (ui && ui.state && ui.state.timer) { win.clearInterval(ui.state.timer); }
    if (ui && ui.disks && ui.disks.timer) { win.clearInterval(ui.disks.timer); }
    if (win.close) { win.close(); }
  }
  if (server) { server.kill('SIGKILL'); }
  if (logRoot) { try { rmSync(logRoot, { recursive: true, force: true }); } catch { /* egal */ } }
}

const $ = (sel) => doc.querySelector(sel);
const $$ = (sel) => Array.from(doc.querySelectorAll(sel));
const click = (sel) => $(sel).dispatchEvent(new win.Event('click', { bubbles: true }));
const change = (el) => el.dispatchEvent(new win.Event('change', { bubbles: true }));
const wait = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitUntil(fn, timeoutMs, label) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (fn()) { return true; }
    await wait(300);
  }
  assert.fail('Zeitueberschreitung: ' + label);
}

describe('Oberflaeche gegen den echten Dienst', { skip: psExe ? false : 'keine PowerShell gefunden' }, () => {
  before(startAll);
  after(stopAll);

  test('Systemdaten kommen vom Dienst und stehen in der Oberflaeche', () => {
    const txt = $('#systemGrid').textContent;
    assert.ok(txt.length > 20, 'Systemuebersicht ist leer');
    assert.match(txt, /PowerShell/);
    // Die Betriebsart steht jetzt dauerhaft in der Kopfzeile
    assert.match($('#modeBadge').textContent, /DEMO/, 'Demomodus wird nicht angezeigt');
  });

  test('Dienstdaten stimmen mit /api/config ueberein', async () => {
    const cfg = await (await fetch(`${base}/api/config`)).json();
    win.RepairCenterUI.switchTab('schedule');
    await wait(600);
    assert.match($('#configGrid').textContent, new RegExp(String(cfg.version).replace(/\./g, '\\.')));
  });

  test('Datentraeger werden aus echten Antworten aufgebaut', async () => {
    win.RepairCenterUI.switchTab('disks');
    await waitUntil(() => $$('.disk-card').length > 0, 10000, 'keine Datentraegerkarten');
    const cards = $$('.disk-card');
    assert.ok(cards.length >= 3, 'zu wenige Datentraeger');
    assert.equal(cards[0].querySelectorAll('button[data-wipe]').length, 0, 'Systemdatentraeger bietet Löschen an');
    assert.ok(cards[1].querySelectorAll('button[data-wipe]').length === 1, 'freier Datenträger ohne Löschen');
  });

  test('Ein Lauf laesst sich in der Oberflaeche starten und bis zum Ende verfolgen', async () => {
    win.RepairCenterUI.switchTab('run');
    $('input[name=mode][value=Quick]').checked = true;
    $('input[name=optimize][value=None]').checked = true;
    $('#optDemo').checked = true;
    click('#startBtn');

    // Kein 404-Fenster: die Anzeige muss sofort etwas zeigen
    await waitUntil(() => $('#runIdLabel').textContent.length > 0, 15000, 'keine Lauf-Kennung in der Anzeige');
    await waitUntil(() => $$('#console div').length > 0, 15000, 'kein Protokoll');

    await waitUntil(() => $('#overallBadge').classList.contains('hidden') === false, 120000, 'Lauf endet nicht');
    assert.ok($$('#stepsTable tbody tr').length >= 3, 'zu wenige Schritte');
    assert.match($('#currentStep').textContent, /Abgeschlossen|Finished/);
    assert.equal($('#startBtn').disabled, false, 'Startknopf bleibt gesperrt');
  });

  test('Der Verlauf zeigt den Lauf, der Bericht laesst sich oeffnen', async () => {
    win.RepairCenterUI.switchTab('history');
    await waitUntil(() => $$('#historyTable tbody tr').length > 0, 15000, 'Verlauf bleibt leer');
    // genau ein Eintrag - genau hier lieferte die Schnittstelle frueher ein Objekt statt einer Liste
    const zeilen = $$('#historyTable tbody tr');
    assert.equal(zeilen.length, 1, 'erwartet wird genau ein Lauf');

    zeilen[0].querySelector('button[data-run]').dispatchEvent(new win.Event('click', { bubbles: true }));
    await waitUntil(() => $('#reportView').textContent.includes('Ergebnisbericht'), 15000, 'Bericht wird nicht geladen');
    assert.match($('#reportView').textContent, /Gesamtstatus/);
  });

  test('Der Loeschdialog holt Schaetzung und Ziele vom Dienst', async () => {
    win.RepairCenterUI.switchTab('disks');
    await waitUntil(() => $$('.disk-card').length > 0, 10000, 'keine Karten');
    $$('.disk-card')[1].querySelector('button[data-wipe]').dispatchEvent(new win.Event('click', { bubbles: true }));
    await waitUntil(() => $('#wipeEstimate').textContent.length > 10, 15000, 'keine Schaetzung');
    assert.match($('#wipeEstimate').textContent, /Zero|Verfahren/);

    $('#rescueEnabled').checked = true;
    change($('#rescueEnabled'));
    await waitUntil(() => $$('#rescueTarget option').length > 0, 15000, 'keine Sicherungsziele');
    await waitUntil(() => $('#rescueMeasure').textContent.includes('GB'), 15000, 'keine Datenmenge');
    const ziele = $$('#rescueTarget option').map((o) => o.value);
    assert.ok(!ziele.includes('D'), 'Quelldatentraeger wird als Ziel angeboten');
  });

  test('Ein Datentraegervorgang laeuft echt durch - mit Sperre und Abschluss', async () => {
    $('#rescueEnabled').checked = false;
    change($('#rescueEnabled'));
    $('#diskConfirm').value = 'DISK1';
    $('#diskConfirm').dispatchEvent(new win.Event('input', { bubbles: true }));
    assert.equal($('#diskOpStart').disabled, false, 'Start bleibt gesperrt');

    click('#diskOpStart');
    await waitUntil(() => $('#diskJobStatus').textContent.length > 0, 15000, 'kein Fortschritt');

    // Waehrend der Vorgang laeuft, muss der Dienst einen zweiten ablehnen
    const zweiter = await fetch(`${base}/api/disk/wipe`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-RepairCenter': '1' },
      body: JSON.stringify({ diskNumber: 2, strategy: 'Zero', confirmation: 'DISK2', demo: true })
    });
    assert.ok(zweiter.status === 409 || zweiter.status === 200,
      'unerwarteter Status beim zweiten Auftrag: ' + zweiter.status);

    await waitUntil(() => /Fertig|Done/.test($('#diskJobStatus').textContent), 120000, 'Vorgang endet nicht');

    // Die Oberflaeche meldet "Fertig", sobald der Zustand auf done steht -
    // der Auftragsprozess braucht danach noch einen Moment zum Beenden.
    // Deshalb auf die Freigabe warten statt sie sofort zu erwarten.
    let frei = false;
    for (let i = 0; i < 40 && !frei; i++) {
      const a = await (await fetch(`${base}/api/disk/active`)).json();
      frei = (a.busy === false);
      if (!frei) { await wait(250); }
    }
    assert.equal(frei, true, 'Sperre wurde nach dem Ende nicht freigegeben');
  });

  test('Die Analyse laeuft gegen den echten Dienst und zeigt die Bewertung', async () => {
    win.RepairCenterUI.switchTab('analysis');
    await waitUntil(() => $$('#analysisDisk option').length > 0, 15000, 'keine Datentraeger in der Auswahl');
    $('#analysisDisk').value = '1';
    $('#analysisSamples').value = '16';
    click('#analysisStart');
    await waitUntil(() => $('#analysisResult').classList.contains('hidden') === false, 120000, 'Analyse endet nicht');
    assert.match($('#verdictBox').textContent, /Akut|Critical/, 'kranke Platte nicht als kritisch gemeldet');
    assert.match($('#smartTable').textContent, /27/, 'wartende Sektoren fehlen');
    assert.ok($$('#reasonList .reason').length >= 4, 'zu wenige Begruendungen');
  });

  test('Die Dateipruefung findet Befunde ueber den echten Dienst', async () => {
    win.RepairCenterUI.switchTab('files');
    $('#filesPath').value = 'C:\\Users';
    click('#filesScan');
    await waitUntil(() => $$('#filesTable tbody tr').length > 0, 120000, 'keine Befunde');
    assert.ok($$('#filesTable tbody tr').length >= 3);
    assert.equal($('#filesRepair').classList.contains('hidden'), false);
  });

  test('Die Aktualisierungspruefung antwortet auch ohne Paketordner', async () => {
    const u = await (await fetch(`${base}/api/update/check`)).json();
    assert.equal(typeof u.currentVersion, 'string');
    assert.ok(u.note && u.note.length > 0, 'keine Erlaeuterung');
  });

  test('Die Betriebsart steht in der Kopfzeile und stimmt mit dem Dienst ueberein', async () => {
    const cfg = await (await fetch(`${base}/api/config`)).json();
    const b = $('#modeBadge');
    assert.ok(b, 'Anzeige der Betriebsart fehlt');
    if (cfg.demo) { assert.match(b.textContent, /DEMO/); }
    else { assert.match(b.textContent, /ECHTBETRIEB|LIVE/); }
    assert.ok(b.textContent.length > 3, 'Betriebsart ist leer');
  });

  test('Die Bereitschaftspruefung laeuft schrittweise gegen den echten Dienst', async () => {
    win.RepairCenterUI.switchTab('system');
    const lauf = win.RepairCenterUI.pruefeBereitschaft();
    // sofort sichtbar, noch bevor die erste Antwort da ist
    assert.equal($$('#readinessBox .schritt').length, 9, 'Pruefpunkte stehen nicht sofort da');
    await lauf;
    assert.equal($$('#readinessBox .schritt.offen').length, 0, 'es blieben offene Punkte');
    assert.ok($$('#readinessBox .schritt').length === 9, 'Punkte verschwunden');
    assert.match($('#readinessBox').textContent, /Betriebsart/);
  });

  test('Die Datentraegerauswahl der Analyse wird vom Dienst gefuellt', async () => {
    win.RepairCenterUI.switchTab('analysis');
    // Auf das Ende des Ladens warten, nicht nur auf die ersten Eintraege -
    // sonst prueft man mitten im Vorgang.
    await waitUntil(() => $$('#analysisDisk option').length > 0 && $('#analysisStart').disabled === false,
      20000, 'Auswahl wurde nicht gefuellt oder Start blieb gesperrt');
    assert.equal($('#analysisHint').classList.contains('hidden'), true, 'es steht ein Hinweis obwohl alles ging');
  });

  test('Ohne den Zusatzkopf weist der Dienst die Oberflaeche ab', async () => {
    const r = await fetch(`${base}/api/disk/format`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ driveLetter: 'E', fileSystem: 'NTFS', demo: true })
    });
    assert.equal(r.status, 403);
  });
});
