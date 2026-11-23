
/* ---- i18n ---- */
const I18N = {
  de: {
    rbTitle:'Radio-Browser durchsuchen',
    rbTargetGroup:'Zielordner',
    rbHelp:'Suche im Radio-Browser und übernehme Sender direkt in "My Stations".',
    rbSearch:'Suchen',
    rbEnterQuery:'Suchbegriff eingeben.',
    rbHits:'Treffer',
    rbNoHits:'Keine Treffer.',
    rbAdd:'Zu My Stations',
    rbAdded:'Hinzugefügt (noch speichern!)',

    refresh:'Aktualisieren', subtitle:'Weboberfläche für YTuner, Stream-Proxy und Diagnose',
    tabStations:'1. Radiosender pflegen', tabAdmin:'2. Administration / Tests',
    sourcesTitle:'YTuner-Quellen / Überbleibsel', sourcesHelp:'Steuert, welche Quellen der AVR im YTuner-Menü sieht. "Überbleibsel" kommen oft aus Radio-Browser/Bookmarks/alten Stations-Dateien oder vTuner-Kategorien.',
    reload:'Neu laden', saveSources:'Quellen speichern',
    stationsTitle:'Senderliste / Ordnerstruktur (stations.ini)', stationsHelp:'Ordner (Gruppen) und Sender für "My Stations" pflegen. Nach dem Speichern ggf. YTuner neu starten.',
    addFolder:'+ Ordner', checkAll:'Alle prüfen', addStation:'+ Sender', save:'Speichern', rawEdit:'Raw stations.ini bearbeiten', saveRaw:'Raw speichern',
    statusTitle:'Status', loading:'Lade...', proxyTitle:'Stream-Proxy Einstellungen', restartProxy:'Proxy neustarten',
    configTitle:'YTuner Konfiguration (read-only Überblick)', testsTitle:'Autotest / Diagnose', runTests:'Tests ausführen',
    legendRed:'nicht bestanden/offen', legendYellow:'läuft', legendGreen:'bestanden',
    noTestsYet:'Noch keine Tests ausgeführt.', matrixPending:'Matrix wird nach Testlauf geladen.',
    logsTitle:'Logs', loadLogs:'Logs laden',
    srcRadiobrowser:'Radio-Browser aktiv (viele Kategorien/Sender)', srcBookmarks:'Bookmarks aktiv', srcMyStations:'My Stations aktiv (stations.ini/yaml)', srcFile:'MyStations-Datei',
    loaded:'Geladen', saving:'Speichere...', saveError:'Fehler',
    noTestsLoaded:'Keine Tests geladen.', testsRunning:'Tests laufen...', testsMapped:'Tests', green:'grün', red:'rot', runFailed:'Testlauf fehlgeschlagen.',
    passed:'bestanden', failed:'fehlgeschlagen', checking:'prüfe...', notChecked:'nicht geprüft', noUrl:'keine URL', groupCheck:'Gruppe prüfen', removeFolder:'Ordner löschen', addSender:'+ Sender', remove:'Entfernen', check:'Prüfen',
    updated:'Aktualisiert', apiOk:'API ok', error:'Fehler', noConfigFiles:'Keine Konfigdateien gefunden.', saveStations:'Speichere stations.ini...', saved:'Gespeichert', rawSaved:'Raw gespeichert',
  },
  en: {
    rbTitle:'Search Radio-Browser',
    rbTargetGroup:'Target folder',
    rbHelp:'Search Radio-Browser and add stations directly to "My Stations".',
    rbSearch:'Search',
    rbEnterQuery:'Enter a search query.',
    rbHits:'hits',
    rbNoHits:'No results.',
    rbAdd:'Add to My Stations',
    rbAdded:'Added (save still required!)',

    refresh:'Refresh', subtitle:'Web interface for YTuner, stream proxy and diagnostics',
    tabStations:'1. Manage radio stations', tabAdmin:'2. Administration / Tests',
    sourcesTitle:'YTuner sources / leftovers', sourcesHelp:'Controls which sources appear in the AVR YTuner menu. “Leftovers” often come from Radio-Browser/Bookmarks/old station files or vTuner categories.',
    reload:'Reload', saveSources:'Save sources',
    stationsTitle:'Station list / folder structure (stations.ini)', stationsHelp:'Manage folders (groups) and stations for "My Stations". After saving, restart YTuner if needed.',
    addFolder:'+ Folder', checkAll:'Check all', addStation:'+ Station', save:'Save', rawEdit:'Edit raw stations.ini', saveRaw:'Save raw',
    statusTitle:'Status', loading:'Loading...', proxyTitle:'Stream proxy settings', restartProxy:'Restart proxy',
    configTitle:'YTuner configuration (read-only overview)', testsTitle:'Autotest / Diagnostics', runTests:'Run tests',
    legendRed:'failed/pending', legendYellow:'running', legendGreen:'passed',
    noTestsYet:'No tests run yet.', matrixPending:'Matrix will load after test run.',
    logsTitle:'Logs', loadLogs:'Load logs',
    srcRadiobrowser:'Radio-Browser enabled (many categories/stations)', srcBookmarks:'Bookmarks enabled', srcMyStations:'My Stations enabled (stations.ini/yaml)', srcFile:'MyStations file',
    loaded:'Loaded', saving:'Saving...', saveError:'Error',
    noTestsLoaded:'No tests loaded.', testsRunning:'Tests running...', testsMapped:'Tests', green:'green', red:'red', runFailed:'Test run failed.',
    passed:'passed', failed:'failed', checking:'checking...', notChecked:'not checked', noUrl:'no URL', groupCheck:'Check group', removeFolder:'Delete folder', addSender:'+ Station', remove:'Remove', check:'Check',
    updated:'Updated', apiOk:'API ok', error:'Error', noConfigFiles:'No config files found.', saveStations:'Saving stations.ini...', saved:'Saved', rawSaved:'Raw saved',
  }
};
let LANG = localStorage.getItem('ytuner-lang') || 'de';
function t(k){ return (I18N[LANG]&&I18N[LANG][k]) || I18N.de[k] || k; }
function applyI18n(){
  document.documentElement.lang = LANG;
  document.querySelectorAll('[data-i18n]').forEach(el=>{ const k=el.dataset.i18n; if(I18N[LANG][k]) el.textContent = I18N[LANG][k]; });
  const toggle = $('#langToggle'); if (toggle) toggle.checked = LANG === 'en';
}
function setLang(lang){ LANG = lang === 'en' ? 'en' : 'de'; localStorage.setItem('ytuner-lang', LANG); applyI18n(); loadSources().catch(()=>{}); renderStationsEditor(); }
async function api(path, opts={}) {
  const res = await fetch(path, {headers:{'Content-Type':'application/json', ...(opts.headers||{})}, ...opts});
  const text = await res.text();
  let data; try { data = JSON.parse(text); } catch { data = {raw:text}; }
  if (!res.ok) throw Object.assign(new Error(data.error || res.statusText), {data, status:res.status});
  return data;
}
const $ = (s)=>document.querySelector(s);
const $$ = (s)=>Array.from(document.querySelectorAll(s));
const esc = (s)=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function badge(ok, text){ const cls = ok===true?'ok':ok===false?'bad':'warn'; return `<span class="badge ${cls}">${esc(text)}</span>`; }

/* ---- Tabs ---- */
$$('.main-tab').forEach(btn=>btn.addEventListener('click', ()=>{
  $$('.main-tab').forEach(b=>b.classList.remove('active'));
  $$('.tab-panel').forEach(p=>p.classList.remove('active'));
  btn.classList.add('active');
  $('#tab-' + btn.dataset.tab).classList.add('active');
}));

/* ---- Radio Browser ---- */
async function searchRadioBrowser(){
  const q = ($('#rbQuery').value||'').trim();
  if (!q) { $('#rbStatus').textContent = t('rbEnterQuery'); return; }
  $('#rbStatus').textContent = t('saving').replace('Speichere...','Suche...').replace('Saving...','Searching...');
  $('#rbResults').innerHTML = '';
  try {
    const d = await api('/api/radiobrowser/search?q='+encodeURIComponent(q)+'&limit=20');
    if (!d.ok) throw new Error(d.error||'search failed');
    const res = d.results||[];
    $('#rbStatus').textContent = `${res.length} ${t('rbHits')} (${d.base})`;
    collectStationsFromEditor();
    const groupOpts = stationsModel.map((g,i)=>`<option value="${i}">${esc(g.name||('Group '+(i+1)))}</option>`).join('');
    $('#rbResults').innerHTML = res.map((r,i)=>`<div class="item"><div style="min-width:0"><strong>${esc(r.name||'(no name)')}</strong><div class="muted small">${esc([r.country,r.codec,r.bitrate? r.bitrate+'k':'',r.tags].filter(Boolean).join(' | '))}</div><div class="muted small" style="overflow:hidden;text-overflow:ellipsis">${esc(r.url||'')}</div></div><div class="actions"><select id="rb-group-${i}" title="${esc(t('rbTargetGroup'))}">${groupOpts}</select><button type="button" data-rb-add="${i}">${esc(t('rbAdd'))}</button></div></div>`).join('') || `<div class="muted">${t('rbNoHits')}</div>`;
    $('#rbResults').querySelectorAll('[data-rb-add]').forEach(btn=>btn.addEventListener('click', ()=>{
      const r = res[+btn.dataset.rbAdd]; if(!r) return;
      collectStationsFromEditor();
      if(!stationsModel.length) stationsModel=[{name:'My Stations',stations:[]}];
      const sel = document.getElementById(`rb-group-${+btn.dataset.rbAdd}`);
      let gi = sel ? parseInt(sel.value,10) : 0;
      if (!(gi>=0 && gi<stationsModel.length)) gi = 0;
      stationsModel[gi].stations.push({name:r.name||'', url:r.url||'', logo:r.favicon||'', _status:null});
      renderStationsEditor();
      $('#stationsSaveResult').textContent = t('rbAdded') + ' → ' + (stationsModel[gi].name||'') + ': ' + (r.name||r.url||'');
    }));
  } catch(e){ $('#rbStatus').textContent = t('error')+': '+e.message; }
}

/* ---- Sources / leftovers ---- */
async function loadSources(){
  const d = await api('/api/config/ytuner-sources');
  const c = d.config || {};
  $('#sourcesForm').innerHTML = `
    <label><input type="checkbox" id="srcRadiobrowser" ${String(c.radiobrowser_enable)==='0'?'':'checked'}> ${esc(t('srcRadiobrowser'))}</label>
    <label><input type="checkbox" id="srcBookmarks" ${String(c.bookmark_enable)==='0'?'':'checked'}> ${esc(t('srcBookmarks'))}</label>
    <label><input type="checkbox" id="srcMyStations" ${String(c.mystations_enable)==='0'?'':'checked'}> ${esc(t('srcMyStations'))}</label>
    <label>${esc(t('srcFile'))} <input id="srcMyStationsFile" value="${esc(c.mystations_file||'stations.ini')}" style="max-width:260px"></label>
  `;
  const files = d.files || [];
  $('#sourcesFiles').innerHTML = files.map(f=>`<div class=\"item\"><div><strong>${esc(f.name)}</strong><div class=\"muted small\">${esc(f.kind)} | ${esc(f.size)} B | ${esc(f.path)}</div></div><div class=\"muted small\">${new Date((f.mtime||0)*1000).toLocaleString()}</div></div>`).join('') || `<div class=\"muted\">${t('noConfigFiles')}</div>`;
  $('#sourcesResult').textContent = `${t('loaded')}: ${d.ytuner_ini}`;
}
async function saveSources(){
  const payload = {
    radiobrowser_enable: $('#srcRadiobrowser').checked ? '1':'0',
    bookmark_enable: $('#srcBookmarks').checked ? '1':'0',
    mystations_enable: $('#srcMyStations').checked ? '1':'0',
    mystations_file: $('#srcMyStationsFile').value.trim() || 'stations.ini',
  };
  $('#sourcesResult').textContent = t('saving');
  try {
    const d = await api('/api/config/ytuner-sources', {method:'POST', body:JSON.stringify(payload)});
    $('#sourcesResult').textContent = JSON.stringify(d, null, 2);
    await loadStatus();
  } catch(e){ $('#sourcesResult').textContent = JSON.stringify(e.data||{error:e.message}, null, 2); }
}

/* ---- Status / Config ---- */
async function loadStatus(){
  const d = await api('/api/status');
  const svc = d.services||[];
  const ports = d.ports||[];
  $('#statusSummary').innerHTML = `${t('updated')}: ${new Date().toLocaleString()} | ${t('apiOk')}`;
  $('#services').innerHTML = svc.map(s=>`<div class="item"><div><strong>${esc(s.name)}</strong><div class="muted small">${esc(JSON.stringify(s.props||{}))}</div></div><div>${badge(s.active==='active', s.active)} ${badge(s.enabled==='enabled'||s.enabled==='static'||s.enabled==='unknown', s.enabled)}</div></div>`).join('');
  $('#ports').innerHTML = ports.map(p=>`<div class="item"><div><strong>Port ${esc(p.port)}</strong></div>${badge(p.open, p.open?'open':'closed')}</div>`).join('');
  renderConfig(d.config||{});
  fillProxyForm((d.config||{}).proxy||{});
}
function renderConfig(cfg){
  const rows=[];
  const add=(k,v)=>rows.push(`<div class="k">${esc(k)}</div><div class="v">${esc(typeof v==='object'?JSON.stringify(v):v)}</div>`);
  add('install_dir', cfg.paths?.install_dir);
  add('ytuner.ini', cfg.paths?.ytuner_ini);
  add('avr.ini', cfg.paths?.avr_ini);
  add('stations.ini', cfg.paths?.stations_ini);
  add('proxy_env', cfg.paths?.proxy_env);
  add('ytuner.web_port', cfg.ytuner?.web_port);
  add('ytuner.dns_port', cfg.ytuner?.dns_port);
  add('ytuner.intercept_dns', cfg.ytuner?.intercept_dns);
  add('ytuner.rb_cache_type', cfg.ytuner?.rb_cache_type);
  add('avr.protocol', cfg.avr?.protocol);
  $('#configView').innerHTML = rows.join('');
}
function fillProxyForm(proxy){
  const f = $('#proxyForm');
  for (const [k,v] of Object.entries(proxy||{})){
    const key = 'STREAM_PROXY_' + k.toUpperCase();
    const el = f.elements.namedItem(key);
    if (el) el.value = v;
  }
}
async function saveProxy(ev){
  ev.preventDefault();
  const fd = new FormData(ev.target);
  const payload = Object.fromEntries(fd.entries());
  $('#proxySaveResult').textContent = 'Speichere...';
  try {
    const d = await api('/api/config/proxy', {method:'POST', body:JSON.stringify(payload)});
    $('#proxySaveResult').textContent = JSON.stringify(d, null, 2);
    await loadStatus();
  } catch(e){ $('#proxySaveResult').textContent = JSON.stringify(e.data||{error:e.message}, null, 2); }
}
async function restartProxy(){
  $('#proxySaveResult').textContent = 'Starte Proxy neu...';
  try {
    const d = await api('/api/service/restart', {method:'POST', body:JSON.stringify({name:'ytuner-stream-proxy'})});
    $('#proxySaveResult').textContent = JSON.stringify(d, null, 2);
    await loadStatus();
  } catch(e){ $('#proxySaveResult').textContent = JSON.stringify(e.data||{error:e.message}, null, 2); }
}

/* ---- Tests ---- */
let MATRIX_SIZE = 0;
let matrixState = [];
function setMatrixSize(n){
  MATRIX_SIZE = Math.max(0, n|0);
  matrixState = Array(MATRIX_SIZE).fill('red');
  renderMatrix();
}
function renderMatrix(){
  const m = $('#testMatrix');
  if (!m) return;
  m.style.gridTemplateColumns = `repeat(${Math.ceil(Math.sqrt(MATRIX_SIZE || 1))}, 22px)`;
  m.innerHTML = matrixState.map((s,i)=>`<button type="button" class="lamp ${s}" data-test-idx="${i}" title="Test ${i+1}: ${s} - klicken zum Springen"></button>`).join('');
  m.querySelectorAll('.lamp[data-test-idx]').forEach(btn=>btn.addEventListener('click', ()=>{
    const idx = +btn.dataset.testIdx;
    const el = document.getElementById(`test-row-${idx}`);
    if (el) { el.scrollIntoView({behavior:'smooth', block:'center'}); el.classList.add('flash'); setTimeout(()=>el.classList.remove('flash'), 1200); }
  }));
  const label = $('#matrixStatus');
  if (label && !matrixState.length) label.textContent = t('noTestsLoaded');
}
function setMatrixAll(state){ if (MATRIX_SIZE) { matrixState = Array(MATRIX_SIZE).fill(state); renderMatrix(); } }
function applyMatrixResults(results){
  const res = results || [];
  if (res.length !== MATRIX_SIZE) setMatrixSize(res.length);
  matrixState = res.map(r => r.ok ? 'green' : 'red');
  renderMatrix();
  $('#matrixStatus').textContent = `${MATRIX_SIZE} ${t('testsMapped')}: ${res.filter(r=>r.ok).length} ${t('green')}, ${res.filter(r=>!r.ok).length} ${t('red')}.`;
}
async function runTests(){
  $('#testSummary').textContent = t('testsRunning');
  $('#testResults').innerHTML = '';
  // optimistic: show all yellow while request is running
  if (MATRIX_SIZE > 0) { setMatrixAll('yellow'); $('#matrixStatus').textContent = `${MATRIX_SIZE} ${t('testsMapped')}...`; }
  else { $('#matrixStatus').textContent = t('testsRunning'); }
  try {
    const d = await api('/api/tests/run', {method:'POST'});
    renderTests(d);
  }
  catch(e){
    if (MATRIX_SIZE > 0) setMatrixAll('red');
    $('#matrixStatus').textContent = MATRIX_SIZE ? `${MATRIX_SIZE} ${t('testsMapped')}: ${t('runFailed')}` : t('runFailed');
    $('#testSummary').textContent = t('error')+': ' + e.message;
  }
}
function renderTests(d){
  $('#testSummary').innerHTML = `${badge(d.ok, d.ok?'PASS':'FAIL')} ${d.passed}/${d.total} ${t('passed')}, ${d.failed} ${t('failed')}`;
  $('#testResults').innerHTML = (d.results||[]).map((r,i)=>`<div class="test" id="test-row-${i}"><div class="head"><span>${i+1}. ${esc(r.name)}</span>${badge(r.ok,r.ok?'ok':'fail')}</div><pre>${esc(JSON.stringify(r.detail, null, 2))}</pre></div>`).join('');
  applyMatrixResults(d.results||[]);
}

/* ---- Stations ---- */
let stationsModel = [];
function normalizeStations(groups){
  if (!Array.isArray(groups) || !groups.length) return [{name:'My Stations', stations:[]}];
  return groups.map(g=>({name: String(g?.name||'Ungrouped'), stations: Array.isArray(g?.stations)?g.stations.map(s=>({name:String(s?.name||''), url:String(s?.url||''), logo:String(s?.logo||''), _status:s._status||null})):[]}));
}
function addGroup(){
  collectStationsFromEditor();
  stationsModel.push({name:'Neuer Ordner', stations:[]});
  renderStationsEditor();
}
function statusHtml(st){
  if (!st || !st.url) return `<span class="station-status warn">${t('noUrl')}</span>`;
  if (!st._status) return `<span class="station-status">${t('notChecked')}</span>`;
  const s = st._status;
  if (s.checking) return `<span class="station-status warn">${t('checking')}</span>`;
  if (s.reachable) return `<span class="station-status ok">OK ${esc(s.status??'')} ${esc(s.content_type||'')} ${esc(s.ms??'')}ms</span>`;
  return `<span class="station-status bad">FAIL ${esc(s.status??'')} ${esc(s.error||'')}</span>`;
}
function renderStationsEditor(){
  const root = $('#stationsEditor');
  root.innerHTML = stationsModel.map((g,gi)=>`
    <div class="station-group" data-gi="${gi}">
      <div class="group-head">
        <input value="${esc(g.name)}" placeholder="Gruppenname" data-field="group-name">
        <button type="button" data-action="add-station">${t("addSender")}</button>
        <button type="button" data-action="check-group">${t("groupCheck")}</button>
        <button type="button" data-action="remove-group">${t("removeFolder")}</button>
      </div>
      ${(g.stations||[]).map((s,si)=>`
        <div class="station-row" data-si="${si}">
          <input value="${esc(s.name)}" placeholder="Sendername" data-field="name">
          <input value="${esc(s.url)}" placeholder="Stream URL (http/https)" data-field="url">
          <input value="${esc(s.logo)}" placeholder="Logo URL (optional)" data-field="logo">
          <button type="button" data-action="check-station">${t("check")}</button>
          <button type="button" data-action="remove-station">${t("remove")}</button>
        </div>
        <div style="margin:-4px 0 10px 0">${statusHtml(s)}</div>`).join('')}
    </div>`).join('');
}
function collectStationsFromEditor(){
  const groups=[];
  document.querySelectorAll('.station-group').forEach(gEl=>{
    const gi = Number(gEl.dataset.gi);
    const old = stationsModel[gi] || {stations:[]};
    const name = gEl.querySelector('[data-field="group-name"]').value.trim() || 'Ungrouped';
    const stations=[];
    gEl.querySelectorAll('.station-row').forEach(rEl=>{
      const si = Number(rEl.dataset.si);
      const prev = (old.stations||[])[si] || {};
      const st={name:rEl.querySelector('[data-field="name"]').value.trim(), url:rEl.querySelector('[data-field="url"]').value.trim(), logo:rEl.querySelector('[data-field="logo"]').value.trim(), _status:prev._status||null};
      // invalidate status if url changed
      if (prev.url !== st.url) st._status = null;
      if (st.name || st.url || st.logo) stations.push(st);
    });
    groups.push({name, stations});
  });
  stationsModel = normalizeStations(groups);
  return stationsModel;
}
async function loadStations(){
  try {
    const d = await api('/api/stations');
    stationsModel = normalizeStations(d.groups||[]);
    $('#stationsRaw').value = d.raw || '';
    renderStationsEditor();
    $('#stationsSaveResult').textContent = `Geladen: ${d.path}`;
  } catch(e){ $('#stationsSaveResult').textContent = t('error')+': '+(e.data?.error||e.message); }
}
async function saveStations(groups){
  $('#stationsSaveResult').textContent = t('saveStations');
  try {
    const d = await api('/api/stations', {method:'POST', body: JSON.stringify(groups ? {groups} : {raw: $('#stationsRaw').value})});
    // preserve status by URL
    const oldStatus = new Map();
    stationsModel.flatMap(g=>g.stations||[]).forEach(s=>{ if(s.url && s._status) oldStatus.set(s.url, s._status); });
    stationsModel = normalizeStations(d.groups||[]).map(g=>({...g, stations:g.stations.map(s=>({...s, _status:oldStatus.get(s.url)||null}))}));
    $('#stationsRaw').value = d.raw || '';
    renderStationsEditor();
    $('#stationsSaveResult').textContent = t('saved')+': '+d.path;
  } catch(e){ $('#stationsSaveResult').textContent = 'Fehler: '+JSON.stringify(e.data||{error:e.message}); }
}
async function checkStation(gi, si){
  collectStationsFromEditor();
  const st = stationsModel?.[gi]?.stations?.[si];
  if (!st || !st.url) return;
  st._status = {checking:true};
  renderStationsEditor();
  try {
    const d = await api('/api/stations/check?url=' + encodeURIComponent(st.url));
    st._status = d;
  } catch(e){ st._status = {reachable:false, error:e.message}; }
  renderStationsEditor();
}
async function checkAllStations(){
  collectStationsFromEditor();
  const jobs=[];
  stationsModel.forEach((g,gi)=> (g.stations||[]).forEach((s,si)=>{ if(s.url) jobs.push([gi,si]); }));
  for (const [gi,si] of jobs) { await checkStation(gi,si); }
}

$('#stationsEditor').addEventListener('click', (ev)=>{
  const btn = ev.target.closest('button[data-action]'); if(!btn) return;
  const gEl = btn.closest('.station-group'); const gi = Number(gEl.dataset.gi);
  collectStationsFromEditor();
  if (btn.dataset.action==='add-station') stationsModel[gi].stations.push({name:'',url:'',logo:'',_status:null});
  if (btn.dataset.action==='remove-group') stationsModel.splice(gi,1);
  if (btn.dataset.action==='remove-station') { const si=Number(btn.closest('.station-row').dataset.si); stationsModel[gi].stations.splice(si,1); }
  if (btn.dataset.action==='check-station') { const si=Number(btn.closest('.station-row').dataset.si); checkStation(gi,si); return; }
  if (btn.dataset.action==='check-group') { (stationsModel[gi].stations||[]).forEach((_,si)=>{}); renderStationsEditor(); (async()=>{ for(let si=0; si<(stationsModel[gi]?.stations||[]).length; si++) await checkStation(gi,si); })(); return; }
  stationsModel = normalizeStations(stationsModel);
  renderStationsEditor();
});
$('#addGroupBtn').addEventListener('click', addGroup);
$('#addStationBtn').addEventListener('click', ()=>{ collectStationsFromEditor(); if(!stationsModel.length) stationsModel=[{name:'My Stations',stations:[]}]; stationsModel[0].stations.push({name:'',url:'',logo:'',_status:null}); renderStationsEditor(); });
$('#saveStationsBtn').addEventListener('click', ()=>saveStations(collectStationsFromEditor()));
$('#saveStationsRawBtn').addEventListener('click', ()=>saveStations(null));
$('#reloadStationsBtn').addEventListener('click', loadStations);
$('#checkAllStationsBtn').addEventListener('click', checkAllStations);
$('#reloadSourcesBtn').addEventListener('click', ()=>loadSources().catch(e=>$('#sourcesResult').textContent=e.message));
$('#saveSourcesBtn').addEventListener('click', saveSources);
$('#rbSearchBtn').addEventListener('click', searchRadioBrowser);
$('#rbQuery').addEventListener('keydown', e=>{ if(e.key==='Enter'){ e.preventDefault(); searchRadioBrowser(); } });

/* ---- Logs ---- */
let currentLog='ytuner';
async function loadLogs(name=currentLog){
  currentLog=name;
  $$('.tab[data-log]').forEach(b=>b.classList.toggle('active', b.dataset.log===name));
  $('#logView').textContent = 'Lade...';
  try { const d = await api(`/api/logs?name=${encodeURIComponent(name)}&lines=200`); $('#logView').textContent = d.content || '(leer)'; }
  catch(e){ $('#logView').textContent = 'Fehler: '+e.message; }
}

/* ---- Wire up ---- */
$('#refreshBtn').addEventListener('click', ()=>{ loadStatus().catch(e=>$('#statusSummary').textContent=e.message); loadStations().catch(()=>{}); });
$('#runTestsBtn').addEventListener('click', runTests);
$('#proxyForm').addEventListener('submit', saveProxy);
$('#restartProxyBtn').addEventListener('click', restartProxy);
$('#refreshLogsBtn').addEventListener('click', ()=>loadLogs(currentLog));
$$('.tab[data-log]').forEach(b=>b.addEventListener('click', ()=>loadLogs(b.dataset.log)));

applyI18n();
const lt=$('#langToggle'); if(lt) lt.addEventListener('change', e=>setLang(e.target.checked?'en':'de'));
renderMatrix();
loadStatus().catch(e=>$('#statusSummary').textContent=t('error')+': '+e.message);
loadStations().catch(()=>{});
loadSources().catch(()=>{});
loadLogs('ytuner').catch(()=>{});
