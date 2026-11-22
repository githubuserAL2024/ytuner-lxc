async function api(path, opts={}) {
  const res = await fetch(path, {headers:{'Content-Type':'application/json', ...(opts.headers||{})}, ...opts});
  const text = await res.text();
  let data; try { data = JSON.parse(text); } catch { data = {raw:text}; }
  if (!res.ok) throw Object.assign(new Error(data.error || res.statusText), {data, status:res.status});
  return data;
}
const $ = (s)=>document.querySelector(s);
const esc = (s)=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function badge(ok, text){ const cls = ok===true?'ok':ok===false?'bad':'warn'; return `<span class="badge ${cls}">${esc(text)}</span>`; }

async function loadStatus(){
  const d = await api('/api/status');
  const svc = d.services||[];
  const ports = d.ports||[];
  $('#statusSummary').innerHTML = `Aktualisiert: ${new Date().toLocaleString()} | API ok`;
  $('#services').innerHTML = svc.map(s=>`<div class="item"><div><strong>${esc(s.name)}</strong><div class="muted small">${esc(JSON.stringify(s.props||{}))}</div></div><div>${badge(s.active==='active', s.active)} ${badge(s.enabled==='enabled'||s.enabled==='static', s.enabled)}</div></div>`).join('');
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
async function runTests(){
  $('#testSummary').textContent = 'Tests laufen...';
  $('#testResults').innerHTML = '';
  try {
    const d = await api('/api/tests/run', {method:'POST'});
    renderTests(d);
  } catch(e){ $('#testSummary').textContent = 'Fehler: ' + e.message; }
}
function renderTests(d){
  $('#testSummary').innerHTML = `${badge(d.ok, d.ok?'PASS':'FAIL')} ${d.passed}/${d.total} bestanden, ${d.failed} fehlgeschlagen`;
  $('#testResults').innerHTML = (d.results||[]).map(r=>`<div class="test"><div class="head"><span>${esc(r.name)}</span>${badge(r.ok,r.ok?'ok':'fail')}</div><pre>${esc(JSON.stringify(r.detail, null, 2))}</pre></div>`).join('');
}
let stationsModel = [];
function normalizeStations(groups){
  if (!Array.isArray(groups) || !groups.length) return [{name:'My Stations', stations:[]}];
  return groups.map(g=>({name: String(g?.name||'Ungrouped'), stations: Array.isArray(g?.stations)?g.stations.map(s=>({name:String(s?.name||''), url:String(s?.url||''), logo:String(s?.logo||'')})):[]}));
}
function renderStationsEditor(){
  const root = $('#stationsEditor');
  root.innerHTML = stationsModel.map((g,gi)=>`
    <div class="station-group" data-gi="${gi}">
      <div class="group-head">
        <input value="${esc(g.name)}" placeholder="Gruppenname" data-field="group-name">
        <button type="button" data-action="add-station">+ Sender</button>
        <button type="button" data-action="remove-group">Gruppe löschen</button>
      </div>
      ${(g.stations||[]).map((s,si)=>`
        <div class="station-row" data-si="${si}">
          <input value="${esc(s.name)}" placeholder="Sendername" data-field="name">
          <input value="${esc(s.url)}" placeholder="Stream URL (http/https)" data-field="url">
          <input value="${esc(s.logo)}" placeholder="Logo URL (optional)" data-field="logo">
          <button type="button" data-action="remove-station">Entfernen</button>
        </div>`).join('')}
    </div>`).join('');
}
function collectStationsFromEditor(){
  const groups=[];
  document.querySelectorAll('.station-group').forEach(gEl=>{
    const gi = Number(gEl.dataset.gi);
    const name = gEl.querySelector('[data-field="group-name"]').value.trim() || 'Ungrouped';
    const stations=[];
    gEl.querySelectorAll('.station-row').forEach(rEl=>{
      const st={name:rEl.querySelector('[data-field="name"]').value.trim(), url:rEl.querySelector('[data-field="url"]').value.trim(), logo:rEl.querySelector('[data-field="logo"]').value.trim()};
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
    stationsModel = normalizeStations(d.groups||[]);
    $('#stationsRaw').value = d.raw || '';
    renderStationsEditor();
    $('#stationsSaveResult').textContent = 'Gespeichert: '+d.path;
  } catch(e){ $('#stationsSaveResult').textContent = 'Fehler: '+JSON.stringify(e.data||{error:e.message}); }
}

$('#stationsEditor').addEventListener('click', (ev)=>{
  const btn = ev.target.closest('button[data-action]'); if(!btn) return;
  const gEl = btn.closest('.station-group'); const gi = Number(gEl.dataset.gi);
  collectStationsFromEditor();
  if (btn.dataset.action==='add-station') stationsModel[gi].stations.push({name:'',url:'',logo:''});
  if (btn.dataset.action==='remove-group') stationsModel.splice(gi,1);
  if (btn.dataset.action==='remove-station') { const si=Number(btn.closest('.station-row').dataset.si); stationsModel[gi].stations.splice(si,1); }
  stationsModel = normalizeStations(stationsModel);
  renderStationsEditor();
});
$('#addStationBtn').addEventListener('click', ()=>{ collectStationsFromEditor(); if(!stationsModel.length) stationsModel=[{name:'My Stations',stations:[]}]; stationsModel[0].stations.push({name:'',url:'',logo:''}); renderStationsEditor(); });
$('#saveStationsBtn').addEventListener('click', ()=>saveStations(collectStationsFromEditor()));
$('#saveStationsRawBtn').addEventListener('click', ()=>saveStations(null));
$('#reloadStationsBtn').addEventListener('click', loadStations);

let currentLog='ytuner';
async function loadLogs(name=currentLog){
  currentLog=name;
  document.querySelectorAll('.tab[data-log]').forEach(b=>b.classList.toggle('active', b.dataset.log===name));
  $('#logView').textContent = 'Lade...';
  try { const d = await api(`/api/logs?name=${encodeURIComponent(name)}&lines=200`); $('#logView').textContent = d.content || '(leer)'; }
  catch(e){ $('#logView').textContent = 'Fehler: '+e.message; }
}

$('#refreshBtn').addEventListener('click', ()=>loadStatus().catch(e=>$('#statusSummary').textContent=e.message));
$('#runTestsBtn').addEventListener('click', runTests);
$('#proxyForm').addEventListener('submit', saveProxy);
$('#restartProxyBtn').addEventListener('click', restartProxy);
$('#refreshLogsBtn').addEventListener('click', ()=>loadLogs(currentLog));
document.querySelectorAll('.tab[data-log]').forEach(b=>b.addEventListener('click', ()=>loadLogs(b.dataset.log)));

loadStatus().catch(e=>$('#statusSummary').textContent='Fehler: '+e.message);
loadStations().catch(()=>{});
loadLogs('ytuner').catch(()=>{});
