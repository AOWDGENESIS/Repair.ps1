/* =====================================================================
   RepairCenter - Frontend
   MIT-Lizenz - Copyright (c) 2026 AOWD GENESIS
   Reines Vanilla-JavaScript, keine Abhaengigkeiten, keine Netzzugriffe
   ausser zur eigenen lokalen API.
   Vorgabe: Deutsch, dunkles Design.
   ===================================================================== */
(function () {
  'use strict';

  var DEFAULT_LANG = 'de';
  var DEFAULT_THEME = 'dark';

  var state = {
    lang: localStorage.getItem('rc.lang') || DEFAULT_LANG,
    theme: localStorage.getItem('rc.theme') || DEFAULT_THEME,
    dict: {},
    runId: null,
    timer: null,
    logCount: 0,
    lastState: null,
    reportRun: null,
    reportFmt: 'txt',
    config: null,
    autoTimer: null
  };
  if (state.lang !== 'de' && state.lang !== 'en') { state.lang = DEFAULT_LANG; }
  if (state.theme !== 'dark' && state.theme !== 'light') { state.theme = DEFAULT_THEME; }

  var doc = document;
  function $(sel) { return document.querySelector(sel); }
  function $$(sel) { return Array.prototype.slice.call(document.querySelectorAll(sel)); }
  function esc(s) {
    return String(s).replace(/[<>&]/g, function (c) { return ({ '<': '&lt;', '>': '&gt;', '&': '&amp;' })[c]; });
  }

  /* ----------------------------- i18n ----------------------------- */
  function t(key, fallback) {
    return (state.dict && state.dict[key]) ? state.dict[key] : (fallback || key);
  }

  function applyLanguage() {
    document.documentElement.lang = state.lang;
    $$('[data-i18n]').forEach(function (el) {
      var val = state.dict[el.getAttribute('data-i18n')];
      if (val) { el.textContent = val; }
    });
    $$('.lang-btn').forEach(function (b) {
      b.classList.toggle('active', b.getAttribute('data-lang') === state.lang);
    });
    document.title = t('app.title', 'RepairCenter');
  }

  function loadLanguage(lang) {
    return fetch('i18n/' + lang + '.json', { cache: 'no-store' })
      .then(function (r) { return r.json(); })
      .then(function (d) {
        state.dict = d;
        state.lang = lang;
        localStorage.setItem('rc.lang', lang);
        applyLanguage();
        if (lastSystem) { renderSystem(lastSystem); }
        if (lastHistory) { renderHistory(lastHistory); }
        if (state.lastState) { renderRun(state.lastState); }
        renderConfig();
      });
  }

  /* ---------------------------- Design ---------------------------- */
  /* ------------------ Betriebsart und Lebendanzeige ----------- */
  var leben = { laufend: {}, ticker: null };

  function zeigeBetriebsart() {
    var b = $('#modeBadge');
    if (!b) { return; }
    var demo = !!(state.config && state.config.demo);
    if (!state.config) {
      b.className = 'badge badge-mode';
      b.textContent = t('mode.unknown', 'verbinde \u2026');
      return;
    }
    b.className = 'badge badge-mode ' + (demo ? 'badge-demo-strong' : 'badge-live');
    b.textContent = demo ? t('mode.demo', 'DEMOMODUS') : t('mode.live', 'ECHTBETRIEB');
    b.title = demo ? t('mode.demoHint', '') : t('mode.liveHint', '');
    document.title = 'RepairCenter \u2013 ' + (demo ? t('mode.demoShort', 'Demomodus') : t('mode.liveShort', 'Echtbetrieb'));
  }

  // Jede laufende Arbeit meldet sich hier an - dadurch ist in JEDEM Reiter
  // sichtbar, dass gerade etwas passiert, und seit wann.
  function starteLeben(schluessel, text) {
    leben.laufend[schluessel] = { text: text, seit: Date.now() };
    zeichneLeben();
    if (!leben.ticker) { leben.ticker = setInterval(zeichneLeben, 1000); }
  }
  function aktualisiereLeben(schluessel, text) {
    if (leben.laufend[schluessel]) { leben.laufend[schluessel].text = text; zeichneLeben(); }
  }
  function beendeLeben(schluessel) {
    delete leben.laufend[schluessel];
    zeichneLeben();
    if (Object.keys(leben.laufend).length === 0 && leben.ticker) {
      clearInterval(leben.ticker); leben.ticker = null;
    }
  }
  function sekundenSeit(zeit) { return Math.max(0, Math.round((Date.now() - zeit) / 1000)); }

  function zeichneLeben() {
    var schluessel = Object.keys(leben.laufend);
    var feld = $('#activity');
    if (!feld) { return; }
    if (schluessel.length === 0) { feld.classList.add('hidden'); }
    else {
      var e = leben.laufend[schluessel[0]];
      $('#activityText').textContent = e.text + ' \u00b7 ' + fmtSeconds(sekundenSeit(e.seit));
      feld.classList.remove('hidden');
    }
    var zuordnung = { analyse: '#analysisElapsed', dateien: '#filesElapsed',
                      datentraeger: '#diskJobElapsed', packen: '#packElapsed' };
    Object.keys(zuordnung).forEach(function (k) {
      var ziel = $(zuordnung[k]);
      if (!ziel) { return; }
      ziel.textContent = leben.laufend[k] ? fmtSeconds(sekundenSeit(leben.laufend[k].seit)) : '';
    });
    var spinner = { '#analysisSpinner': 'analyse', '#filesSpinner': 'dateien',
                    '#diskJobSpinner': 'datentraeger', '#runSpinner': 'lauf', '#packSpinner': 'packen' };
    Object.keys(spinner).forEach(function (sel) {
      var el = $(sel);
      if (el) { el.classList.toggle('hidden', !leben.laufend[spinner[sel]]); }
    });
  }

  function applyTheme() {
    document.body.setAttribute('data-theme', state.theme);
    localStorage.setItem('rc.theme', state.theme);
  }

  /* ------------------------------ API ----------------------------- */
  // Jede Anfrage traegt den Zusatzkopf. Fremde Webseiten koennen ihn
  // ohne Vorabanfrage nicht setzen - der Dienst weist sie damit ab.
  function withHeaders(options) {
    var o = Object.assign({ cache: 'no-store' }, options || {});
    o.headers = Object.assign({ 'X-RepairCenter': '1' }, o.headers || {});
    return o;
  }

  function api(path, options) {
    return fetch(path, withHeaders(options)).then(function (r) {
      if (r.ok || r.status === 404) { return r.json(); }
      // Der Dienst begruendet Ablehnungen im Text - die ist fuer den
      // Nutzer brauchbarer als eine nackte Statusnummer.
      return r.json().then(function (data) {
        var msg = (data && data.error) ? data.error : ('HTTP ' + r.status);
        if (data && data.problems && data.problems.length) { msg += ' (' + data.problems.join('; ') + ')'; }
        throw new Error(msg);
      }, function () { throw new Error('HTTP ' + r.status); });
    });
  }

  function apiText(path) {
    return fetch(path, withHeaders()).then(function (r) {
      if (!r.ok) { throw new Error('HTTP ' + r.status); }
      return r.text();
    });
  }

  /* ---------------------------- System ---------------------------- */
  var lastSystem = null;

  function kv(label, value) {
    return '<div class="kv"><div class="k">' + esc(label) + '</div><div class="v">' + value + '</div></div>';
  }

  function renderSystem(s) {
    if (!s) { return; }
    lastSystem = s;
    var free = (s.freeSpaceGB === null || s.freeSpaceGB === undefined) ? '-' : s.freeSpaceGB + ' GB';
    if (s.totalSpaceGB) { free += ' / ' + s.totalSpaceGB + ' GB'; }
    var pending = (s.pendingReboot && s.pendingReboot.length);
    var reboot = pending
      ? '<span class="st st-WARNING">' + t('system.rebootYes', 'ausstehend') + '</span>'
      : '<span class="st st-PASS">' + t('system.rebootNo', 'nein') + '</span>';
    var admin = s.isAdmin
      ? '<span class="st st-PASS">' + t('system.adminYes', 'ja') + '</span>'
      : '<span class="st st-FAILED">' + t('system.adminNo', 'nein') + '</span>';
    var storeCls = (s.componentStore === 'Healthy') ? 'st-PASS' : 'st-WARNING';

    $('#systemGrid').innerHTML =
      kv(t('system.computer', 'Computer'), esc(s.computer || '-')) +
      kv(t('system.os', 'Betriebssystem'), esc((s.os || '-') + (s.build ? ' (Build ' + s.build + ')' : ''))) +
      kv(t('system.ps', 'PowerShell'), esc(s.psVersion || '-') + ' (' + (s.is64BitProcess ? '64' : '32') + ' Bit)') +
      kv(t('system.admin', 'Administrator'), admin) +
      kv(t('system.free', 'Freier Speicher'), esc(free)) +
      kv(t('system.store', 'Komponentenstore'), '<span class="st ' + storeCls + '">' + esc(s.componentStore || '-') + '</span>') +
      kv(t('system.reboot', 'Neustart'), reboot) +
      kv(t('system.uptime', 'Laufzeit'), (s.uptimeDays === null || s.uptimeDays === undefined) ? '-' : s.uptimeDays + ' ' + t('unit.days', 'Tage'));

    var pl = $('#pendingList');
    if (pending) {
      pl.innerHTML = '<div class="notice notice-warn">' + t('system.pendingTitle', 'Ausstehende Neustartgründe') + ': ' +
        esc(s.pendingReboot.join(', ')) + '</div>';
    } else { pl.innerHTML = ''; }

    if (s.maintenanceBusy && s.maintenanceBusy.length) {
      pl.innerHTML += '<div class="notice notice-warn">' + t('system.busy', 'Windows-Wartung läuft gerade') + ': ' +
        esc(s.maintenanceBusy.join(', ')) + '</div>';
    }

    var body = $('#diskTable').querySelector('tbody');
    body.innerHTML = '';
    (s.disks || []).forEach(function (d) {
      var tr = document.createElement('tr');
      tr.innerHTML = '<td>' + esc(d.name || '-') + '</td><td>' + esc(d.media || '-') + '</td>' +
        '<td>' + esc(String(d.sizeGB || '-')) + ' GB</td>' +
        '<td class="st ' + (d.health === 'Healthy' ? 'st-PASS' : 'st-FAILED') + '">' + esc(d.health || '-') + '</td>';
      body.appendChild(tr);
    });

    var badge = $('#adminBadge');
    badge.textContent = s.isAdmin ? t('badge.admin', 'Administrator') : t('badge.noadmin', 'eingeschränkt');
    badge.className = 'badge ' + (s.isAdmin ? 'badge-ok' : 'badge-err');
    badge.classList.remove('hidden');
    zeigeBetriebsart();
  }

  function refreshSystem() { return api('/api/system').then(renderSystem).catch(function () { }); }

  /* -------------------------- Konfiguration ----------------------- */
  function renderConfig() {
    if (!state.config) { return; }
    var c = state.config;
    $('#configGrid').innerHTML =
      kv(t('config.version', 'Version'), esc(c.version)) +
      kv(t('config.logRoot', 'Ablage der Berichte'), esc(c.logRoot)) +
      kv(t('config.port', 'Dienst'), 'localhost:' + esc(String(c.port))) +
      kv(t('config.mode', 'Betriebsart'), c.demo
        ? '<span class="st st-WARNING">' + t('config.demo', 'Demomodus') + '</span>'
        : '<span class="st st-PASS">' + t('config.live', 'produktiv') + '</span>');
  }

  /* ---------------------------- Verlauf --------------------------- */
  var lastHistory = null;

  function renderHistory(rows) {
    if (!rows) { return; }
    lastHistory = rows;
    var body = $('#historyTable').querySelector('tbody');
    body.innerHTML = '';
    rows.forEach(function (r) {
      var tr = document.createElement('tr');
      var when = r.startTime ? new Date(r.startTime).toLocaleString(state.lang === 'de' ? 'de-DE' : 'en-GB') : '-';
      var res;
      if (r.status === 'unreadable') {
        res = '<span class="st st-FAILED">' + t('history.unreadable', 'unlesbar') + '</span>';
      } else if (r.status === 'running') {
        res = '<span class="st st-WARNING">' + t('history.running', 'läuft') + '</span>';
      } else {
        res = '<span class="st st-' + (r.overall || '') + '">' + t('status.' + r.overall, r.overall || '-') + '</span>';
      }
      var space = (r.reclaimedGB && r.reclaimedGB !== 0) ? (r.reclaimedGB > 0 ? '+' : '') + r.reclaimedGB + ' GB' : '-';
      tr.innerHTML = '<td>' + esc(when) + (r.demo ? ' <span class="badge badge-demo">DEMO</span>' : '') + '</td>' +
        '<td>' + esc(r.mode || '-') + '</td><td>' + esc(r.optimize || '-') + '</td>' +
        '<td>' + res + '</td><td>' + esc(String(r.durationSec || 0)) + ' s</td><td>' + esc(space) + '</td>' +
        '<td>' + (r.status === 'unreadable'
          ? ('<button class="btn btn-small btn-ghost" data-remove="' + esc(r.runId) + '" title="' +
             esc(r.reason || '') + '">' + t('history.remove', 'Entfernen') + '</button>')
          : ('<button class="btn btn-small" data-run="' + esc(r.runId) + '">' + t('actions.open', 'Bericht') + '</button>')) +
        '</td>';
      body.appendChild(tr);
    });
    $$('#historyTable button[data-run]').forEach(function (b) {
      b.addEventListener('click', function () { showReport(b.getAttribute('data-run')); });
    });
    $$('#historyTable button[data-remove]').forEach(function (b) {
      b.addEventListener('click', function () {
        var id = b.getAttribute('data-remove');
        if (!window.confirm(t('history.confirmRemove', 'Diesen beschädigten Eintrag entfernen?') + '\n' + id)) { return; }
        api('/api/run/' + id, { method: 'DELETE' }).then(refreshHistory).catch(function (e) {
          window.alert(e.message);
        });
      });
    });
    $('#historyEmpty').classList.toggle('hidden', rows.length > 0);
    fillReportSelect(rows);
  }

  function refreshHistory() { return api('/api/runs').then(renderHistory).catch(function () { }); }

  /* ---------------------------- Bericht --------------------------- */
  function fillReportSelect(rows) {
    var sel = $('#reportRun');
    var current = sel.value;
    sel.innerHTML = '';
    (rows || []).forEach(function (r) {
      var o = document.createElement('option');
      o.value = r.runId;
      o.textContent = r.runId + '  (' + r.mode + '/' + r.optimize + ')';
      sel.appendChild(o);
    });
    if (current) { sel.value = current; }
    else if (state.reportRun) { sel.value = state.reportRun; }
  }

  function loadReport() {
    var id = $('#reportRun').value;
    if (!id) { $('#reportView').textContent = t('report.empty', 'Noch kein Bericht ausgewählt.'); return; }
    state.reportRun = id;
    var url = '/api/report/' + id + (state.reportFmt === 'txt' ? '' : '?format=' + state.reportFmt);
    apiText(url).then(function (txt) {
      $('#reportView').textContent = txt && txt.trim().length ? txt : t('report.none', 'Für diesen Lauf liegt diese Datei nicht vor.');
    }).catch(function () {
      $('#reportView').textContent = t('report.none', 'Für diesen Lauf liegt diese Datei nicht vor.');
    });
  }

  function showReport(runId) {
    state.reportRun = runId;
    switchTab('report');
    refreshHistory().then(function () {
      $('#reportRun').value = runId;
      loadReport();
    });
  }

  /* ------------------------------ Lauf ---------------------------- */
  function statusBadge(overall) {
    var el = $('#overallBadge');
    if (!overall || overall === 'UNKNOWN') { el.classList.add('hidden'); return; }
    var cls = 'badge-warn';
    if (overall === 'HEALTHY') { cls = 'badge-ok'; }
    if (overall === 'FAILED') { cls = 'badge-err'; }
    el.className = 'badge ' + cls;
    el.textContent = t('status.' + overall, overall);
    el.classList.remove('hidden');
  }

  function renderLog(logs) {
    var con = $('#console');
    var showTools = $('#showToolLines').checked;
    if (logs.length < state.logCount) { con.innerHTML = ''; state.logCount = 0; }
    for (var i = state.logCount; i < logs.length; i++) {
      var entry = logs[i];
      var div = document.createElement('div');
      div.className = 'l-' + (entry.kind || 'info');
      if (entry.kind === 'tool') { div.classList.add('is-tool'); }
      div.innerHTML = '<span class="t">' + esc(entry.t) + '</span>  ' + esc(entry.text);
      con.appendChild(div);
    }
    state.logCount = logs.length;
    con.classList.toggle('hide-tools', !showTools);
    con.scrollTop = con.scrollHeight;
  }

  function renderRun(s) {
    state.lastState = s;
    $('#progressBar').style.width = (s.progress || 0) + '%';
    $('#runIdLabel').textContent = s.runId || '';
    $('#currentStep').textContent = s.status === 'done'
      ? t('progress.done', 'Abgeschlossen.')
      : (s.currentStep ? t('step.' + s.currentStep, s.currentStep) : t('progress.running', 'Läuft ...'));

    if (s.startTime) {
      var sec = (s.status === 'done') ? s.durationSec : Math.round((new Date() - new Date(s.startTime)) / 1000);
      $('#elapsed').textContent = sec + ' s';
    }

    var body = $('#stepsTable').querySelector('tbody');
    body.innerHTML = '';
    (s.steps || []).forEach(function (st) {
      var tr = document.createElement('tr');
      tr.innerHTML = '<td>' + esc(t('step.' + st.name, st.name)) + '</td>' +
        '<td class="st st-' + esc(st.status) + '">' + esc(t('status.' + st.status, st.status)) + '</td>' +
        '<td>' + esc(String(st.durationSec || 0)) + ' s</td><td class="muted">' + esc(st.detail || '') + '</td>';
      body.appendChild(tr);
    });

    var f = $('#findings');
    f.innerHTML = '';
    (s.findings || []).forEach(function (x) {
      var d = document.createElement('div');
      d.className = 'finding f-' + x.level;
      d.textContent = x.text;
      f.appendChild(d);
    });

    renderLog(s.log || []);
    statusBadge(s.status === 'done' ? s.overall : null);

    var space = $('#spaceInfo');
    if (s.status === 'done' && s.reclaimedGB) {
      space.textContent = t('progress.space', 'Freigegebener Speicher') + ': ' +
        (s.reclaimedGB > 0 ? '+' : '') + s.reclaimedGB + ' GB';
      space.classList.remove('hidden');
    } else { space.classList.add('hidden'); }

    if (s.status !== 'done') {
      aktualisiereLeben('lauf', t('progress.running', 'Läuft ...') + ' ' + (s.progress || 0) + ' %');
    }
    if (s.status === 'done') {
      stopPolling();
      beendeLeben('lauf');
      $('#startBtn').disabled = false;
      $('#cancelBtn').classList.add('hidden');
      $('#reportLinks').classList.remove('hidden');
      $('#linkTxt').href = '/api/report/' + s.runId;
      $('#linkJson').href = '/api/report/' + s.runId + '?format=json';
      $('#linkTools').href = '/api/report/' + s.runId + '?format=tools';
      state.reportRun = s.runId;
      showRestartBanner(s);
      refreshHistory();
      refreshSystem();
    }
  }

  function showRestartBanner(s) {
    var banner = $('#restartBanner');
    if (!s.restartRequired) { banner.classList.add('hidden'); return; }
    $('#restartReasons').textContent = (s.restartReasons || []).join(' · ');
    banner.classList.remove('hidden');
  }

  function poll() {
    if (!state.runId) { return; }
    api('/api/run/' + state.runId).then(function (s) {
      if (s && s.runId) { renderRun(s); }
    }).catch(function () { });
  }

  function startPolling() { stopPolling(); state.timer = setInterval(poll, 1000); }
  function stopPolling() { if (state.timer) { clearInterval(state.timer); state.timer = null; } }

  function collectPayload() {
    return {
      mode: (document.querySelector('input[name=mode]:checked') || {}).value || 'Repair',
      optimize: (document.querySelector('input[name=optimize]:checked') || {}).value || 'Safe',
      whatIf: $('#optWhatIf').checked,
      skipDism: $('#optSkipDism').checked,
      skipSfc: $('#optSkipSfc').checked,
      skipDisk: $('#optSkipDisk').checked,
      noEscalate: $('#optNoEscalate').checked,
      noRestorePoint: $('#optNoRestorePoint').checked,
      demo: $('#optDemo').checked,
      demoScenario: $('#optScenario').value,
      tempFileAgeDays: parseInt($('#optTempAge').value, 10) || 2,
      minFreeSpaceGB: parseInt($('#optMinFree').value, 10) || 8
    };
  }

  function startRun() {
    var payload = collectPayload();
    if (payload.optimize === 'Aggressive' && !payload.whatIf && !payload.demo) {
      if (!window.confirm(t('confirm.aggressive', 'Aggressive Wartung wirklich ausführen? Einige Schritte lassen sich nicht rückgängig machen.'))) { return; }
    }
    $('#startBtn').disabled = true;
    $('#console').innerHTML = '';
    $('#findings').innerHTML = '';
    $('#stepsTable').querySelector('tbody').innerHTML = '';
    $('#reportLinks').classList.add('hidden');
    $('#restartBanner').classList.add('hidden');
    $('#spaceInfo').classList.add('hidden');
    state.logCount = 0;
    statusBadge(null);

    api('/api/run', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    }).then(function (r) {
      if (r.error) { throw new Error(r.error); }
      state.runId = r.runId;
      $('#cancelBtn').classList.remove('hidden');
      $('#currentStep').textContent = t('progress.starting', 'Wird gestartet ...');
      starteLeben('lauf', t('progress.running', 'Läuft ...'));
      startPolling();
    }).catch(function (e) {
      $('#startBtn').disabled = false;
      $('#currentStep').textContent = t('progress.error', 'Start fehlgeschlagen') + ': ' + e.message;
    });
  }

  function cancelRun() {
    if (!state.runId) { return; }
    api('/api/run/' + state.runId + '/cancel', { method: 'POST' }).then(function () {
      $('#currentStep').textContent = t('progress.cancelled', 'Abgebrochen.');
      $('#cancelBtn').classList.add('hidden');
      $('#startBtn').disabled = false;
      stopPolling();
      beendeLeben('lauf');
      refreshHistory();
    }).catch(function () { });
  }

  /* ----------------------------- Planung -------------------------- */
  function renderSchedule(s) {
    var el = $('#scheduleState');
    if (!s.supported) {
      el.className = 'notice notice-warn';
      el.textContent = t('schedule.unsupported', 'Aufgabenplanung steht nur unter Windows zur Verfügung.');
      $('#schedCreate').disabled = true;
      $('#schedDelete').disabled = true;
      return;
    }
    el.className = 'notice ' + (s.exists ? 'notice-ok' : '');
    el.textContent = s.exists
      ? t('schedule.exists', 'Eine wöchentliche Wartungsaufgabe ist eingerichtet.')
      : t('schedule.missing', 'Es ist keine Wartungsaufgabe eingerichtet.');
  }

  function refreshSchedule() { return api('/api/schedule').then(renderSchedule).catch(function () { }); }


  /* ----------------------- Datenträger ------------------------ */
  var disks = { list: [], op: null, jobId: null, timer: null, logCount: 0 };

  function fmtBytes(b) {
    if (b === null || b === undefined) { return '-'; }
    var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0, v = Number(b);
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    var decimals = (i === 0 || v >= 100) ? 0 : 1;
    return v.toFixed(decimals) + ' ' + u[i];
  }

  function fmtSeconds(sec) {
    if (sec === null || sec === undefined) { return '-'; }
    if (sec < 60) { return sec + ' s'; }
    if (sec < 3600) { return Math.floor(sec / 60) + ' min ' + (sec % 60) + ' s'; }
    return Math.floor(sec / 3600) + ' h ' + Math.floor((sec % 3600) / 60) + ' min';
  }

  function renderDisks(list) {
    disks.list = list || [];
    var host = $('#diskList');
    host.innerHTML = '';
    disks.list.forEach(function (d) {
      var used = 0, total = 0;
      (d.volumes || []).forEach(function (v) { total += (v.sizeBytes || 0); used += ((v.sizeBytes || 0) - (v.freeBytes || 0)); });
      var pct = total > 0 ? Math.round((used / total) * 100) : 0;

      var card = doc.createElement('div');
      card.className = 'disk-card' + (d.protected ? ' is-protected' : '');
      var badges = '';
      if (d.protected) { badges += '<span class="badge badge-warn">' + esc(t('disks.protected', 'geschützt') + ': ' + (d.protectReason || '')) + '</span> '; }
      if (d.bitlocker === 'On') { badges += '<span class="badge badge-ok">BitLocker</span> '; }
      if (d.deviceKindLabel) { badges += '<span class="badge badge-kind">' + esc(d.deviceKindLabel) + '</span> '; }
      if (d.isRemovable) { badges += '<span class="badge">' + esc(t('disks.removable', 'Wechselmedium')) + '</span> '; }
      badges += '<span class="badge">' + esc(d.busType || '') + '</span> <span class="badge">' + esc(d.mediaType || '') + '</span>';

      var actions = '';
      if (!d.protected) {
        actions = '<button class="btn btn-small btn-danger" data-wipe="' + d.number + '">' +
          esc(t('disks.wipe', 'Löschen …')) + '</button>';
      }

      var volRows = (d.volumes || []).map(function (v) {
        var vact = d.protected || v.isSystem ? '<span class="muted">' + esc(t('disks.systemVolume', 'Systemvolume')) + '</span>'
          : '<button class="btn btn-small" data-format="' + esc(v.driveLetter) + '">' + esc(t('disks.format', 'Formatieren …')) + '</button> ' +
            '<button class="btn btn-small" data-convert="' + esc(v.driveLetter) + '">' + esc(t('disks.convert', 'Dateisystem …')) + '</button>';
        return '<tr><td>' + esc(v.driveLetter || '-') + ':</td><td>' + esc(v.label || '—') + '</td>' +
          '<td>' + esc(v.fileSystem || '—') + '</td><td>' + fmtBytes(v.sizeBytes) + '</td>' +
          '<td class="muted">' + fmtBytes(v.freeBytes) + ' ' + esc(t('disks.free', 'frei')) + '</td>' +
          '<td style="text-align:right">' + vact + '</td></tr>';
      }).join('');

      card.innerHTML =
        '<div class="disk-head"><div>' +
        '<div class="disk-title">' + esc(t('disks.disk', 'Datenträger')) + ' ' + d.number + ' · ' + esc(d.friendlyName || '') + '</div>' +
        '<div class="disk-sub">' + fmtBytes(d.sizeBytes) + ' · ' + esc(d.partitionStyle || '') +
        ' · ' + esc(t('disks.health', 'Zustand')) + ': ' + esc(d.healthStatus || '') +
        (d.serial ? ' · S/N ' + esc(d.serial) : '') + '</div>' +
        '<div style="margin-top:6px">' + badges + '</div></div>' +
        '<div class="disk-actions">' + actions + '</div></div>' +
        '<div class="disk-bar"><span style="width:' + pct + '%"></span></div>' +
        (volRows ? '<table class="vol-table">' + volRows + '</table>'
          : '<div class="muted">' + esc(t('disks.noVolumes', 'Keine Volumes vorhanden.')) + '</div>');
      host.appendChild(card);
    });

    $$('#diskList button[data-wipe]').forEach(function (b) {
      b.addEventListener('click', function () { openDiskOp('wipe', parseInt(b.getAttribute('data-wipe'), 10), null); });
    });
    $$('#diskList button[data-format]').forEach(function (b) {
      b.addEventListener('click', function () { openDiskOp('format', null, b.getAttribute('data-format')); });
    });
    $$('#diskList button[data-convert]').forEach(function (b) {
      b.addEventListener('click', function () { openDiskOp('convert', null, b.getAttribute('data-convert')); });
    });
  }

  function refreshDisks() { return api('/api/disks').then(renderDisks).catch(function () { }); }

  function diskByLetter(letter) {
    for (var i = 0; i < disks.list.length; i++) {
      var vols = disks.list[i].volumes || [];
      for (var j = 0; j < vols.length; j++) { if (vols[j].driveLetter === letter) { return disks.list[i]; } }
    }
    return null;
  }

  function openDiskOp(kind, diskNumber, letter) {
    var d = (kind === 'wipe') ? disks.list.filter(function (x) { return x.number === diskNumber; })[0] : diskByLetter(letter);
    if (!d) { return; }
    disks.op = { kind: kind, disk: d, letter: letter };
    $('#diskOpCard').classList.remove('hidden');
    $('#diskJobBox').classList.add('hidden');
    $('#diskConfirm').value = '';
    $('#diskOpStart').disabled = true;
    $('#diskFormatPanel').classList.toggle('hidden', kind === 'wipe');
    $('#diskWipePanel').classList.toggle('hidden', kind !== 'wipe');
    $('#fmtLossRow').classList.toggle('hidden', kind !== 'convert');
    $('#fmtHint').classList.add('hidden');

    var token = (kind === 'wipe') ? ('DISK' + d.number) : (letter + ':');
    $('#diskConfirm').placeholder = token;
    $('#confirmHint').textContent = t('disks.confirmHint', 'Zum Bestätigen eintippen') + ': ' + token;

    if (kind === 'wipe') {
      $('#diskOpTitle').textContent = t('disks.wipeTitle', 'Datenträger löschen') + ' — ' + d.number + ' · ' +
        (d.deviceKindLabel ? d.deviceKindLabel + ' · ' : '') + (d.friendlyName || '');
      updateEstimate();
      $('#rescueEnabled').checked = false;
      $('#rescueOptions').classList.add('hidden');
      disks.measured = null;
      disks.spaceOk = true;
    } else if (kind === 'format') {
      $('#diskOpTitle').textContent = t('disks.formatTitle', 'Formatieren') + ' — ' + letter + ':';
    } else {
      $('#diskOpTitle').textContent = t('disks.convertTitle', 'Dateisystem wechseln') + ' — ' + letter + ':';
      showConvertHint();
    }
    var card = $('#diskOpCard');
    if (card.scrollIntoView) { card.scrollIntoView({ behavior: 'smooth', block: 'nearest' }); }
  }

  function showConvertHint() {
    if (!disks.op || disks.op.kind !== 'convert') { return; }
    var vol = null;
    (disks.op.disk.volumes || []).forEach(function (v) { if (v.driveLetter === disks.op.letter) { vol = v; } });
    var target = $('#fmtFileSystem').value;
    var box = $('#fmtHint');
    var lossless = (target === 'NTFS' && vol && /^FAT/i.test(vol.fileSystem || ''));
    box.className = 'notice ' + (lossless ? 'notice-ok' : 'notice-warn');
    box.textContent = lossless
      ? t('disks.convertLossless', 'Dieser Wechsel läuft verlustfrei über convert.exe – die Daten bleiben erhalten.')
      : t('disks.convertLossy', 'Dieser Wechsel ist nur durch Neuformatieren möglich. Alle Daten auf dem Volume gehen verloren.');
    box.classList.remove('hidden');
  }

  function loadRescueTargets() {
    if (!disks.op || disks.op.kind !== 'wipe') { return Promise.resolve(); }
    var n = disks.op.disk.number;
    return api('/api/disk/targets?exclude=' + n).then(function (list) {
      var sel = $('#rescueTarget');
      sel.innerHTML = '';
      (list || []).forEach(function (tg) {
        var o = doc.createElement('option');
        o.value = tg.driveLetter;
        o.setAttribute('data-free', tg.freeBytes);
        o.textContent = tg.driveLetter + ': ' + (tg.label || '—') + ' · ' + fmtBytes(tg.freeBytes) + ' ' +
          t('disks.free', 'frei') + ' (' + tg.deviceKind + ')';
        sel.appendChild(o);
      });
      checkRescueSpace();
    }).catch(function () { });
  }

  function loadRescueMeasure() {
    if (!disks.op || disks.op.kind !== 'wipe') { return Promise.resolve(); }
    $('#rescueMeasure').className = 'notice';
    $('#rescueMeasure').textContent = t('rescue.measuring', 'Datenmenge wird ermittelt ...');
    return api('/api/disk/measure?number=' + disks.op.disk.number).then(function (m) {
      disks.measured = m;
      $('#rescueMeasure').className = 'notice';
      $('#rescueMeasure').innerHTML = '<b>' + esc(t('rescue.found', 'Zu sichern')) + ': ' +
        fmtBytes(m.bytes) + '</b> ' + t('rescue.inFiles', 'in') + ' ' +
        Number(m.files).toLocaleString(state.lang === 'de' ? 'de-DE' : 'en-GB') + ' ' +
        t('rescue.files', 'Dateien');
      checkRescueSpace();
    }).catch(function () { });
  }

  function checkRescueSpace() {
    var box = $('#rescueSpace');
    var sel = $('#rescueTarget');
    if (!disks.measured || !sel.selectedOptions || !sel.selectedOptions[0]) { box.classList.add('hidden'); return; }
    var free = Number(sel.selectedOptions[0].getAttribute('data-free') || 0);
    var need = Number(disks.measured.bytes || 0);
    box.classList.remove('hidden');
    if (need > free) {
      box.className = 'notice notice-warn';
      box.textContent = t('rescue.tooSmall', 'Zu wenig Platz am Ziel') + ': ' + fmtBytes(need) + ' ' +
        t('rescue.needed', 'benötigt') + ', ' + fmtBytes(free) + ' ' + t('disks.free', 'frei') + '.';
      disks.spaceOk = false;
    } else {
      box.className = 'notice notice-ok';
      box.textContent = t('rescue.fits', 'Passt') + ': ' + fmtBytes(free - need) + ' ' +
        t('rescue.leftOver', 'bleiben danach frei') + '.';
      disks.spaceOk = true;
    }
    checkConfirm();
  }

  function renderStages(stages, current) {
    var host = $('#stageList');
    if (!stages || !stages.length) { host.innerHTML = ''; return; }
    host.innerHTML = stages.map(function (st) {
      var cls = 'stage';
      if (st.status === 'PASS') { cls += ' is-pass'; }
      else if (st.status === 'FAILED') { cls += ' is-failed'; }
      else if (st.name === current) { cls += ' is-running'; }
      var icon = (st.status === 'PASS') ? '✓' : (st.status === 'FAILED' ? '✕' : '●');
      return '<span class="' + cls + '">' + icon + ' ' + esc(t('stage.' + st.name, st.name)) + '</span>';
    }).join('');
  }

  function updateEstimate() {
    if (!disks.op || disks.op.kind !== 'wipe') { return; }
    var n = disks.op.disk.number;
    var strategy = $('#wipeStrategy').value;
    api('/api/disk/estimate?number=' + n + '&strategy=' + strategy).then(function (e) {
      if (e.error) { return; }
      $('#wipeEstimate').className = 'notice notice-warn';
      $('#wipeEstimate').innerHTML =
        '<b>' + esc(t('disks.estStrategy', 'Verfahren')) + ': ' + esc(e.strategy) + '</b> · ' +
        esc(t('disks.estDuration', 'geschätzte Dauer')) + ': <b>' + esc(e.readable) + '</b>' +
        (e.throughputMBs ? ' (~' + esc(String(e.throughputMBs)) + ' MB/s)' : '') +
        '<br><span class="muted">' + esc(e.note) + '</span>';
    }).catch(function () { });
  }

  function checkConfirm() {
    if (!disks.op) { return; }
    var token = (disks.op.kind === 'wipe') ? ('DISK' + disks.op.disk.number) : (disks.op.letter + ':');
    var tokenOk = ($('#diskConfirm').value.trim().toUpperCase() === token.toUpperCase());
    var rescueOk = true;
    if (disks.op.kind === 'wipe' && $('#rescueEnabled').checked) {
      rescueOk = (disks.spaceOk !== false) && !!$('#rescueTarget').value;
    }
    $('#diskOpStart').disabled = !(tokenOk && rescueOk);
  }

  function startDiskOp() {
    if (!disks.op) { return; }
    var kind = disks.op.kind;
    var payload, url;
    if (kind === 'wipe') {
      url = '/api/disk/wipe';
      payload = {
        diskNumber: disks.op.disk.number,
        strategy: $('#wipeStrategy').value,
        confirmation: 'DISK' + disks.op.disk.number,
        bufferMiB: parseInt($('#wipeBuffer').value, 10),
        queueDepth: parseInt($('#wipeQueue').value, 10)
      };
      if ($('#rescueEnabled').checked) {
        var folder = ($('#rescueFolder').value || 'RepairCenter-Rettung').replace(/^[\\/]+/, '');
        payload.rescueTarget = $('#rescueTarget').value + ':\\' + folder;
        payload.rescueMode = $('#rescueMode').value;
        payload.rescueThreads = parseInt($('#rescueThreads').value, 10);
        payload.rescueUnbuffered = $('#rescueUnbuffered').checked;
      }
    } else {
      url = (kind === 'format') ? '/api/disk/format' : '/api/disk/convert';
      payload = {
        driveLetter: disks.op.letter,
        fileSystem: $('#fmtFileSystem').value,
        label: $('#fmtLabel').value,
        full: $('#fmtFull').checked,
        allocationUnitSize: parseInt($('#fmtAllocation').value, 10) || 0,
        allowDataLoss: $('#fmtAllowLoss').checked
      };
    }
    if (!window.confirm(t('disks.confirmDialog', 'Der Vorgang vernichtet Daten endgültig. Wirklich ausführen?'))) { return; }

    $('#diskOpStart').disabled = true;
    $('#diskJobBox').classList.remove('hidden');
    $('#stageList').innerHTML = '';
    $('#diskJobLog').innerHTML = '';
    disks.logCount = 0;
    $('#diskJobBar').style.width = '0%';
    $('#diskJobStatus').textContent = t('progress.starting', 'Wird gestartet ...');
    starteLeben('datentraeger', t('disks.running', 'Datenträgervorgang läuft'));

    api(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) })
      .then(function (r) {
        if (r.error) { throw new Error(r.error); }
        disks.jobId = r.jobId;
        if (disks.timer) { clearInterval(disks.timer); }
        disks.timer = setInterval(pollDiskJob, 800);
      })
      .catch(function (e) {
        beendeLeben('datentraeger');
        $('#diskJobStatus').textContent = t('progress.error', 'Start fehlgeschlagen') + ': ' + e.message;
        $('#diskOpStart').disabled = false;
      });
  }

  function pollDiskJob() {
    if (!disks.jobId) { return; }
    api('/api/disk/job/' + disks.jobId).then(function (j) {
      if (!j || j.error) { return; }
      renderStages(j.stages, j.stage);
      $('#diskJobBar').style.width = (j.percent || 0) + '%';
      var stageLabel = j.stage ? (t('stage.' + j.stage, j.stage) + ' · ') : '';
      var status = (j.status === 'done')
        ? (j.ok ? t('disks.jobDone', 'Fertig') : t('disks.jobFailed', 'Fehlgeschlagen'))
        : stageLabel + (j.percent || 0) + ' % · ' + fmtBytes(j.bytesDone) + ' / ' + fmtBytes(j.bytesTotal);
      $('#diskJobStatus').textContent = status;
      $('#diskJobSpeed').textContent = (j.throughput ? j.throughput + ' MB/s' : '') +
        (j.secondsLeft ? ' · ' + t('disks.remaining', 'Rest') + ' ' + fmtSeconds(j.secondsLeft) : '');

      var logs = j.log || [];
      for (var i = disks.logCount; i < logs.length; i++) {
        var div = doc.createElement('div');
        div.className = 'l-' + (logs[i].kind || 'info');
        div.innerHTML = '<span class="t">' + esc(logs[i].t) + '</span>  ' + esc(logs[i].text);
        $('#diskJobLog').appendChild(div);
      }
      disks.logCount = logs.length;
      $('#diskJobLog').scrollTop = $('#diskJobLog').scrollHeight;

      if (j.status === 'done') {
        clearInterval(disks.timer);
        disks.timer = null;
        beendeLeben('datentraeger');
        $('#diskOpStart').disabled = false;
        refreshDisks();
      }
      else {
        aktualisiereLeben('datentraeger', t('disks.running', 'Datenträgervorgang läuft') + ' ' + (j.percent || 0) + ' %');
      }
    }).catch(function () { });
  }

  function cancelDiskJob() {
    if (!disks.jobId) { return; }
    api('/api/disk/job/' + disks.jobId + '/cancel', { method: 'POST' }).then(function () {
      if (disks.timer) { clearInterval(disks.timer); disks.timer = null; }
      $('#diskJobStatus').textContent = t('progress.cancelled', 'Abgebrochen.');
      $('#diskOpStart').disabled = false;
      refreshDisks();
    }).catch(function () { });
  }


  /* --------------------- Analyse und Dateien ------------------- */
  var pruefung = { analysisJob: null, analysisTimer: null, fileJob: null, fileTimer: null, lastScanJob: null, logCount: 0 };

  function fuellAnalysisDisks() {
    var hinweis = $('#analysisHint');
    var sel = $('#analysisDisk');
    hinweis.className = 'notice';
    hinweis.classList.remove('hidden');
    hinweis.innerHTML = '<span class="spinner spinner-inline"></span>' + t('analysis.loading', 'Datenträger werden gelesen …');
    $('#analysisStart').disabled = true;

    return api('/api/disks').then(function (list) {
      var vorher = sel.value;
      sel.innerHTML = '';
      var anzahl = 0;
      (list || []).forEach(function (d) {
        var o = doc.createElement('option');
        o.value = d.number;
        o.textContent = d.number + ' · ' + (d.deviceKindLabel || '') + ' · ' + (d.friendlyName || '') +
          ' (' + fmtBytes(d.sizeBytes) + ')';
        sel.appendChild(o);
        anzahl++;
      });
      if (vorher) { sel.value = vorher; }
      if (anzahl === 0) {
        hinweis.className = 'notice notice-warn';
        hinweis.textContent = t('analysis.noDisks', 'Es wurden keine Datenträger gefunden.');
        $('#analysisStart').disabled = true;
      } else {
        hinweis.classList.add('hidden');
        $('#analysisStart').disabled = false;
      }
    }).catch(function (e) {
      // Vorher wurde der Fehler verschluckt - man sah nur eine leere Liste.
      sel.innerHTML = '';
      hinweis.className = 'notice notice-warn';
      hinweis.innerHTML = '<b>' + esc(t('analysis.diskError', 'Datenträger konnten nicht gelesen werden')) + '</b><br>' +
        esc(e.message) + '<br><button class="btn btn-small" id="analysisRetry">' +
        esc(t('actions.retry', 'Erneut versuchen')) + '</button>';
      var knopf = $('#analysisRetry');
      if (knopf) { knopf.addEventListener('click', fuellAnalysisDisks); }
      $('#analysisStart').disabled = true;
    });
  }

  function smartZeile(bezeichnung, wert, einheit, grenze) {
    if (wert === null || wert === undefined) {
      return '<tr class="kv-row"><td>' + esc(bezeichnung) + '</td><td class="muted">' +
        t('analysis.unknown', 'nicht lesbar') + '</td></tr>';
    }
    var klasse = 'wert-ok';
    if (grenze && wert > grenze.err) { klasse = 'wert-err'; }
    else if (grenze && wert > grenze.warn) { klasse = 'wert-warn'; }
    return '<tr class="kv-row"><td>' + esc(bezeichnung) + '</td><td class="' + klasse + '">' +
      esc(String(wert)) + (einheit ? ' ' + esc(einheit) : '') + '</td></tr>';
  }

  function zeigeAnalyse(a) {
    if (!a) { return; }
    $('#analysisResult').classList.remove('hidden');
    var v = a.verdict || {};
    $('#verdictBox').className = 'verdict verdict-' + (v.level || 0);
    $('#verdictBox').innerHTML = '<h3>' + esc(t('verdict.' + (v.level || 0), v.verdict || '')) + '</h3>' +
      '<div class="empfehlung">' + esc(v.recommendation || '') + '</div>' +
      '<div class="muted" style="margin-top:6px">' + esc(a.friendlyName || '') + ' · ' +
      fmtBytes(a.sizeBytes) + ' · ' + esc(a.deviceKindLabel || '') + '</div>';

    var s = a.smart || {};
    $('#smartTable').querySelector('tbody').innerHTML =
      '<tr class="kv-row"><td>' + t('analysis.source', 'Quelle') + '</td><td>' + esc(s.source || '-') + '</td></tr>' +
      smartZeile(t('smart.pending', 'Wartende Sektoren (197)'), s.pendingSectors, '', { warn: 0, err: 10 }) +
      smartZeile(t('smart.uncorrectable', 'Nicht korrigierbar (198)'), s.uncorrectableSectors, '', { warn: 0, err: 0 }) +
      smartZeile(t('smart.reallocated', 'Ersetzte Sektoren (5)'), s.reallocatedSectors, '', { warn: 0, err: 50 }) +
      smartZeile(t('smart.crc', 'Übertragungsfehler (199)'), s.crcErrors, '', { warn: 0, err: 100 }) +
      smartZeile(t('smart.hours', 'Betriebsstunden (9)'), s.powerOnHours, 'h', null) +
      smartZeile(t('smart.temp', 'Temperatur (194)'), s.temperatureCelsius, '°C', { warn: 50, err: 60 }) +
      smartZeile(t('smart.wear', 'Abnutzung'), s.wearPercent, '%', { warn: 60, err: 80 }) +
      smartZeile(t('smart.readErrors', 'Lesefehler gesamt'), s.readErrorsTotal, '', { warn: 0, err: 10 });

    var sf = a.surface;
    $('#surfaceBox').innerHTML = sf
      ? (esc(String(sf.samples)) + ' ' + t('analysis.probes', 'Proben') + ': ' +
        '<span class="wert-ok">' + sf.ok + ' ' + t('analysis.ok', 'gelesen') + '</span>, ' +
        '<span class="' + (sf.errors > 0 ? 'wert-err' : 'muted') + '">' + sf.errors + ' ' + t('analysis.failed', 'Fehler') + '</span>, ' +
        '<span class="' + (sf.slow > 0 ? 'wert-warn' : 'muted') + '">' + sf.slow + ' ' + t('analysis.slow', 'langsam') + '</span>' +
        ' · ' + t('analysis.avg', 'Mittel') + ' ' + sf.avgMsPerRead + ' ms, ' +
        t('analysis.max', 'längste') + ' ' + sf.maxMsPerRead + ' ms')
      : t('analysis.noSurface', 'Oberflächenprüfung wurde übersprungen.');

    var eb = $('#eventTable').querySelector('tbody');
    eb.innerHTML = '';
    (a.events || []).forEach(function (e) {
      var tr = doc.createElement('tr');
      tr.innerHTML = '<td>' + esc(e.provider + ' / ' + e.id) + '<div class="muted">' + esc(e.text) + '</div></td>' +
        '<td class="wert-warn">' + esc(String(e.count)) + '</td>' +
        '<td class="muted">' + esc(e.lastTime ? new Date(e.lastTime).toLocaleString(state.lang === 'de' ? 'de-DE' : 'en-GB') : '-') + '</td>';
      eb.appendChild(tr);
    });
    if (!(a.events || []).length) {
      eb.innerHTML = '<tr><td colspan="3" class="muted">' + t('analysis.noEvents', 'Keine einschlägigen Ereignisse.') + '</td></tr>';
    }

    var rl = $('#reasonList');
    rl.innerHTML = '';
    (v.reasons || []).forEach(function (g) {
      var d = doc.createElement('div');
      d.className = 'reason reason-' + g.level;
      d.textContent = g.text;
      rl.appendChild(d);
    });
    if (!(v.reasons || []).length) {
      rl.innerHTML = '<div class="reason">' + t('analysis.noFindings', 'Keine Auffälligkeiten gefunden.') + '</div>';
    }
  }

  function starteAnalyse() {
    var gewaehlt = $('#analysisDisk').value;
    if (gewaehlt === '' || gewaehlt === null) {
      var h = $('#analysisHint');
      h.className = 'notice notice-warn';
      h.classList.remove('hidden');
      h.textContent = t('analysis.pickDisk', 'Bitte zuerst einen Datenträger auswählen.');
      return;
    }
    var payload = {
      diskNumber: parseInt(gewaehlt, 10),
      samples: parseInt($('#analysisSamples').value, 10),
      skipSurface: $('#analysisSkipSurface').checked,
      demo: !!(state.config && state.config.demo)
    };
    $('#analysisStart').disabled = true;
    $('#analysisProgress').classList.remove('hidden');
    $('#analysisBar').style.width = '0%';
    $('#analysisStatus').textContent = t('progress.starting', 'Wird gestartet ...');
    starteLeben('analyse', t('analysis.running', 'Analyse läuft'));

    api('/api/disk/analyze', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload)
    }).then(function (r) {
      pruefung.analysisJob = r.jobId;
      if (pruefung.analysisTimer) { clearInterval(pruefung.analysisTimer); }
      pruefung.analysisTimer = setInterval(frageAnalyseAb, 800);
    }).catch(function (e) {
      beendeLeben('analyse');
      $('#analysisStart').disabled = false;
      $('#analysisStatus').textContent = t('progress.error', 'Start fehlgeschlagen') + ': ' + e.message;
    });
  }

  function frageAnalyseAb() {
    if (!pruefung.analysisJob) { return; }
    api('/api/disk/job/' + pruefung.analysisJob).then(function (j) {
      if (!j || j.error) { return; }
      $('#analysisBar').style.width = (j.percent || 0) + '%';
      $('#analysisStatus').textContent = (j.status === 'done')
        ? t('analysis.done', 'Analyse abgeschlossen.')
        : t('stage.' + (j.stage || ''), j.stage || '') + ' · ' + (j.percent || 0) + ' %';
      if (j.status === 'done') {
        clearInterval(pruefung.analysisTimer);
        pruefung.analysisTimer = null;
        beendeLeben('analyse');
        $('#analysisStart').disabled = false;
        zeigeAnalyse(j.analysis);
      }
      else {
        aktualisiereLeben('analyse', t('analysis.running', 'Analyse läuft') + ' ' + (j.percent || 0) + ' %');
      }
    }).catch(function () { });
  }

  function zeigeDateifunde(sc) {
    var box = $('#filesSummary');
    box.classList.remove('hidden');
    var anzahl = (sc.findings || []).length;
    box.className = 'notice ' + (anzahl > 0 ? 'notice-warn' : 'notice-ok');
    box.textContent = sc.filesTotal + ' ' + t('files.checked', 'Dateien geprüft') + ' · ' +
      anzahl + ' ' + t('files.damaged', 'auffällig') + ' · ' + (sc.durationSec || 0) + ' s';

    var tabelle = $('#filesTable');
    var tb = tabelle.querySelector('tbody');
    tb.innerHTML = '';
    (sc.findings || []).forEach(function (f) {
      var tr = doc.createElement('tr');
      tr.innerHTML = '<td class="datei-pfad">' + esc(f.path) + '</td>' +
        '<td class="st ' + (f.kind === 'unreadable' ? 'st-FAILED' : 'st-WARNING') + '">' +
        esc(t('files.kind.' + f.kind, f.kind)) + '</td>' +
        '<td>' + esc(f.format || '—') + '</td>' +
        '<td class="muted">' + esc(f.reason) + '</td>';
      tb.appendChild(tr);
    });
    tabelle.classList.toggle('hidden', anzahl === 0);
    // Der Knopf bleibt sichtbar und erklaert sich - vorher verschwand er
    // ganz und man suchte vergeblich nach der Reparatur.
    $('#filesRepair').disabled = (anzahl === 0);
    $('#filesRepairHint').textContent = (anzahl === 0)
      ? t('files.repairHint', 'Erst suchen - danach lassen sich die Funde reparieren.')
      : (anzahl + ' ' + t('files.repairReady', 'Fund(e) bereit zur Reparatur.'));
  }

  function starteDateisuche() {
    var payload = {
      path: $('#filesPath').value,
      deep: $('#filesDeep').checked,
      demo: !!(state.config && state.config.demo)
    };
    $('#filesScan').disabled = true;
    $('#filesProgress').classList.remove('hidden');
    $('#filesBar').style.width = '0%';
    $('#filesSummary').classList.add('hidden');
    $('#filesTable').classList.add('hidden');
    $('#filesRepair').disabled = true;
    $('#filesStatus').textContent = t('progress.starting', 'Wird gestartet ...');
    starteLeben('dateien', t('files.running', 'Dateiprüfung läuft'));

    api('/api/files/scan', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload)
    }).then(function (r) {
      pruefung.fileJob = r.jobId;
      if (pruefung.fileTimer) { clearInterval(pruefung.fileTimer); }
      pruefung.fileTimer = setInterval(frageDateienAb, 800);
    }).catch(function (e) {
      beendeLeben('dateien');
      $('#filesScan').disabled = false;
      $('#filesStatus').textContent = t('progress.error', 'Start fehlgeschlagen') + ': ' + e.message;
    });
  }

  function frageDateienAb() {
    if (!pruefung.fileJob) { return; }
    api('/api/disk/job/' + pruefung.fileJob).then(function (j) {
      if (!j || j.error) { return; }
      $('#filesBar').style.width = (j.percent || 0) + '%';
      $('#filesStatus').textContent = (j.status === 'done')
        ? (j.detail || t('progress.done', 'Abgeschlossen.'))
        : (j.percent || 0) + ' %';
      if (j.current) { $('#filesCurrent').textContent = j.current; }
      if (j.status !== 'done') {
        aktualisiereLeben('dateien', t('files.running', 'Dateiprüfung läuft') + ' ' + (j.percent || 0) + ' %');
      }
      if (j.status === 'done') {
        clearInterval(pruefung.fileTimer);
        pruefung.fileTimer = null;
        beendeLeben('dateien');
        $('#filesScan').disabled = false;
        $('#filesRepair').disabled = false;
        if (j.scan) { pruefung.lastScanJob = j.jobId; zeigeDateifunde(j.scan); }
        if (j.repair) {
          $('#filesSummary').classList.remove('hidden');
          $('#filesSummary').className = 'notice ' + (j.repair.failed > 0 ? 'notice-warn' : 'notice-ok');
          $('#filesSummary').textContent = j.repair.detail;
        }
      }
    }).catch(function () { });
  }

  function starteDateireparatur() {
    if (!pruefung.lastScanJob) { return; }
    if (!window.confirm(t('files.confirmRepair', 'Gefundene Dateien jetzt reparieren? Beschädigte Fassungen werden daneben gesichert.'))) { return; }
    $('#filesRepair').disabled = true;
    $('#filesProgress').classList.remove('hidden');
    api('/api/files/repair', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        scanJobId: pruefung.lastScanJob,
        repairStrategy: $('#filesStrategy').value,
        demo: !!(state.config && state.config.demo)
      })
    }).then(function (r) {
      pruefung.fileJob = r.jobId;
      if (pruefung.fileTimer) { clearInterval(pruefung.fileTimer); }
      pruefung.fileTimer = setInterval(frageDateienAb, 800);
    }).catch(function (e) {
      $('#filesRepair').disabled = false;
      $('#filesStatus').textContent = t('progress.error', 'Start fehlgeschlagen') + ': ' + e.message;
    });
  }

  function pruefeBereitschaft() {
    var box = $('#readinessBox');
    var namen = {
      os: t('readiness.os', 'Betriebssystem'), admin: t('readiness.admin', 'Administratorrechte'),
      mode: t('readiness.mode', 'Betriebsart'), smart: t('readiness.smart', 'SMART-Werte'),
      counters: t('readiness.counters', 'Zuverlässigkeitszähler'), events: t('readiness.events', 'Ereignisprotokoll'),
      raw: t('readiness.raw', 'Rohzugriff'), shadow: t('readiness.shadow', 'Schattenkopien'),
      tools: t('readiness.tools', 'Bordwerkzeuge')
    };
    var reihenfolge = ['os', 'admin', 'mode', 'smart', 'counters', 'events', 'raw', 'shadow', 'tools'];
    $('#checkReadiness').disabled = true;
    starteLeben('bereitschaft', t('readiness.checking', 'Bereitschaft wird geprüft'));

    // Jede Zeile erscheint sofort als "offen" und wird einzeln ausgefüllt -
    // so sieht man, dass wirklich etwas passiert, statt nur "wird geprüft".
    box.innerHTML = '<div class="schritt-liste">' + reihenfolge.map(function (k) {
      return '<div class="schritt offen" id="schritt-' + k + '">' +
        '<span class="zeichen"><span class="spinner spinner-inline"></span></span>' +
        '<span class="benennung">' + esc(namen[k]) + '</span>' +
        '<span class="erklaerung">' + esc(t('readiness.pending', 'wird geprüft …')) + '</span></div>';
    }).join('') + '</div>';

    var ergebnisse = [];
    var kette = Promise.resolve();
    reihenfolge.forEach(function (k) {
      kette = kette.then(function () {
        aktualisiereLeben('bereitschaft', t('readiness.checking', 'Bereitschaft wird geprüft') + ': ' + namen[k]);
        return api('/api/readiness?step=' + k).then(function (r) {
          ergebnisse.push(r);
          var zeile = $('#schritt-' + k);
          if (!zeile) { return; }
          var klasse = (r.status || 'WARNING').toLowerCase();
          var zeichen = r.status === 'PASS' ? '✓' : (r.status === 'WARNING' ? '!' : '✕');
          zeile.className = 'schritt ' + klasse;
          zeile.innerHTML = '<span class="zeichen">' + zeichen + '</span>' +
            '<span class="benennung">' + esc(r.name || namen[k]) + '</span>' +
            '<span class="erklaerung">' + esc(r.detail || '') + '</span>';
        }).catch(function (e) {
          var zeile = $('#schritt-' + k);
          if (zeile) {
            zeile.className = 'schritt failed';
            zeile.innerHTML = '<span class="zeichen">✕</span><span class="benennung">' + esc(namen[k]) +
              '</span><span class="erklaerung">' + esc(e.message) + '</span>';
          }
        });
      });
    });

    return kette.then(function () {
      beendeLeben('bereitschaft');
      $('#checkReadiness').disabled = false;
      var fehlt = ergebnisse.filter(function (r) { return r.status === 'FAILED'; }).length;
      var kopf = doc.createElement('div');
      kopf.className = 'notice ' + (fehlt === 0 ? 'notice-ok' : 'notice-warn');
      kopf.textContent = fehlt === 0
        ? t('readiness.ready', 'Alles Nötige ist vorhanden.')
        : t('readiness.notReady', 'Einiges fehlt – siehe unten. Die Analyse läuft trotzdem, nur mit weniger Quellen.');
      box.insertBefore(kopf, box.firstChild);
    });
  }

  function pruefeBereitschaftAlt() {
    var box = $('#readinessBox');
    box.innerHTML = '<div class="muted">' + t('readiness.checking', 'Wird geprüft ...') + '</div>';
    return api('/api/readiness').then(function (r) {
      var zeilen = (r.checks || []).map(function (c) {
        var klasse = c.status === 'PASS' ? 'st-PASS' : (c.status === 'WARNING' ? 'st-WARNING' : 'st-FAILED');
        var zeichen = c.status === 'PASS' ? '✓' : (c.status === 'WARNING' ? '!' : '✕');
        return '<tr><td style="width:34%">' + esc(c.name) + '</td>' +
          '<td class="st ' + klasse + '" style="width:8%">' + zeichen + '</td>' +
          '<td class="muted">' + esc(c.detail) + '</td></tr>';
      }).join('');
      var kopf = r.ready
        ? '<div class="notice notice-ok">' + t('readiness.ready', 'Alles Nötige ist vorhanden.') + '</div>'
        : '<div class="notice notice-warn">' + t('readiness.notReady', 'Einiges fehlt – siehe unten. Die Analyse läuft trotzdem, nur mit weniger Quellen.') + '</div>';
      box.innerHTML = kopf + '<table class="table">' + zeilen + '</table>';
    }).catch(function (e) {
      box.innerHTML = '<div class="notice notice-warn">' + esc(e.message) + '</div>';
    });
  }

  function spieleAktualisierungEin() {
    if (!window.confirm(t('update.confirmApply', 'Aktualisierung jetzt einspielen? Der Dienst beendet sich dabei kurz und startet neu. Eine Sicherung der jetzigen Fassung wird angelegt.'))) { return; }
    var box = $('#updateApplyResult');
    box.classList.remove('hidden');
    box.className = 'notice';
    box.textContent = t('update.applying', 'Wird eingespielt ...');
    api('/api/update/apply', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ source: $('#updateSource').value })
    }).then(function (r) {
      box.className = 'notice ' + (r.ok ? 'notice-ok' : 'notice-warn');
      box.textContent = r.reason || '';
      if (r.ok) { warteAufNeustart(); }
    }).catch(function (e) {
      box.className = 'notice notice-warn';
      box.textContent = e.message;
    });
  }

  function warteAufNeustart() {
    var box = $('#updateApplyResult');
    var versuche = 0;
    var uhr = setInterval(function () {
      versuche++;
      fetch('/api/config', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (c) {
        clearInterval(uhr);
        box.className = 'notice notice-ok';
        box.textContent = t('update.restarted', 'Dienst läuft wieder, Fassung') + ' ' + c.version + '. ' +
          t('update.reload', 'Bitte die Seite neu laden.');
      }).catch(function () {
        box.textContent = t('update.waiting', 'Dienst startet neu ...') + ' (' + versuche + ')';
        if (versuche > 60) { clearInterval(uhr); }
      });
    }, 2000);
  }

  /* ------------- Sichern, packen und uebertragen -------------- */
  var packen = { job: null, timer: null };

  function ladePackWerkzeuge() {
    return api('/api/files/tools').then(function (w) {
      var box = $('#packTools');
      var hinweise = [];
      if (!w.sevenZip) { hinweise.push(w.sevenNote); }
      if (!w.rar) { hinweise.push(w.rarNote); }
      // Nicht vorhandene Packer abwählbar machen statt sie scheitern zu lassen
      $$('#packAction option').forEach(function (o) {
        if (o.value === '7z') { o.disabled = !w.sevenZip; }
        if (o.value === 'rar') { o.disabled = !w.rar; }
      });
      if (hinweise.length) {
        box.className = 'notice';
        box.classList.remove('hidden');
        box.innerHTML = hinweise.map(esc).join('<br>');
      } else { box.classList.add('hidden'); }
    }).catch(function () { });
  }

  function packFelderAnpassen() {
    var aktion = $('#packAction').value;
    var packt = (aktion === 'zip' || aktion === '7z' || aktion === 'rar');
    $('#packLevelField').classList.toggle('dim', !packt);
    $('#packLevel').disabled = !packt;
    $('#packThreadField').classList.toggle('dim', packt);
    $('#packThreads').disabled = packt;
    $('#packUnbuffered').disabled = packt;
    $('#packUnbufferedField').classList.toggle('dim', packt);
  }

  function startePacken() {
    var quelle = $('#packSource').value.trim();
    var ziel = $('#packTarget').value.trim();
    var ergebnis = $('#packResult');
    if (!quelle || !ziel) {
      $('#packProgress').classList.remove('hidden');
      ergebnis.className = 'notice notice-warn';
      ergebnis.classList.remove('hidden');
      ergebnis.textContent = t('pack.needBoth', 'Bitte Quellordner und Ziel angeben.');
      return;
    }
    var aktion = $('#packAction').value;
    var packt = (aktion === 'zip' || aktion === '7z' || aktion === 'rar');
    var pfad = packt ? '/api/files/archive' : '/api/files/copy';
    var payload = { path: quelle, target: ziel, demo: !!(state.config && state.config.demo) };
    if (packt) {
      payload.archiveFormat = (aktion === 'zip') ? 'Zip' : (aktion === '7z' ? 'SevenZip' : 'Rar');
      payload.archiveLevel = $('#packLevel').value;
    } else {
      payload.copyMode = (aktion === 'move') ? 'Move' : 'Copy';
      payload.threads = parseInt($('#packThreads').value, 10);
      payload.unbuffered = $('#packUnbuffered').checked;
    }

    $('#packStart').disabled = true;
    $('#packProgress').classList.remove('hidden');
    $('#packBar').style.width = '0%';
    ergebnis.classList.add('hidden');
    $('#packStatus').textContent = t('progress.starting', 'Wird gestartet ...');
    starteLeben('packen', packt ? t('pack.packing', 'Packen läuft') : t('pack.copying', 'Übertragung läuft'));

    api(pfad, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) })
      .then(function (r) {
        if (r.error) { throw new Error(r.error); }
        packen.job = r.jobId;
        if (packen.timer) { clearInterval(packen.timer); }
        packen.timer = setInterval(fragePackenAb, 800);
      })
      .catch(function (e) {
        beendeLeben('packen');
        $('#packStart').disabled = false;
        ergebnis.className = 'notice notice-warn';
        ergebnis.classList.remove('hidden');
        ergebnis.textContent = t('progress.error', 'Start fehlgeschlagen') + ': ' + e.message;
        $('#packStatus').textContent = '';
      });
  }

  function fragePackenAb() {
    if (!packen.job) { return; }
    api('/api/disk/job/' + packen.job).then(function (j) {
      if (!j || j.error) { return; }
      $('#packBar').style.width = (j.percent || 0) + '%';
      $('#packStatus').textContent = (j.status === 'done')
        ? (j.ok ? t('pack.done', 'Fertig') : t('pack.failed', 'Fehlgeschlagen'))
        : (j.percent || 0) + ' % · ' + fmtBytes(j.bytesDone) + ' / ' + fmtBytes(j.bytesTotal);
      $('#packSpeed').textContent = (j.throughput ? j.throughput + ' MB/s' : '') +
        (j.secondsLeft ? ' · ' + t('disks.remaining', 'Rest') + ' ' + fmtSeconds(j.secondsLeft) : '');
      if (j.current) { $('#packCurrent').textContent = j.current; }
      if (j.status !== 'done') {
        aktualisiereLeben('packen', t('pack.working', 'Arbeitet') + ' ' + (j.percent || 0) + ' %');
        return;
      }
      clearInterval(packen.timer);
      packen.timer = null;
      beendeLeben('packen');
      $('#packStart').disabled = false;
      $('#packCurrent').textContent = '';
      var ergebnis = $('#packResult');
      ergebnis.classList.remove('hidden');
      ergebnis.className = 'notice ' + (j.ok ? 'notice-ok' : 'notice-warn');
      ergebnis.textContent = j.detail || '';
    }).catch(function () { });
  }

  function pruefeAktualisierung() {
    var quelle = $('#updateSource').value;
    var box = $('#updateResult');
    box.classList.remove('hidden');
    box.className = 'notice';
    box.textContent = t('update.checking', 'Wird geprüft ...');
    api('/api/update/check' + (quelle ? ('?source=' + encodeURIComponent(quelle)) : '')).then(function (u) {
      box.className = 'notice ' + (u.available ? 'notice-warn' : 'notice-ok');
      box.innerHTML = '<b>' + t('update.current', 'Installiert') + ': ' + esc(u.currentVersion) + '</b>' +
        (u.newestVersion ? ' · ' + t('update.found', 'gefunden') + ': ' + esc(u.newestVersion) : '') +
        '<br><span class="muted">' + esc(u.note) + '</span>' +
        '<br><span class="muted">' + t('update.source', 'Ordner') + ': ' + esc(u.source) + '</span>';
      $('#updateApply').classList.toggle('hidden', !u.available);
    }).catch(function (e) {
      box.className = 'notice notice-warn';
      box.textContent = e.message;
    });
  }

  /* ----------------- Aktualisierung aller Bereiche ------------- */
  function aktualisiereAktuellenBereich() {
    var aktiv = ($$('.tab').filter(function (x) { return x.classList.contains('active'); })[0] || {});
    var name = aktiv.getAttribute ? aktiv.getAttribute('data-tab') : 'run';
    if (name === 'system') { refreshSystem(); }
    else if (name === 'history') { refreshHistory(); }
    else if (name === 'disks') { refreshDisks(); }
    else if (name === 'schedule') { refreshSchedule(); refreshConfig(); }
    else if (name === 'report') { refreshHistory(); }
    else if (name === 'analysis') { fuellAnalysisDisks(); }
    else if (name === 'files') { refreshDisks(); }
    else if (name === 'run') { refreshSystem(); }
  }

  function refreshConfig() {
    return api('/api/config').then(function (c) {
      state.config = c;
      renderConfig();
      zeigeBetriebsart();
    }).catch(function () { });
  }

  function setzeAutoAktualisierung() {
    if (state.autoTimer) { clearInterval(state.autoTimer); state.autoTimer = null; }
    if ($('#autoRefresh').checked) {
      localStorage.setItem('rc.auto', '1');
      state.autoTimer = setInterval(aktualisiereAktuellenBereich, 5000);
    } else {
      localStorage.removeItem('rc.auto');
    }
  }

  /* ------------------------------ Tabs ---------------------------- */
  function switchTab(name) {
    $$('.tab').forEach(function (x) { x.classList.toggle('active', x.getAttribute('data-tab') === name); });
    $$('.tab-panel').forEach(function (x) { x.classList.remove('active'); });
    var panel = $('#tab-' + name);
    if (panel) { panel.classList.add('active'); }
    if (name === 'system') { refreshSystem(); }
    if (name === 'history') { refreshHistory(); }
    if (name === 'schedule') { refreshSchedule(); }
    if (name === 'disks') { refreshDisks(); }
    if (name === 'analysis') { fuellAnalysisDisks(); }
    if (name === 'files') { ladePackWerkzeuge(); }
    if (name === 'report') {
      refreshHistory().then(function () {
        if (state.reportRun) { $('#reportRun').value = state.reportRun; }
        loadReport();
      });
    }
  }

  /* ----------------------------- Events --------------------------- */
  function bind() {
    $$('.lang-btn').forEach(function (b) {
      b.addEventListener('click', function () { loadLanguage(b.getAttribute('data-lang')); });
    });
    $('#themeBtn').addEventListener('click', function () {
      state.theme = (state.theme === 'dark') ? 'light' : 'dark';
      applyTheme();
    });
    $$('.tab').forEach(function (tab) {
      tab.addEventListener('click', function () { switchTab(tab.getAttribute('data-tab')); });
    });
    $$('input[name=optimize]').forEach(function (r) {
      r.addEventListener('change', function () {
        $('#aggressiveWarn').classList.toggle('hidden', !(r.value === 'Aggressive' && r.checked));
      });
    });
    $$('input[name=mode]').forEach(function (r) {
      r.addEventListener('change', function () {
        if (r.checked && r.value === 'Diagnose') {
          document.querySelector('input[name=optimize][value=None]').checked = true;
          $('#aggressiveWarn').classList.add('hidden');
        }
      });
    });
    $('#optDemo').addEventListener('change', function () {
      $('#scenarioField').classList.toggle('dim', !$('#optDemo').checked);
    });
    $('#showToolLines').addEventListener('change', function () {
      $('#console').classList.toggle('hide-tools', !$('#showToolLines').checked);
    });
    $('#startBtn').addEventListener('click', startRun);
    $('#cancelBtn').addEventListener('click', cancelRun);
    $('#refreshSystem').addEventListener('click', refreshSystem);
    $('#refreshHistory').addEventListener('click', refreshHistory);
    $('#openReportTab').addEventListener('click', function () { showReport(state.reportRun); });
    $('#reportRun').addEventListener('change', loadReport);
    $$('.fmt-btn').forEach(function (b) {
      b.addEventListener('click', function () {
        $$('.fmt-btn').forEach(function (x) { x.classList.remove('active'); });
        b.classList.add('active');
        state.reportFmt = b.getAttribute('data-fmt');
        loadReport();
      });
    });
    $('#copyReport').addEventListener('click', function () {
      var txt = $('#reportView').textContent;
      if (navigator.clipboard) { navigator.clipboard.writeText(txt); }
    });
    $('#restartDismiss').addEventListener('click', function () { $('#restartBanner').classList.add('hidden'); });
    $('#restartBtn').addEventListener('click', function () {
      if (!window.confirm(t('confirm.restart', 'Windows in 60 Sekunden neu starten?'))) { return; }
      api('/api/restart', { method: 'POST' }).then(function (r) {
        $('#restartReasons').textContent = r.ok
          ? t('restart.scheduled', 'Neustart in 60 Sekunden. Abbrechen mit: shutdown /a')
          : (t('restart.failed', 'Neustart nicht möglich') + ': ' + (r.reason || ''));
      }).catch(function () { });
    });
    $('#schedCreate').addEventListener('click', function () {
      api('/api/schedule', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          day: $('#schedDay').value, time: $('#schedTime').value,
          mode: $('#schedMode').value, optimize: $('#schedOptimize').value
        })
      }).then(refreshSchedule).catch(function () { });
    });
    $('#refreshDisks').addEventListener('click', refreshDisks);
    $('#globalRefresh').addEventListener('click', aktualisiereAktuellenBereich);
    $('#autoRefresh').addEventListener('change', setzeAutoAktualisierung);
    $('#refreshAnalysis').addEventListener('click', fuellAnalysisDisks);
    $('#refreshFiles').addEventListener('click', aktualisiereAktuellenBereich);
    $('#analysisStart').addEventListener('click', starteAnalyse);
    $('#filesScan').addEventListener('click', starteDateisuche);
    $('#filesRepair').addEventListener('click', starteDateireparatur);
    $('#updateCheck').addEventListener('click', pruefeAktualisierung);
    $('#packStart').addEventListener('click', startePacken);
    $('#packAction').addEventListener('change', packFelderAnpassen);
    $('#updateApply').addEventListener('click', spieleAktualisierungEin);
    $('#checkReadiness').addEventListener('click', pruefeBereitschaft);
    $('#diskOpClose').addEventListener('click', function () { $('#diskOpCard').classList.add('hidden'); disks.op = null; });
    $('#diskConfirm').addEventListener('input', checkConfirm);
    $('#diskOpStart').addEventListener('click', startDiskOp);
    $('#diskJobCancel').addEventListener('click', cancelDiskJob);
    $('#wipeStrategy').addEventListener('change', updateEstimate);
    $('#rescueEnabled').addEventListener('change', function () {
      var on = $('#rescueEnabled').checked;
      $('#rescueOptions').classList.toggle('hidden', !on);
      if (on) { loadRescueTargets(); loadRescueMeasure(); }
      checkConfirm();
    });
    $('#rescueTarget').addEventListener('change', checkRescueSpace);
    $('#fmtFileSystem').addEventListener('change', showConvertHint);
    $('#schedDelete').addEventListener('click', function () {
      api('/api/schedule', { method: 'DELETE' }).then(refreshSchedule).catch(function () { });
    });
  }

  /* ------------------------------ Start --------------------------- */
  applyTheme();
  bind();
  $('#scenarioField').classList.add('dim');

  if (localStorage.getItem('rc.auto') === '1') { $('#autoRefresh').checked = true; }

  loadLanguage(state.lang).then(function () {
    setzeAutoAktualisierung();
    api('/api/config').then(function (c) {
      state.config = c;
      renderConfig();
      zeigeBetriebsart();
      if (c.demo) {
        $('#optDemo').checked = true;
        $('#scenarioField').classList.remove('dim');
      }
    }).catch(function () {
      var b = $('#modeBadge');
      b.className = 'badge badge-err';
      b.textContent = t('mode.offline', 'Dienst antwortet nicht');
    });
    refreshSystem();
    refreshHistory();
    // Datentraegerliste gleich beim Start laden, nicht erst beim Reiterwechsel
    fuellAnalysisDisks();
    ladePackWerkzeuge();
    packFelderAnpassen();
    api('/api/runs').then(function (rows) {
      var running = (rows || []).filter(function (r) { return r.status === 'running'; })[0];
      if (running) {
        state.runId = running.runId;
        $('#startBtn').disabled = true;
        $('#cancelBtn').classList.remove('hidden');
        startPolling();
      }
    }).catch(function () { });
  });

  // fuer Tests zugaenglich machen
  window.RepairCenterUI = {
    t: t, renderRun: renderRun, renderSystem: renderSystem, renderHistory: renderHistory,
    collectPayload: collectPayload, switchTab: switchTab, loadLanguage: loadLanguage,
    renderDisks: renderDisks, openDiskOp: openDiskOp, checkConfirm: checkConfirm,
    zeigeAnalyse: zeigeAnalyse, zeigeDateifunde: zeigeDateifunde, pruefung: pruefung,
    pruefeBereitschaft: pruefeBereitschaft, pruefeAktualisierung: pruefeAktualisierung,
    aktualisiereAktuellenBereich: aktualisiereAktuellenBereich, fuellAnalysisDisks: fuellAnalysisDisks,
    zeigeBetriebsart: zeigeBetriebsart, starteLeben: starteLeben, beendeLeben: beendeLeben, leben: leben,
    startePacken: startePacken, ladePackWerkzeuge: ladePackWerkzeuge, packFelderAnpassen: packFelderAnpassen,
    packen: packen,
    loadRescueTargets: loadRescueTargets, loadRescueMeasure: loadRescueMeasure,
    checkRescueSpace: checkRescueSpace, renderStages: renderStages,
    fmtBytes: fmtBytes, fmtSeconds: fmtSeconds, disks: disks,
    state: state
  };
})();
