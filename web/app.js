/* ==========================================================================
   AntiGem — web face
   Talks to scripts/serve.py. No framework, no build step.
   ========================================================================== */
'use strict';

const $  = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

const state = {
  info: null,
  agents: [],
  sessions: [],
  session: null,      // current session id
  agent: 'claude',
  run: null,          // active run id
  tab: 'chat',
  file: { path: null, original: '' },
  treePath: '.',
};

/* ── tiny api client ─────────────────────────────────────────────────── */
async function api(path, opts = {}) {
  const res = await fetch(path, {
    headers: { 'Content-Type': 'application/json' },
    ...opts,
  });
  let data = {};
  try { data = await res.json(); } catch { /* empty body */ }
  if (!res.ok) throw new Error(data.error || `${res.status} ${res.statusText}`);
  return data;
}

/* ── markdown-lite (safe: escape first, then decorate) ────────────────── */
function esc(s) {
  return String(s).replace(/[&<>"']/g, c => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}

function md(src) {
  const blocks = [];
  let s = esc(src).replace(/```([\w+-]*)\n?([\s\S]*?)```/g, (_, lang, code) => {
    blocks.push(`<pre><code>${code.replace(/\n$/, '')}</code></pre>`);
    return `\u0000${blocks.length - 1}\u0000`;
  });

  s = s
    .replace(/`([^`\n]+)`/g, '<code>$1</code>')
    .replace(/^### (.+)$/gm, '<strong>$1</strong>')
    .replace(/^## (.+)$/gm, '<strong>$1</strong>')
    .replace(/^# (.+)$/gm, '<strong>$1</strong>')
    .replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[\s(])\*([^*\n]+)\*/g, '$1<em>$2</em>')
    .replace(/\[([^\]]+)\]\((?!https?:)[^)]*\)/g, '<code>$1</code>')
    .replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g,
      '<a href="$2" target="_blank" rel="noreferrer noopener">$1</a>');

  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => blocks[+i]);
}

/* ── status pill ─────────────────────────────────────────────────────── */
const statusEl = $('#status');
let statusTimer = null;

function setStatus(kind, text) {
  statusEl.className = 'status ' + kind;
  $('span', statusEl).textContent = text;
}

function statusRunning(label) {
  const t0 = Date.now();
  setStatus('live', label);
  clearInterval(statusTimer);
  statusTimer = setInterval(() => {
    const s = Math.round((Date.now() - t0) / 1000);
    setStatus('live', `${label} · ${s}s`);
  }, 1000);
}

function statusDone(label) {
  clearInterval(statusTimer);
  setStatus('done', label);
}

function statusError(msg) {
  clearInterval(statusTimer);
  setStatus('err', msg);
}

/* ── boot ────────────────────────────────────────────────────────────── */
function shortPath(p) {
  const parts = String(p).split('/').filter(Boolean);
  return parts.length <= 2 ? p : '…/' + parts.slice(-2).join('/');
}

async function boot() {
  bindUI();
  try {
    const info = await api('/api/info');
    state.info = info;
    state.agents = info.agents || [];
    state.sessions = info.sessions || [];
    state.agent = info.default_agent || 'claude';

    $('#ws-path').textContent = shortPath(info.workspace);
    $('#ws-path').title = info.workspace;
    $('#brand-sub').textContent = `portable ${info.version}`;
    $('#ver').textContent = `${info.version} · ${info.platform}`;

    renderAgents();
    renderSessions();
    if (!state.agents.some(a => a.id === state.agent && a.status.startsWith('ready'))) {
      const ready = state.agents.find(a => a.status.startsWith('ready'));
      if (ready) state.agent = ready.id;
    }
    $('#agent').value = state.agent;

    if (state.sessions.length) openSession(state.sessions[0].id);
    applyHash();
  } catch (e) {
    statusError('offline');
    console.error(e);
  }
}

function applyHash() {
  const h = decodeURIComponent(location.hash.slice(1));
  if (!h) return;
  const [tab, arg] = h.split(':');
  if (tab === 'files') {
    setTab('files');
    if (arg) setTimeout(() => openFile(arg), 150);
  } else if (tab === 'terminal' || tab === 'chat') {
    setTab(tab);
  }
}

/* ── agents ──────────────────────────────────────────────────────────── */
function renderAgents() {
  const box = $('#agents');
  box.innerHTML = '';
  const sel = $('#agent');
  sel.innerHTML = '';

  for (const a of state.agents) {
    const ready = a.status.startsWith('ready');

    const row = document.createElement('div');
    row.className = 'agent-row' + (a.id === state.agent ? ' on' : '');
    row.innerHTML = `<span class="dot ${ready ? 'ready' : ''}"></span>
                     <span class="lbl">${esc(a.label)}</span>
                     <span class="st">${esc(a.status)}</span>`;
    row.title = a.path || 'not installed';
    row.onclick = () => {
      state.agent = a.id;
      $('#agent').value = a.id;
      renderAgents();
      if (!ready) setStatus('err', `${a.label} not installed`);
    };
    box.appendChild(row);

    const opt = document.createElement('option');
    opt.value = a.id;
    opt.textContent = `${a.label}${ready ? '' : ' — missing'}`;
    opt.disabled = !ready && a.id !== 'shell';
    sel.appendChild(opt);
  }

  sel.value = state.agent;
}

/* ── sessions ────────────────────────────────────────────────────────── */
function renderSessions() {
  const box = $('#sessions');
  box.innerHTML = '';
  if (!state.sessions.length) {
    box.innerHTML = '<div class="session" style="cursor:default;color:#4a5266">no sessions yet</div>';
    return;
  }
  for (const s of state.sessions) {
    const el = document.createElement('div');
    el.className = 'session' + (s.id === state.session ? ' active' : '');
    el.innerHTML = `<span class="dot"></span>
                    <span class="name">${esc(s.title || 'session')}</span>
                    <span class="n">${s.count ?? 0}</span>`;
    el.title = `${s.title}\n${s.agent} · ${s.count} messages`;
    el.onclick = () => openSession(s.id);
    box.appendChild(el);
  }
}

async function refreshSessions() {
  try {
    const d = await api('/api/sessions');
    state.sessions = d.sessions || [];
    renderSessions();
  } catch { /* ignore */ }
}

async function openSession(id) {
  try {
    const s = await api('/api/session/' + id);
    state.session = s.id;
    if (s.agent) {
      state.agent = s.agent;
      $('#agent').value = s.agent;
      renderAgents();
    }
    $('#session-title').textContent = s.title || 'Session';
    document.title = `${s.title || 'AntiGem'} — AntiGem`;
    renderMessages(s.messages || []);
    renderSessions();
    closeNav();
  } catch (e) {
    statusError('cannot open session');
  }
}

function renderMessages(messages) {
  const box = $('#messages');
  box.innerHTML = '';
  if (!messages.length) {
    box.appendChild(emptyState());
    return;
  }
  for (const m of messages) addMessage(m.role, m);
  scrollDown(true);
}

function emptyState() {
  const wrap = document.createElement('div');
  wrap.className = 'empty';
  wrap.id = 'empty-state';
  wrap.innerHTML = `
    <div class="empty-logo">AG</div>
    <h1>AntiGem portable</h1>
    <p>Your agents, in one folder. Pick an engine and start typing.</p>
    <div class="chips">
      <button class="chip" data-prompt="What is in this workspace?">What's in here?</button>
      <button class="chip" data-prompt="List the files and explain what this project does.">Explain the project</button>
      <button class="chip" data-prompt="Run the test suite and summarise the failures.">Run the tests</button>
      <button class="chip" data-prompt="/help">Show agent help</button>
    </div>`;
  $$('.chip', wrap).forEach(c => {
    c.onclick = () => { $('#prompt').value = c.dataset.prompt; sendChat(); };
  });
  return wrap;
}

/* ── messages ────────────────────────────────────────────────────────── */
const AGENT_LABEL = {
  claude: 'Claude Code', codex: 'Codex', agy: 'Antigravity',
  opencode: 'OpenCode', shell: 'Shell', you: 'You',
};

function toolCard(name, input) {
  const card = document.createElement('div');
  card.className = 'tool';

  const isShell = name === 'shell' && input && typeof input === 'object' && input.command;
  const summary = isShell ? input.command : JSON.stringify(input ?? {});
  let body;
  if (isShell) {
    body = '$ ' + input.command;
    if (input.output) body += '\n\n' + input.output;
  } else {
    body = typeof input === 'string' ? input : JSON.stringify(input ?? {}, null, 2);
  }

  let code = '';
  if (isShell && input.exit_code !== null && input.exit_code !== undefined) {
    code = `<span class="code ${input.exit_code === 0 ? 'ok' : 'bad'}">exit ${input.exit_code}</span>`;
  }

  card.innerHTML = `<div class="head">
      <span class="ic">${isShell ? '$' : '&rsaquo;'}</span><span class="name">${esc(name || 'tool')}</span>${code}
      <span class="arg">${esc(String(summary).replace(/\s+/g, ' ').slice(0, 72))}</span>
    </div>
    <pre>${esc(body)}</pre>`;
  $('.head', card).onclick = () => card.classList.toggle('collapsed');
  return card;
}

function addMessage(role, msg) {
  const empty = $('#empty-state');
  if (empty) empty.remove();

  const agent = msg.agent || (role === 'user' ? 'you' : state.agent);
  const label = AGENT_LABEL[agent] || agent;

  const wrap = document.createElement('div');
  wrap.className = 'msg ' + role;
  wrap.innerHTML = `<div class="avatar">${role === 'user' ? 'YOU' : 'AG'}</div>
    <div class="body"><div class="who">${esc(label)}</div><div class="content"></div></div>`;

  const content = $('.content', wrap);

  if (role === 'user') {
    const t = document.createElement('div');
    t.className = 'text';
    t.textContent = msg.content || '';
    content.appendChild(t);
  } else if (Array.isArray(msg.parts) && msg.parts.length) {
    for (const p of msg.parts) {
      if (p.type === 'tool') content.appendChild(toolCard(p.name, p.input));
      else {
        const t = document.createElement('div');
        t.className = 'text';
        t.innerHTML = md(p.text || '');
        content.appendChild(t);
      }
    }
  } else {
    const t = document.createElement('div');
    t.className = 'text';
    t.innerHTML = md(msg.content || '');
    content.appendChild(t);
  }

  $('#messages').appendChild(wrap);
  scrollDown();
  return wrap;
}

function scrollDown(force = false) {
  const box = $('#messages');
  const nearBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 140;
  if (force || nearBottom) box.scrollTop = box.scrollHeight;
}

/* a streaming assistant bubble: text + inline tool cards */
function beginStream(agent) {
  const empty = $('#empty-state');
  if (empty) empty.remove();

  const label = AGENT_LABEL[agent] || agent;
  const wrap = document.createElement('div');
  wrap.className = 'msg assistant';
  wrap.innerHTML = `<div class="avatar">AG</div>
    <div class="body"><div class="who">${esc(label)}</div><div class="content"></div></div>`;
  $('#messages').appendChild(wrap);

  const content = $('.content', wrap);
  let buffer = '';
  let textEl = null;

  const newText = () => {
    textEl = document.createElement('div');
    textEl.className = 'text cursor';
    content.appendChild(textEl);
    buffer = '';
    return textEl;
  };
  newText();

  return {
    push(chunk) {
      chunk = String(chunk);
      if (buffer && !buffer.endsWith('\n') && !chunk.startsWith('\n')) chunk = '\n\n' + chunk;
      buffer += chunk;
      textEl.innerHTML = md(buffer);
      scrollDown();
    },
    tool(name, input) {
      textEl.classList.remove('cursor');
      content.appendChild(toolCard(name, input));
      newText();
      scrollDown();
    },
    end(err) {
      textEl.classList.remove('cursor');
      if (err && !buffer.trim()) {
        textEl.innerHTML = `<span style="color:var(--red)">${esc(err)}</span>`;
      }
      if (!content.textContent.trim()) {
        textEl.innerHTML = '<span style="color:var(--dimmer)">(no output)</span>';
      }
      scrollDown();
    },
    get text() { return content.textContent; },
  };
}

/* ── SSE reader (EventSource, one shot) ──────────────────────────────── */
function streamRun(runId, onEvent) {
  return new Promise((resolve, reject) => {
    const es = new EventSource('/api/stream/' + runId);
    const finish = (fn, arg) => { es.close(); fn(arg); };

    ['message', 'tool', 'done'].forEach(kind => {
      es.addEventListener(kind, ev => {
        let payload = ev.data;
        try { payload = JSON.parse(ev.data); } catch { /* plain string */ }
        if (kind === 'done') return finish(resolve, payload || {});
        onEvent(kind, payload);
      });
    });

    es.onerror = () => {
      // EventSource retries; if the server already ended the stream this fires once.
      if (es.readyState === EventSource.CLOSED) finish(reject, new Error('stream closed'));
      else if (state.run !== runId) finish(reject, new Error('stream ended'));
    };
  });
}

/* ── chat ────────────────────────────────────────────────────────────── */
async function sendChat() {
  if (state.run) return;

  const input = $('#prompt');
  const prompt = input.value.trim();
  if (!prompt) return;

  input.value = '';
  autosize(input);
  $('#prompt').disabled = true;
  $('#send').classList.add('hidden');
  $('#stop').classList.remove('hidden');

  if (!state.session) {
    try {
      const s = await api('/api/session/new', {
        method: 'POST',
        body: JSON.stringify({ agent: state.agent }),
      });
      state.session = s.id;
      $('#session-title').textContent = s.title || 'New session';
      $('#messages').innerHTML = '';
      await refreshSessions();
    } catch (e) {
      statusError('cannot create session');
      resetComposer();
      return;
    }
  }

  addMessage('user', prompt, 'you');
  const bubble = beginStream(state.agent);
  statusRunning(`${state.agent} working`);

  try {
    const start = await api('/api/chat', {
      method: 'POST',
      body: JSON.stringify({ agent: state.agent, prompt, session: state.session }),
    });
    state.run = start.run;

    await streamRun(start.run, (kind, payload) => {
      if (kind === 'message') bubble.push(String(payload));
      else if (kind === 'tool') bubble.tool(payload.name, payload.input);
    });

    // the session title may have been set from the first prompt
    const s = await api('/api/session/' + state.session).catch(() => null);
    if (s) {
      $('#session-title').textContent = s.title || 'Session';
      document.title = `${s.title} — AntiGem`;
    }
    bubble.end();
    statusDone('done');
    refreshSessions();
  } catch (e) {
    bubble.end('run failed: ' + e.message);
    statusError('error');
  } finally {
    state.run = null;
    resetComposer();
  }
}

function resetComposer() {
  $('#prompt').disabled = false;
  $('#send').classList.remove('hidden');
  $('#stop').classList.add('hidden');
  $('#prompt').focus();
}

async function cancelRun() {
  if (!state.run) return;
  const rid = state.run;
  state.run = null;
  try { await api('/api/cancel', { method: 'POST', body: JSON.stringify({ run: rid }) }); } catch { /* ignore */ }
  statusDone('stopped');
}

/* ── terminal ────────────────────────────────────────────────────────── */
const termOut = () => $('#term-out');

function termWrite(text, cls) {
  const out = termOut();
  const span = document.createElement('span');
  if (cls) span.className = cls;
  span.textContent = text;
  out.appendChild(span);
  out.scrollTop = out.scrollHeight;
}

async function runCommand() {
  if (state.run) return;
  const input = $('#cmd');
  const cmd = input.value.trim();
  if (!cmd) return;
  input.value = '';

  termWrite('$ ' + cmd + '\n', 'cmd');
  $('#run').disabled = true;
  statusRunning('running');

  try {
    const start = await api('/api/term', { method: 'POST', body: JSON.stringify({ cmd }) });
    state.run = start.run;
    await streamRun(start.run, (kind, payload) => {
      if (kind === 'message') termWrite(String(payload));
    });
    termWrite('\n');
    statusDone('done');
  } catch (e) {
    termWrite(`[error] ${e.message}\n`, 'err');
    statusError('error');
  } finally {
    state.run = null;
    $('#run').disabled = false;
    input.focus();
  }
}

/* ── files ───────────────────────────────────────────────────────────── */
async function loadDir(path) {
  try {
    const d = await api('/api/files?path=' + encodeURIComponent(path));
    state.treePath = d.path || '.';
    $('#tree-path').textContent = state.treePath;
    $('#tree-path').title = state.treePath;

    const box = $('#tree-items');
    box.innerHTML = '';
    if (!d.items || !d.items.length) {
      box.innerHTML = '<div class="entry" style="cursor:default">empty folder</div>';
      return;
    }
    for (const it of d.items) {
      const el = document.createElement('div');
      el.className = 'entry' + (it.name === state.file.path ? ' on' : '');
      const size = it.dir ? '' : human(it.size);
      el.innerHTML = `<span class="ic">${it.dir ? '▸' : '·'}</span>
                      <span class="nm">${esc(it.name)}</span>
                      <span class="sz">${size}</span>`;
      el.onclick = () => {
        const next = state.treePath === '.' ? it.name : `${state.treePath}/${it.name}`;
        if (it.dir) loadDir(next);
        else openFile(next);
      };
      box.appendChild(el);
    }
  } catch (e) {
    $('#tree-items').innerHTML = `<div class="entry" style="cursor:default;color:var(--red)">${esc(e.message)}</div>`;
  }
}

function human(n) {
  if (n < 1024) return n + ' B';
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' K';
  return (n / 1024 / 1024).toFixed(1) + ' M';
}

async function openFile(path) {
  try {
    const d = await api('/api/file?path=' + encodeURIComponent(path));
    state.file = { path: d.path, original: d.content };
    $('#file-path').textContent = d.path;
    $('#file-path').title = d.path;
    $('#file-body').value = d.content;
    $('#file-body').readOnly = false;
    $('#dirty').classList.add('hidden');
    $('#save').classList.add('hidden');
    const lines = d.content.split('\n').length;
    $('#file-meta').textContent = `${lines} lines · ${human(d.content.length)}`;
    $$('.entry').forEach(e => {
      const nm = $('.nm', e);
      e.classList.toggle('on', nm && nm.textContent === d.path.split('/').pop());
    });
  } catch (e) {
    $('#file-path').textContent = path;
    $('#file-body').value = `[${e.message}]`;
    $('#file-body').readOnly = true;
    $('#file-meta').textContent = '';
  }
}

async function saveFile() {
  if (!state.file.path) return;
  try {
    await api('/api/save', {
      method: 'POST',
      body: JSON.stringify({ path: state.file.path, content: $('#file-body').value }),
    });
    state.file.original = $('#file-body').value;
    $('#dirty').classList.add('hidden');
    $('#save').classList.add('hidden');
    statusDone('saved');
  } catch (e) {
    statusError('save failed');
  }
}

/* ── tabs ────────────────────────────────────────────────────────────── */
function setTab(tab) {
  state.tab = tab;
  $$('.tab').forEach(t => t.classList.toggle('active', t.dataset.tab === tab));
  $$('.panel').forEach(p => p.classList.toggle('active', p.id === 'panel-' + tab));
  if (tab === 'files' && !$('#tree-items').children.length) loadDir(state.treePath);
  if (tab === 'terminal' && !termOut().children.length) loadTermHistory();
  if (tab === 'chat') $('#prompt').focus();
  if (tab === 'terminal') $('#cmd').focus();
}

async function loadTermHistory() {
  const out = termOut();
  out.innerHTML = '';
  termWrite(`AntiGem portable ${state.info?.version || ''} — ${state.info?.workspace || ''}\n`, 'sys');
  termWrite('commands run in the portable workspace with the portable HOME.\n\n', 'sys');
  try {
    const d = await api('/api/term/history');
    for (const it of d.items || []) {
      termWrite('$ ' + it.cmd + '\n', 'cmd');
      termWrite(it.out || '');
      if (it.code) termWrite(`exit ${it.code}\n`, 'err');
      termWrite('\n');
    }
  } catch { /* first load */ }
}

function closeNav() { document.body.classList.remove('nav-open'); }

/* ── textarea behaviour ──────────────────────────────────────────────── */
function autosize(el) {
  el.style.height = 'auto';
  el.style.height = Math.min(el.scrollHeight, 180) + 'px';
}

/* ── wiring ──────────────────────────────────────────────────────────── */
function bindUI() {
  $$('.tab').forEach(t => t.onclick = () => setTab(t.dataset.tab));

  $('#send').onclick = sendChat;
  $('#stop').onclick = cancelRun;
  $('#run').onclick = runCommand;

  $('#prompt').addEventListener('input', e => autosize(e.target));
  $('#prompt').addEventListener('keydown', e => {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendChat(); }
  });

  $('#cmd').addEventListener('keydown', e => {
    if (e.key === 'Enter') { e.preventDefault(); runCommand(); }
  });

  $('#agent').onchange = e => {
    state.agent = e.target.value;
    renderAgents();
  };

  $('#new-session').onclick = async () => {
    if (state.run) return;
    try {
      const s = await api('/api/session/new', {
        method: 'POST',
        body: JSON.stringify({ agent: state.agent }),
      });
      state.session = s.id;
      $('#session-title').textContent = 'New session';
      $('#messages').innerHTML = '';
      $('#messages').appendChild(emptyState());
      await refreshSessions();
      setTab('chat');
      closeNav();
      $('#prompt').focus();
    } catch (e) { statusError('cannot create session'); }
  };

  $('#clear').onclick = () => {
    if (state.tab === 'terminal') { termOut().innerHTML = ''; return; }
    if (state.tab === 'chat') {
      $('#messages').innerHTML = '';
      $('#messages').appendChild(emptyState());
    }
  };

  $('#open-sidebar').onclick = () => {
    if (window.matchMedia('(max-width: 820px)').matches) document.body.classList.add('nav-open');
    else document.body.classList.remove('nav-collapsed');
  };
  $('#toggle-sidebar').onclick = () => document.body.classList.toggle('nav-collapsed');
  document.addEventListener('click', e => {
    if (document.body.classList.contains('nav-open') &&
        !e.target.closest('#sidebar') && !e.target.closest('#open-sidebar')) closeNav();
  });

  $('#reload-files').onclick = () => loadDir(state.treePath);
  $('#up').onclick = () => {
    if (state.treePath === '.') return;
    const parts = state.treePath.split('/');
    parts.pop();
    loadDir(parts.join('/') || '.');
  };

  $('#file-body').addEventListener('input', () => {
    const changed = $('#file-body').value !== state.file.original;
    $('#dirty').classList.toggle('hidden', !changed);
    $('#save').classList.toggle('hidden', !changed);
  });
  $('#save').onclick = saveFile;
  $('#file-body').addEventListener('keydown', e => {
    if ((e.ctrlKey || e.metaKey) && e.key === 's') { e.preventDefault(); saveFile(); }
  });

  document.addEventListener('keydown', e => {
    if ((e.ctrlKey || e.metaKey) && e.key === 'k') {
      e.preventDefault(); setTab('chat'); $('#prompt').focus();
    }
    if (e.key === 'Escape') closeNav();
  });
}

boot();
