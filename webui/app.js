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
loadLogs('ytuner').catch(()=>{});
