/* ── Tauri IPC ─────────────────────────────────────────────────
   In production (Tauri webview), window.__TAURI__ is injected.
   Calls fall through to the no-op mock when running in a browser
   for design/layout purposes only.
───────────────────────────────────────────────────────────── */
function inTauriApp() {
  return typeof window.__TAURI__ !== 'undefined';
}

async function invoke(cmd, args) {
  if (inTauriApp()) {
    return window.__TAURI__.core.invoke(cmd, args);
  }
  // Browser preview fallback — returns mock data
  console.warn('[mock] invoke:', cmd, args);
  return mockInvoke(cmd, args);
}

async function listenEvent(event, handler) {
  if (inTauriApp()) {
    return window.__TAURI__.event.listen(event, handler);
  }
  return () => {};
}

async function openDirDialog() {
  if (inTauriApp()) {
    return window.__TAURI__.dialog.open({ directory: true });
  }
  return null;
}

async function openFileDialog() {
  if (inTauriApp()) {
    return window.__TAURI__.dialog.open({
      directory: false,
      multiple: false,
      filters: [{ name: 'Certificate bundle', extensions: ['pem', 'crt', 'cer', 'cert'] }],
    });
  }
  return null;
}

async function saveFileDialog(defaultName, content) {
  if (inTauriApp()) {
    const path = await window.__TAURI__.dialog.save({ defaultPath: defaultName });
    if (path) {
      await window.__TAURI__.fs.writeTextFile(path, content);
      return path;
    }
    return null;
  }
  // Browser fallback
  const blob = new Blob([content], { type: 'text/plain' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url; a.download = defaultName; a.click();
  URL.revokeObjectURL(url);
  return defaultName;
}

// ── App state ─────────────────────────────────────────────────

let step = 1;
let bundleType = 'full';
let certSource = 'download';   // 'download' | 'existing'
let mode = 'configure';
let detectedTools = [];
let lastResults = [];
let lastBundlePath = '';
let running = false;
let progressUnlisten = null;

const META = [null,
  { step:'Step 1 of 5', title:'Proxy Integration',   desc:'Choose the SSL inspection platform deployed in your environment.' },
  { step:'Step 2 of 5', title:'Connection Details',  desc:'Enter your Netskope tenant URL and organisation key. A live connection check will be performed before proceeding.' },
  { step:'Step 3 of 5', title:'Certificate Bundle',  desc:'Configure where the bundle will be saved and what it should contain.' },
  { step:'Step 4 of 5', title:'Select Tools',        desc:'Choose which developer tools to configure. Greyed-out tools were not detected on this machine.' },
  { step:'Step 5 of 5', title:'Review & Run',        desc:'Review the configuration summary and run — or roll back an existing configuration.' },
];

// ── Render ────────────────────────────────────────────────────

function render() {
  document.querySelectorAll('.step-content').forEach(el => el.classList.remove('active'));
  document.getElementById('step-' + step).classList.add('active');

  const m = META[step];
  document.getElementById('mh-step').textContent  = m.step;
  document.getElementById('mh-title').textContent = m.title;
  document.getElementById('mh-desc').textContent  = m.desc;

  document.querySelectorAll('#step-list .step-item').forEach(el => {
    const s = +el.dataset.s;
    el.classList.remove('active','completed');
    const badge = el.querySelector('.step-badge');
    if (s < step)        { el.classList.add('completed'); badge.textContent = '✓'; }
    else if (s === step) { el.classList.add('active');    badge.textContent = s;   }
    else                 {                                badge.textContent = s;   }
  });

  document.getElementById('prog').style.width = ((step - 1) / 4 * 100) + '%';
  document.getElementById('btn-back').disabled = step === 1;
  document.getElementById('btn-next').style.display = step === 5 ? 'none' : '';
  document.getElementById('nav-lbl').textContent = `${step} / 5`;

  if (step === 5) updateSummary();
  updateCount();
}

// ── Navigation ────────────────────────────────────────────────

async function nav(d) {
  // Validate before leaving Step 2
  if (step === 2 && d === 1) {
    if (certSource === 'download') {
      const status = document.getElementById('conn-status');
      if (!status.classList.contains('alert-ok')) {
        alert('Please verify the connection before continuing.');
        return;
      }
    } else {
      // Existing bundle: must be present and validated
      const ok = await validateExisting();
      if (!ok) return;
    }
  }

  // Leaving Step 3 going forward: download only in download mode.
  // In existing mode the bundle path is already set from Step 2.
  if (step === 3 && d === 1 && certSource === 'download') {
    const downloaded = await ensureBundle();
    if (!downloaded) return;
  }

  step = Math.max(1, Math.min(5, step + d));
  render();
}

document.querySelectorAll('#step-list .step-item').forEach(el => {
  el.addEventListener('click', () => {
    if (+el.dataset.s <= step) { step = +el.dataset.s; render(); }
  });
});

// ── Step 2: Connection test ───────────────────────────────────

async function testConn() {
  const tenant = document.getElementById('tenant-url').value.trim();
  const orgKey = document.getElementById('org-key').value.trim();

  if (!tenant || !orgKey) {
    showConnStatus('err', '⚠️', 'Tenant URL and org key are required');
    return;
  }

  showConnStatus('chk', '⏳', 'Verifying connection…');

  try {
    const result = await invoke('test_connection', { tenant, orgKey });
    if (result.ok) {
      showConnStatus('ok', '✓', result.message);
    } else {
      showConnStatus('err', '✗', result.message);
    }
  } catch (e) {
    showConnStatus('err', '✗', String(e));
  }
}

function showConnStatus(type, icon, msg) {
  const el = document.getElementById('conn-status');
  el.style.display = 'flex';
  el.className = `alert alert-${type}`;
  document.getElementById('conn-icon').textContent = icon;
  document.getElementById('conn-msg').textContent = msg;
}

// ── Certificate source (download vs existing bundle) ──────────

function setSource(s) {
  certSource = s;
  document.getElementById('src-download').classList.toggle('on', s === 'download');
  document.getElementById('src-existing').classList.toggle('on', s === 'existing');
  document.getElementById('src-download-card').style.display = s === 'download' ? '' : 'none';
  document.getElementById('src-existing-card').style.display = s === 'existing' ? '' : 'none';
  // Keep Step 3 in sync (download location/type vs existing-bundle note)
  document.getElementById('step3-download').style.display = s === 'download' ? '' : 'none';
  document.getElementById('step3-existing').style.display = s === 'existing' ? '' : 'none';
}

async function browseBundle() {
  const selected = await openFileDialog();
  if (!selected) return;
  document.getElementById('existing-bundle-path').value = selected;
  await validateExisting();
}

function showExistingStatus(type, icon, msg) {
  const el = document.getElementById('existing-status');
  el.style.display = 'flex';
  el.className = `alert alert-${type}`;
  document.getElementById('existing-icon').textContent = icon;
  document.getElementById('existing-msg').textContent = msg;
}

// Validates the chosen file and, on success, sets lastBundlePath. Returns bool.
async function validateExisting() {
  const path = document.getElementById('existing-bundle-path').value.trim();
  if (!path) {
    showExistingStatus('err', '⚠️', 'Select a certificate bundle file');
    return false;
  }
  showExistingStatus('chk', '⏳', 'Validating bundle…');
  try {
    const result = await invoke('use_existing_bundle', { path });
    lastBundlePath = result.path;
    document.getElementById('step3-existing-path').textContent = result.path;
    showExistingStatus('ok', '✓', 'Valid certificate bundle');
    return true;
  } catch (e) {
    lastBundlePath = '';
    showExistingStatus('err', '✗', String(e));
    return false;
  }
}

// ── Step 3: Bundle location & download ───────────────────────

function setBundle(t) {
  bundleType = t;
  document.getElementById('tgl-ns').classList.toggle('on', t === 'ns');
  document.getElementById('tgl-full').classList.toggle('on', t === 'full');
}

async function browseDir() {
  const selected = await openDirDialog();
  if (selected) document.getElementById('cert-dir').value = selected;
}

async function ensureBundle() {
  const tenant   = document.getElementById('tenant-url').value.trim();
  const orgKey   = document.getElementById('org-key').value.trim();
  const certDir  = document.getElementById('cert-dir').value.trim();
  const certName = document.getElementById('cert-name').value.trim();
  const redownload = document.getElementById('redownload').checked;

  if (!certDir || !certName) {
    alert('Please set a directory and file name for the bundle.');
    return false;
  }

  // For now always download (backend is idempotent)
  try {
    const result = await invoke('download_bundle', {
      tenant,
      orgKey,
      certDir,
      certName,
      fullBundle: bundleType === 'full',
    });
    lastBundlePath = result.path;
    return true;
  } catch (e) {
    alert('Bundle download failed: ' + e);
    return false;
  }
}

// ── Step 4: Tool list (populated dynamically) ─────────────────

async function loadTools() {
  try {
    detectedTools = await invoke('detect_tools', {});
    renderTools(detectedTools);
  } catch (e) {
    document.getElementById('tools-container').innerHTML =
      `<div style="color:var(--red);padding:16px">Failed to detect tools: ${e}</div>`;
  }
}

// Re-runs detection (e.g. after installing a tool without restarting the
// app) while preserving any tool the user had explicitly unchecked.
async function refreshTools() {
  const btn = document.getElementById('btn-refresh-tools');
  const hadRows = document.querySelectorAll('#step-4 .tool-row').length > 0;
  const previouslyOn = new Set(getSelectedToolIds());
  // Only a tool that was already installed (and thus could have been
  // deselected) counts as an explicit deselection below — a tool that just
  // became installed was never "on" before but should default to checked,
  // same as a first load, not get force-unchecked.
  const previouslyInstalled = new Set(detectedTools.filter(t => t.installed).map(t => t.id));

  btn.disabled = true;
  const original = btn.textContent;
  btn.textContent = '⟳ Refreshing…';
  try {
    await loadTools();
    if (hadRows) {
      // renderTools() defaults every installed tool back to checked —
      // restore explicit deselections from before the refresh.
      document.querySelectorAll('#step-4 .tool-row').forEach(row => {
        const id = row.dataset.id;
        if (!row.classList.contains('disabled') && previouslyInstalled.has(id) && !previouslyOn.has(id)) {
          const cb = row.querySelector('.cb');
          row.classList.remove('on');
          cb.classList.remove('on');
          cb.textContent = '';
        }
      });
      updateCount();
    }
  } finally {
    btn.disabled = false;
    btn.textContent = original;
  }
}

function renderTools(tools) {
  const groups = {};
  for (const t of tools) {
    if (!groups[t.group]) groups[t.group] = [];
    groups[t.group].push(t);
  }

  let html = '';
  for (const [group, groupTools] of Object.entries(groups)) {
    html += `<div class="tool-group">
      <div class="tool-group-label">${group}</div>`;
    for (const t of groupTools) {
      const installed = t.installed;
      const checkedClass = installed ? ' on' : '';
      const cbClass = installed ? ' on' : '';
      const badge = installed
        ? `<span class="badge badge-green"><span class="dot"></span>Installed</span>`
        : `<span class="badge badge-gray">Not installed</span>`;
      const ver = t.version ? `<span class="tool-ver">${t.version}</span>` : '';
      html += `<div class="tool-row${checkedClass}${installed ? '' : ' disabled'}"
                    data-id="${t.id}" onclick="tog(this)">
        <div class="cb${cbClass}">${installed ? '✓' : ''}</div>
        <span class="tool-name">${t.name}</span>
        ${badge}${ver}
      </div>`;
    }
    html += `</div>`;
  }

  document.getElementById('tools-container').innerHTML = html;
  updateCount();
}

function tog(row) {
  if (row.classList.contains('disabled')) return;
  const cb = row.querySelector('.cb');
  const on = row.classList.toggle('on');
  cb.classList.toggle('on', on);
  cb.textContent = on ? '✓' : '';
  updateCount();
}

function selectAll(v) {
  document.querySelectorAll('#step-4 .tool-row:not(.disabled)').forEach(row => {
    const cb = row.querySelector('.cb');
    row.classList.toggle('on', v);
    cb.classList.toggle('on', v);
    cb.textContent = v ? '✓' : '';
  });
  updateCount();
}

function updateCount() {
  const all = document.querySelectorAll('#step-4 .tool-row');
  const chk = document.querySelectorAll('#step-4 .tool-row.on');
  if (!all.length) return;
  document.getElementById('tool-count').textContent = `${chk.length} of ${all.length} selected`;
}

function getSelectedToolIds() {
  return [...document.querySelectorAll('#step-4 .tool-row.on')]
    .map(row => row.dataset.id);
}

// ── Step 5: Summary & mode ────────────────────────────────────

function setMode(m) {
  mode = m;
  document.getElementById('mode-cfg').className = 'mode-card' + (m === 'configure' ? ' mode-on-cfg' : '');
  document.getElementById('mode-rb').className  = 'mode-card' + (m === 'rollback'  ? ' mode-on-rb'  : '');
  const btn = document.getElementById('run-btn');
  btn.className = m === 'configure' ? 'btn btn-success' : 'btn btn-danger';
  btn.innerHTML = m === 'configure' ? '▶&ensp;Run configuration' : '↩&ensp;Run rollback';
}

function updateSummary() {
  const selected = getSelectedToolIds();
  const notInstalled = document.querySelectorAll('#step-4 .tool-row.disabled').length;

  if (certSource === 'existing') {
    const fileName = lastBundlePath.split(/[\\/]/).pop() || '—';
    document.getElementById('sum-tenant').textContent = 'Existing bundle';
    document.getElementById('sum-bundle-name').textContent = fileName;
    document.getElementById('sum-bundle-path').textContent = lastBundlePath || '—';
  } else {
    const tenant = document.getElementById('tenant-url').value.trim() || '—';
    const certName = document.getElementById('cert-name').value.trim() || '—';
    const certDir  = document.getElementById('cert-dir').value.trim()  || '—';
    document.getElementById('sum-tenant').textContent = tenant;
    document.getElementById('sum-bundle-name').textContent = certName;
    document.getElementById('sum-bundle-path').textContent =
      `${certDir} · ${bundleType === 'ns' ? 'Netskope-only' : 'Full bundle'}`;
  }

  document.getElementById('sum-tools').textContent = `${selected.length} tools`;
  document.getElementById('sum-tools-sub').textContent =
    `${notInstalled} not installed — skipped`;

  const isWindows = navigator.userAgentData?.platform?.includes('Win')
    || navigator.platform?.startsWith('Win')
    || navigator.userAgent.includes('Windows');
  document.getElementById('replay-name').textContent =
    isWindows ? 'configured_tools.bat' : 'configured_tools.sh';
}

// ── Step 5: Run ───────────────────────────────────────────────

async function runScript() {
  if (running) return;
  running = true;

  const log = document.getElementById('log-area');
  log.innerHTML = '';
  document.getElementById('run-btn').disabled = true;
  document.getElementById('download-replay-btn').style.display = 'none';

  // Subscribe to streaming progress events
  if (progressUnlisten) progressUnlisten();
  progressUnlisten = await listenEvent('tool-progress', ({ payload }) => {
    const [cls, text] = Array.isArray(payload) ? payload : ['l-dim', String(payload)];
    appendLog(text, cls);
  });

  const selectedIds = getSelectedToolIds();
  const bundlePath  = lastBundlePath || (
    document.getElementById('cert-dir').value.trim() + '\\' +
    document.getElementById('cert-name').value.trim()
  );

  try {
    if (mode === 'configure') {
      lastResults = await invoke('configure_tools', {
        toolIds: selectedIds,
        bundlePath,
      });
    } else {
      lastResults = await invoke('rollback_tools', {
        toolIds: selectedIds,
      });
    }

    if (document.getElementById('replay-chk').checked) {
      document.getElementById('download-replay-btn').style.display = '';
    }
  } catch (e) {
    appendLog('Error: ' + e, 'l-err');
  }

  if (progressUnlisten) { progressUnlisten(); progressUnlisten = null; }

  document.getElementById('run-btn').disabled = false;
  running = false;
}

function appendLog(text, cls = 'l-dim') {
  const log = document.getElementById('log-area');
  const span = document.createElement('span');
  span.className = cls;
  span.textContent = text + '\n';
  log.appendChild(span);
  log.scrollTop = log.scrollHeight;
}

// ── Replay script download ────────────────────────────────────

async function downloadReplay() {
  const tenant    = document.getElementById('tenant-url').value.trim();
  const bundlePath = lastBundlePath;
  const isWindows  = navigator.userAgentData?.platform?.includes('Win')
    || navigator.platform?.startsWith('Win')
    || navigator.userAgent.includes('Windows');
  const platform  = isWindows ? 'windows' : (navigator.platform?.includes('Mac') ? 'mac' : 'linux');
  const defaultName = isWindows ? 'configured_tools.bat' : 'configured_tools.sh';

  try {
    const content = await invoke('generate_replay_script', {
      results: lastResults,
      platform,
      bundlePath,
      tenant,
    });
    await saveFileDialog(defaultName, content);
  } catch (e) {
    alert('Failed to generate replay script: ' + e);
  }
}

// ── Browser mock (for layout preview without Tauri) ───────────

function mockInvoke(cmd, args) {
  const mockTools = [
    { id:'git',      name:'Git',             group:'Developer Tools', installed:true,  version:'git version 2.45.2', path:'/usr/bin/git' },
    { id:'openssl',  name:'OpenSSL',          group:'Developer Tools', installed:true,  version:'OpenSSL 3.3.0', path:'/usr/bin/openssl' },
    { id:'curl',     name:'cURL',             group:'Developer Tools', installed:true,  version:'curl 8.7.1', path:'/usr/bin/curl' },
    { id:'go',       name:'Go',               group:'Developer Tools', installed:false, version:null, path:null },
    { id:'ruby',     name:'Ruby',             group:'Developer Tools', installed:false, version:null, path:null },
    { id:'composer', name:'PHP Composer',     group:'Developer Tools', installed:false, version:null, path:null },
    { id:'cargo',    name:'Cargo (Rust)',      group:'Developer Tools', installed:false, version:null, path:null },
    { id:'npm',      name:'NPM / Node.js',    group:'Package Managers', installed:true,  version:'10.8.0', path:'/usr/bin/npm' },
    { id:'python',   name:'Python / pip',     group:'Package Managers', installed:true,  version:'Python 3.12.4', path:'/usr/bin/python3' },
    { id:'yarn',     name:'Yarn',             group:'Package Managers', installed:false, version:null, path:null },
    { id:'pnpm',     name:'pnpm',             group:'Package Managers', installed:false, version:null, path:null },
    { id:'aws',      name:'AWS CLI',          group:'Cloud CLIs', installed:true,  version:'aws-cli/2.17.0', path:'/usr/local/bin/aws' },
    { id:'gcloud',   name:'Google Cloud CLI', group:'Cloud CLIs', installed:false, version:null, path:null },
    { id:'az',       name:'Azure CLI',        group:'Cloud CLIs', installed:true,  version:'2.62.0', path:'/usr/bin/az' },
    { id:'oci',      name:'Oracle Cloud CLI', group:'Cloud CLIs', installed:false, version:null, path:null },
    { id:'jdk',             name:'Java / JDK (keytool)',       group:'Windows Platform', installed:true,  version:'2 JDKs found', path:'C:\\Program Files\\Java\\jdk-21' },
    { id:'vscode',          name:'VS Code',                    group:'Windows Platform', installed:true,  version:null, path:'C:\\Program Files\\Microsoft VS Code\\Code.exe' },
    { id:'windows_certstore', name:'Windows Certificate Store', group:'Windows Platform', installed:true,  version:null, path:null },
    { id:'docker',          name:'Docker Desktop',             group:'Windows Platform', installed:true,  version:null, path:'C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe' },
  ];

  if (cmd === 'detect_tools') return Promise.resolve(mockTools);
  if (cmd === 'default_bundle_dir') return Promise.resolve('C:\\Users\\user\\netskope');
  if (cmd === 'test_connection') return Promise.resolve({ ok: true, message: 'Tenant reachable (mock)' });
  if (cmd === 'download_bundle') return Promise.resolve({ path: 'C:\\netskope\\netskope-cert-bundle.pem', sidecar_path: null });
  if (cmd === 'use_existing_bundle') return Promise.resolve({ path: args.path, sidecar_path: null });
  if (cmd === 'configure_tools' || cmd === 'rollback_tools') {
    // Simulate streamed output
    const log = document.getElementById('log-area');
    log.innerHTML = '';
    let i = 0;
    const lines = [
      ['l-hdr', '── Starting configuration ────────────────────────'],
      ['l-ok',  '  ✓ Git http.sslCAInfo configured'],
      ['l-ok',  '  ✓ npm cafile configured'],
      ['l-ok',  '  ✓ AWS CLI ca_bundle configured'],
      ['l-ok',  '  ✓ Azure CLI ca_bundle_path configured'],
      ['l-ok',  '  ✓ Imported to Trusted Root (elevated)'],
      ['l-ok',  '  ✓ http.systemCertificates: true set'],
      ['l-ok',  '  ✓ JDK 21.0.3 imported'],
      ['l-ok',  '✓ Done — 7/7 tools configured.'],
    ];
    const iv = setInterval(() => {
      if (i >= lines.length) { clearInterval(iv); return; }
      const [cls, txt] = lines[i++];
      appendLog(txt, cls);
    }, 80);
    return Promise.resolve([]);
  }
  if (cmd === 'generate_replay_script') return Promise.resolve('@echo off\necho Mock replay script\n');
  if (cmd === 'platform_info') return Promise.resolve('macOS (Apple Silicon) [mock]');
  return Promise.resolve(null);
}

// ── Init ──────────────────────────────────────────────────────

window.addEventListener('DOMContentLoaded', async () => {
  // Detect platform info for sidebar footer. navigator.platform is NOT used
  // here — WebKit reports "MacIntel" for every Mac regardless of actual CPU
  // architecture, so Apple Silicon machines showed as Intel. The Rust
  // backend reports the real compiled-for OS/arch instead.
  let platform = navigator.platform;
  try {
    platform = await invoke('platform_info', {});
  } catch (e) {
    console.warn('platform_info failed:', e);
  }
  document.getElementById('sb-footer').textContent = `v0.4.0 · ${platform}`;

  render();

  // Populate default bundle dir (~/netskope)
  try {
    const defaultDir = await invoke('default_bundle_dir', {});
    const input = document.getElementById('cert-dir');
    if (!input.value) input.value = defaultDir;
  } catch (e) {
    console.warn('default_bundle_dir failed:', e);
    document.getElementById('cert-dir').value = 'C:\\netskope';
  }

  await loadTools();
});
