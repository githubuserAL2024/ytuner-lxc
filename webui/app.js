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

/* ---- Sources / leftovers ---- */
async function loadSources(){
  const d = await api('/api/config/ytuner-sources');
  const c = d.config || {};
  $('#sourcesForm').innerHTML = `
    <label><input type="checkbox" id="srcRadiobrowser" ${String(c.radiobrowser_enable)==='0'?'':'checked'}> Radio-Browser aktiv (viele Kategorien/Sender)</label>
    <label><input type="checkbox" id="srcBookmarks" ${String(c.bookmark_enable)==='0'?'':'checked'}> Bookmarks aktiv</label>
    <label><input type="checkbox" id="srcMyStations" ${String(c.mystations_enable)==='0'?'':'checked'}> My Stations aktiv (stations.ini/yaml)</label>
    <label>MyStations-Datei <input id="srcMyStationsFile" value="${esc(c.mystations_file||'stations.ini')}" style="max-width:260px"></label>
  `;
  const files = d.files || [];
  $('#sourcesFiles').innerHTML = files.map(f=>`<div class="item"><div><strong>${esc(f.name)}</strong><div class="muted small">${esc(f.kind)} | ${esc(f.size)} B | ${esc(f.path)}</div></div><div class="muted small">${new Date((f.mtime||0)*1000).toLocaleString()}</div></div>`).join('') || '<div class="muted">Keine Konfigdateien gefunden.</div>';
  $('#sourcesResult').textContent = `Geladen: ${d.ytuner_ini}`;
}
async function saveSources(){
  const payload = {
    radiobrowser_enable: $('#srcRadiobrowser').checked ? '1':'0',
    bookmark_enable: $('#srcBookmarks').checked ? '1':'0',
    mystations_enable: $('#srcMyStations').checked ? '1':'0',
    mystations_file: $('#srcMyStationsFile').value.trim() || 'stations.ini',
  };
  $('#sourcesResult').textContent = 'Speichere...';
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
  $('#statusSummary').innerHTML = `Aktualisiert: ${new Date().toLocaleString()} | API ok`;
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
  if (label && !matrixState.length) label.textContent = 'Keine Tests geladen.';
}
function setMatrixAll(state){ if (MATRIX_SIZE) { matrixState = Array(MATRIX_SIZE).fill(state); renderMatrix(); } }
function applyMatrixResults(results){
  const res = results || [];
  if (res.length !== MATRIX_SIZE) setMatrixSize(res.length);
  matrixState = res.map(r => r.ok ? 'green' : 'red');
  renderMatrix();
  $('#matrixStatus').textContent = `${MATRIX_SIZE} Tests: ${res.filter(r=>r.ok).length} grün, ${res.filter(r=>!r.ok).length} rot.`;
}
async function runTests(){
  $('#testSummary').textContent = 'Tests laufen...';
  $('#testResults').innerHTML = '';
  // optimistic: show all yellow while request is running
  if (MATRIX_SIZE > 0) { setMatrixAll('yellow'); $('#matrixStatus').textContent = `${MATRIX_SIZE} Tests laufen...`; }
  else { $('#matrixStatus').textContent = 'Tests laufen...'; }
  try {
    const d = await api('/api/tests/run', {method:'POST'});
    renderTests(d);
  }
  catch(e){
    if (MATRIX_SIZE > 0) setMatrixAll('red');
    $('#matrixStatus').textContent = MATRIX_SIZE ? `${MATRIX_SIZE} Tests: Lauf fehlgeschlagen.` : 'Testlauf fehlgeschlagen.';
    $('#testSummary').textContent = 'Fehler: ' + e.message;
  }
}
function renderTests(d){
  $('#testSummary').innerHTML = `${badge(d.ok, d.ok?'PASS':'FAIL')} ${d.passed}/${d.total} bestanden, ${d.failed} fehlgeschlagen`;
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
  if (!st || !st.url) return '<span class="station-status warn">keine URL</span>';
  if (!st._status) return '<span class="station-status">nicht geprüft</span>';
  const s = st._status;
  if (s.checking) return '<span class="station-status warn">prüfe...</span>';
  if (s.reachable) return `<span class="station-status ok">OK ${esc(s.status??'')} ${esc(s.content_type||'')} ${esc(s.ms??'')}ms</span>`;
  return `<span class="station-status bad">FAIL ${esc(s.status??'')} ${esc(s.error||'')}</span>`;
}
function renderStationsEditor(){
  const root = $('#stationsEditor');
  root.innerHTML = stationsModel.map((g,gi)=>`
    <div class="station-group" data-gi="${gi}">
      <div class="group-head">
        <input value="${esc(g.name)}" placeholder="Gruppenname" data-field="group-name">
        <button type="button" data-action="add-station">+ Sender</button>
        <button type="button" data-action="check-group">Gruppe prüfen</button>
        <button type="button" data-action="remove-group">Ordner löschen</button>
      </div>
      ${(g.stations||[]).map((s,si)=>`
        <div class="station-row" data-si="${si}">
          <input value="${esc(s.name)}" placeholder="Sendername" data-field="name">
          <input value="${esc(s.url)}" placeholder="Stream URL (http/https)" data-field="url">
          <input value="${esc(s.logo)}" placeholder="Logo URL (optional)" data-field="logo">
          <button type="button" data-action="check-station">Prüfen</button>
          <button type="button" data-action="remove-station">Entfernen</button>
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
  } catch(e){ $('#stationsSaveResult').textContent = 'Fehler: '+(e.data?.error||e.message); }
}
async function saveStations(groups){
  $('#stationsSaveResult').textContent = 'Speichere stations.ini...';
  try {
    const d = await api('/api/stations', {method:'POST', body: JSON.stringify(groups ? {groups} : {raw: $('#stationsRaw').value})});
    // preserve status by URL
    const oldStatus = new Map();
    stationsModel.flatMap(g=>g.stations||[]).forEach(s=>{ if(s.url && s._status) oldStatus.set(s.url, s._status); });
    stationsModel = normalizeStations(d.groups||[]).map(g=>({...g, stations:g.stations.map(s=>({...s, _status:oldStatus.get(s.url)||null}))}));
    $('#stationsRaw').value = d.raw || '';
    renderStationsEditor();
    $('#stationsSaveResult').textContent = 'Gespeichert: '+d.path;
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

renderMatrix();
loadStatus().catch(e=>$('#statusSummary').textContent='Fehler: '+e.message);
loadStations().catch(()=>{});
loadSources().catch(()=>{});
loadLogs('ytuner').catch(()=>{});
