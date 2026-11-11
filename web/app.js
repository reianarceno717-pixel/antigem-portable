/* ==========================================================================
   AntiGem Web — front end
   Same engine as the app (claude / codex / agy / opencode), served by serve.py.
   Phone: drawer + one column. Desktop: permanent rail + centred chat.
   ========================================================================== */
'use strict';

const $  = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

const AGENT_LABEL = {
  claude: 'Claude Code', codex: 'Codex', agy: 'Antigravity',
  opencode: 'OpenCode', shell: 'Shell', you: 'You',
};

const state = {
  info: null,
  agents: [],
  sessions: [],
  session: null,
  agent: 'claude',
  run: null,
  view: 'chat',
  auto: true,
  file: { path: null, original: '' },
  treePath: '.',
  chatTitle: 'New chat',
};

/* ── api ─────────────────────────────────────────────────────────────── */
async function api(path, opts = {}) {
  const res = await fetch(path, { headers: { 'Content-Type': 'application/json' }, ...opts });
  let data = {};
  try { data = await res.json(); } catch { /* empty */ }
  if (!res.ok) throw new Error(data.error || `${res.status} ${res.statusText}`);
  return data;
}

/* ── markdown-lite ───────────────────────────────────────────────────── */
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
    .replace(/^#{1,3} (.+)$/gm, '<strong>$1</strong>')
    .replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[\s(])\*([^*\n]+)\*/g, '$1<em>$2</em>')
    .replace(/\[([^\]]+)\]\((?!https?:)[^)]*\)/g, '<code>$1</code>')
    .replace(/\[([^\]]+)\]\((https?:[^)\s]+)\)/g,
      '<a href="$2" target="_blank" rel="noreferrer noopener">$1</a>');

  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => blocks[+i]);
}

/* ── status ──────────────────────────────────────────────────────────── */
const statusEl = $('#status');
let statusTimer = null;

function showStatus(kind, text) {
  statusEl.className = 'status ' + kind;
  $('span', statusEl).textContent = text;
}

function hideStatus() { statusEl.className = 'status hidden'; }

function statusRunning(text) {
  const t0 = Date.now();
  showStatus('live', text);
  clearInterval(statusTimer);
  statusTimer = setInterval(() => {
    showStatus('live', `${text} · ${Math.round((Date.now() - t0) / 1000)}s`);
  }, 1000);
}

function statusError(text) { clearInterval(statusTimer); showStatus('err', text); }
function statusDone(text) { clearInterval(statusTimer); showStatus('done', text); setTimeout(hideStatus, 4000); }

/* ── boot ────────────────────────────────────────────────────────────── */
async function boot() {
  wire();
  try {
    const info = await api('/api/info');
    state.info = info;
    state.agents = info.agents || [];
    state.sessions = info.sessions || [];
    state.agent = info.default_agent || 'claude';
    if (!ready(state.agent)) {
      const r = state.agents.find(a => ready(a.id));
      if (r) state.agent = r.id;
    }

    $('#ws-path').textContent = shortPath(info.workspace);
    $('#ws-path').title = info.workspace;
    $('#ver').textContent = `v${info.version} · ${info.platform}`;

    renderAgents();
    renderSessions();

    if (hashView() === 'new') {
      showEmpty();
      setTitle('New chat');
    } else {
      const target = hashSession();
      if (target && state.sessions.some(s => s.id === target)) await openSession(target);
      else if (state.sessions.length) await openSession(state.sessions[0].id);
      else showEmpty();
    }
    applyHash();  } catch (e) {
    statusError('server unreachable');
    console.error(e);
  }
}

const ready = id => (state.agents.find(a => a.id === id) || {}).status?.startsWith('ready');

function shortPath(p) {
  const parts = String(p).split('/').filter(Boolean);
  return parts.length <= 2 ? p : '…/' + parts.slice(-2).join('/');
}

/* ── agents ──────────────────────────────────────────────────────────── */
function renderAgents() {
  // drawer list
  const box = $('#agents');
  box.innerHTML = '';
  for (const a of state.agents) {
    const row = document.createElement('button');
    row.className = 'drawer-row';
    row.innerHTML = `<span class="dot ${ready(a.id) ? 'ready' : ''}"></span>
                     <span>${esc(a.label)}</span>
                     <span class="st">${esc(a.status)}</span>`;
    row.title = a.path || 'not installed';
    row.onclick = () => selectAgent(a.id);
    box.appendChild(row);
  }

  // top-bar project chip (the app shows the open project here, not the agent)
  const proj = state.info.workspace.split('/').filter(Boolean).pop() || 'workspace';
  $('#proj-name').textContent = proj;
  $('#proj-chip').title = state.info.workspace;

  // empty-state pills
  renderEmptyPills();
}

function selectAgent(id) {
  state.agent = id;
  renderAgents();
  $('#prompt').placeholder = `Reply to ${AGENT_LABEL[id] || id}…`;
  if (!ready(id)) statusError(`${AGENT_LABEL[id] || id} is not installed`);
}

/* ── empty state ─────────────────────────────────────────────────────── */
function emptyNode() {
  const wrap = document.createElement('div');
  wrap.className = 'empty';
  wrap.id = 'empty';
  const pillIds = ['agy', 'claude', 'opencode', 'codex'].filter(id => state.agents.some(a => a.id === id));
  wrap.innerHTML = `
    <div class="agent-pills">${pillIds.map(id => `
      <button data-agent="${id}" class="${id === state.agent ? 'on' : ''}">
        <span class="dot"></span>${esc(AGENT_LABEL[id] || id)}
      </button>`).join('')}
    </div>
    <h1>How can I help you today?</h1>
    <p>Ask a question, brainstorm ideas, or start coding</p>`;

  $$('.agent-pills button', wrap).forEach(b => {
    b.onclick = () => { selectAgent(b.dataset.agent); renderEmptyPills(); };
  });
  return wrap;
}

function renderEmptyPills() {
  const old = $('#empty');
  if (!old) return;
  const fresh = emptyNode();
  old.replaceWith(fresh);
}

function showEmpty() {
  const box = $('#messages');
  box.innerHTML = '';
  box.appendChild(emptyNode());
}

function hideEmpty() {
  const e = $('#empty');
  if (e) e.remove();
}

/* ── sessions ────────────────────────────────────────────────────────── */
function renderSessions() {
  const box = $('#sessions');
  box.innerHTML = '';
  if (!state.sessions.length) {
    const d = document.createElement('div');
    d.className = 'drawer-item';
    d.style.cursor = 'default';
    d.textContent = 'no chats yet';
    box.appendChild(d);
    return;
  }
  for (const s of state.sessions) {
    const b = document.createElement('button');
    b.className = 'drawer-item' + (s.id === state.session ? ' on' : '');
    b.innerHTML = `<span class="t">${esc(s.title || 'chat')}</span>`;
    b.title = `${s.title}\n${s.agent} · ${s.count} messages`;
    b.onclick = () => openSession(s.id);
    box.appendChild(b);
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
    if (s.agent) selectAgent(s.agent);
    setTitle(s.title || 'Chat');
    renderMessages(s.messages || []);
    renderSessions();
    setView('chat');
    closeDrawer();
  } catch {
    statusError('cannot open chat');
  }
}

function setTitle(t) {
  state.chatTitle = t;
  if (state.view === 'chat') {
    $('#title').textContent = t;
    document.title = `${t} — AntiGem`;
  }
}

function renderMessages(messages) {
  const box = $('#messages');
  box.innerHTML = '';
  if (!messages.length) { showEmpty(); return; }
  for (const m of messages) addMessage(m.role, m);
  scrollDown(true);
}

/* ── rendering ───────────────────────────────────────────────────────── */
function thinkBlock(text, open = true) {
  const el = document.createElement('div');
  el.className = 'think' + (open ? ' open' : '');
  el.innerHTML = `<div class="think-head"><span class="chev">›</span>
      <span class="gl">✳</span><span>Thinking process</span></div>
    <div class="think-body">${esc(text || '')}</div>`;
  $('.think-head', el).onclick = () => el.classList.toggle('open');
  return el;
}

const TOOL_ICON = {
  shell: '⌘', command_execution: '⌘', file_change: '✎', patch: '✎',
};

const TOOL_LABEL = {
  shell: 'Running command…', command_execution: 'Running command…',
  file_change: 'Editing file…', patch: 'Editing file…',
};

function toolBlock(name, input) {
  const isShell = (name === 'shell' || name === 'command_execution') && input && input.command;
  const label = isShell ? 'Running command…' : (TOOL_LABEL[name] || `Using ${name || 'tool'}…`);
  const detail = isShell ? prettyCmd(input.command) : oneLine(JSON.stringify(input ?? {}), 52);
  const exit = isShell && input.exit_code !== null && input.exit_code !== undefined ? input.exit_code : null;

  let body;
  if (isShell) {
    body = '$ ' + input.command + (input.output ? '\n\n' + input.output : '');
  } else {
    body = typeof input === 'string' ? input : JSON.stringify(input ?? {}, null, 2);
  }

  const wrap = document.createElement('div');
  wrap.className = 'tool-wrap';

  const el = document.createElement('div');
  el.className = 'tool';
  el.innerHTML = `<span class="chev">›</span>
    <span class="ic">${TOOL_ICON[name] || '▸'}</span>
    <span class="lbl">${esc(label)}</span>
    <span class="nm">${esc(detail)}</span>${exit === null ? '' : `<span class="tail ${exit === 0 ? 'code-ok' : 'code-bad'}">${exit === 0 ? 'ok' : 'exit ' + exit}</span>`}`;

  const pre = document.createElement('div');
  pre.className = 'tool-body';
  pre.textContent = body;

  el.onclick = () => wrap.classList.toggle('open');
  wrap.append(el, pre);
  return wrap;
}

function oneLine(s, n) {
  const t = String(s).replace(/\s+/g, ' ').trim();
  return t.length > n ? t.slice(0, n) + '…' : t;
}

/** A shell command as one short readable phrase: unwrap `sh -lc "…"`, keep the first line. */
function prettyCmd(cmd) {
  let c = String(cmd).trim();
  const wrapped = c.replace(/^(?:\S*\/)?(?:ba|z)?sh\s+-l?c\s+(["'])?/, '');
  if (wrapped !== c) {
    c = wrapped.replace(/["']$/, '');
  }
  const first = c.split('\n').map(l => l.trim()).find(Boolean) || c;
  return oneLine(first, 52);
}

function bubbleNode(text) {
  const el = document.createElement('div');
  el.className = 'bubble';
  const lines = String(text).split('\n').length;
  el.innerHTML = `<div class="body">${esc(text)}</div>`;
  if (lines > 6) {
    el.classList.add('clamped');
    const btn = document.createElement('button');
    btn.className = 'more';
    btn.innerHTML = `Show more (${lines} lines) <span class="arw">▾</span>`;
    btn.onclick = () => {
      const clamped = el.classList.toggle('clamped');
      btn.innerHTML = clamped
        ? `Show more (${lines} lines) <span class="arw">▾</span>`
        : 'Show less <span class="arw">▴</span>';
    };
    el.appendChild(btn);
  }
  return el;
}

function addMessage(role, msg) {
  hideEmpty();
  const wrap = document.createElement('div');
  wrap.className = 'msg ' + role;

  if (role === 'user') {
    wrap.appendChild(bubbleNode(msg.content || ''));
  } else {
    const answer = document.createElement('div');
    answer.className = 'answer';
    const parts = Array.isArray(msg.parts) && msg.parts.length
      ? msg.parts
      : [{ type: 'text', text: msg.content || '' }];

    parts.forEach((p, i) => {
      if (p.type === 'tool') {
        answer.appendChild(toolBlock(p.name, p.input));
      } else if (p.type === 'think') {
        answer.appendChild(thinkBlock(p.text));
      } else {
        const t = document.createElement('div');
        t.className = 'text';
        t.innerHTML = md(p.text || '');
        if (i === parts.length - 1) t.classList.add('cursor-off');
        answer.appendChild(t);
      }
    });
    wrap.appendChild(answer);
  }

  $('#messages').appendChild(wrap);
  scrollDown();
  return wrap;
}

function scrollDown(force = false) {
  const box = $('#messages');
  const near = box.scrollHeight - box.scrollTop - box.clientHeight < 160;
  if (force || near) box.scrollTop = box.scrollHeight;
}

/* ── streaming bubble ────────────────────────────────────────────────── */
function streamBubble(agent) {
  hideEmpty();
  const wrap = document.createElement('div');
  wrap.className = 'msg assistant';
  const answer = document.createElement('div');
  answer.className = 'answer';
  wrap.appendChild(answer);

  const working = document.createElement('div');
  working.className = 'working';
  working.innerHTML = `<span class="spin">✳</span><span>Accomplishing…</span>`;
  wrap.appendChild(working);

  $('#messages').appendChild(wrap);

  let buffer = '';
  let textEl = null;

  const newText = () => {
    textEl = document.createElement('div');
    textEl.className = 'text cursor';
    answer.appendChild(textEl);
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
    think(text) {
      textEl.classList.remove('cursor');
      const t = thinkBlock(text, false);
      answer.appendChild(t);
      newText();
      scrollDown();
    },
    tool(name, input) {
      textEl.classList.remove('cursor');
      answer.appendChild(toolBlock(name, input));
      newText();
      scrollDown();
    },
    end(err) {
      working.remove();
      textEl.classList.remove('cursor');
      if (err && !buffer.trim()) {
        textEl.innerHTML = `<span style="color:var(--danger)">${esc(err)}</span>`;
      }
      if (!answer.textContent.trim()) {
        textEl.innerHTML = '<span style="color:var(--faint)">(no output)</span>';
      }
      scrollDown();
    },
  };
}

/* ── SSE ─────────────────────────────────────────────────────────────── */
function streamRun(runId, onEvent) {
  return new Promise((resolve, reject) => {
    const es = new EventSource('/api/stream/' + runId);
    const finish = (fn, arg) => { es.close(); fn(arg); };

    ['message', 'tool', 'think', 'done'].forEach(kind => {
      es.addEventListener(kind, ev => {
        let payload = ev.data;
        try { payload = JSON.parse(ev.data); } catch { /* plain */ }
        if (kind === 'done') return finish(resolve, payload || {});
        onEvent(kind, payload);
      });
    });

    es.onerror = () => {
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
  input.disabled = true;
  $('#send').classList.add('hidden');
  $('#stop').classList.remove('hidden');

  if (!state.session) {
    try {
      const s = await api('/api/session/new', {
        method: 'POST', body: JSON.stringify({ agent: state.agent }),
      });
      state.session = s.id;
      setTitle('New chat');
      $('#messages').innerHTML = '';
      await refreshSessions();
    } catch {
      statusError('cannot create chat');
      resetComposer();
      return;
    }
  }

  addMessage('user', { content: prompt });
  const bubble = streamBubble(state.agent);
  statusRunning(`${AGENT_LABEL[state.agent] || state.agent} working`);

  try {
    const start = await api('/api/chat', {
      method: 'POST',
      body: JSON.stringify({
        agent: state.agent, prompt, session: state.session, auto: state.auto,
      }),
    });
    state.run = start.run;

    await streamRun(start.run, (kind, payload) => {
      if (kind === 'message') bubble.push(String(payload));
      else if (kind === 'tool') bubble.tool(payload.name, payload.input);
      else if (kind === 'think') bubble.think(String(payload));
    });

    const s = await api('/api/session/' + state.session).catch(() => null);
    if (s) setTitle(s.title || 'Chat');
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

async function loadTermHistory() {
  const out = termOut();
  out.innerHTML = '';
  termWrite(`AntiGem ${state.info?.version || ''} · ${state.info?.workspace || ''}\n`, 'sys');
  termWrite('commands run in the portable workspace with the portable HOME\n\n', 'sys');
  try {
    const d = await api('/api/term/history');
    for (const it of d.items || []) {
      termWrite('$ ' + it.cmd + '\n', 'cmd');
      termWrite(it.out || '');
      if (it.code) termWrite(`exit ${it.code}\n`, 'err');
      termWrite('\n');
    }
  } catch { /* first run */ }
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
    const box = $('#tree-items');
    box.innerHTML = '';
    if (!d.items || !d.items.length) {
      box.innerHTML = '<div class="entry" style="cursor:default">empty folder</div>';
      return;
    }
    for (const it of d.items) {
      const el = document.createElement('div');
      el.className = 'entry';
      el.innerHTML = `<span class="ic">${it.dir ? '▸' : '·'}</span>
                      <span class="nm">${esc(it.name)}</span>
                      <span class="sz">${it.dir ? '' : human(it.size)}</span>`;
      el.onclick = () => {
        const next = state.treePath === '.' ? it.name : `${state.treePath}/${it.name}`;
        if (it.dir) loadDir(next); else openFile(next);
      };
      box.appendChild(el);
    }
  } catch (e) {
    $('#tree-items').innerHTML = `<div class="entry" style="cursor:default;color:var(--danger)">${esc(e.message)}</div>`;
  }
}

function human(n) {
  if (n < 1024) return n + ' B';
  if (n < 1048576) return (n / 1024).toFixed(1) + ' K';
  return (n / 1048576).toFixed(1) + ' M';
}

async function openFile(path) {
  try {
    const d = await api('/api/file?path=' + encodeURIComponent(path));
    state.file = { path: d.path, original: d.content };
    $('#file-path').textContent = d.path;
    $('#file-body').value = d.content;
    $('#file-body').readOnly = false;
    $('#dirty').classList.add('hidden');
    $('#save').classList.add('hidden');
    const lines = d.content.split('\n').length;
    $('#file-meta').textContent = `${lines} lines · ${human(d.content.length)}`;
    if (matchMedia('(max-width: 1023px)').matches) {
      $('.files-wrap').classList.add('file-open');
    }
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
  } catch { statusError('save failed'); }
}

/* ── views / drawer ──────────────────────────────────────────────────── */
function setView(view) {
  state.view = view;
  $$('.view').forEach(v => v.classList.toggle('active', v.id === 'view-' + view));

  const names = { chat: state.chatTitle || 'New chat', files: 'Files', terminal: 'Terminal' };
  $('#title').textContent = names[view] || 'AntiGem';
  document.title = `${names[view] || 'AntiGem'} — AntiGem`;

  if (view === 'terminal' && !termOut().children.length) loadTermHistory();
  if (view === 'files' && !$('#tree-items').children.length) loadDir(state.treePath);
  if (view === 'chat') $('#prompt').focus();
  if (view === 'terminal') $('#cmd').focus();
}

function openDrawer() { document.body.classList.add('nav-open'); }
function closeDrawer() { document.body.classList.remove('nav-open'); }
function toggleDrawer() {
  document.body.classList.toggle('nav-open');
}

/* ── textarea ────────────────────────────────────────────────────────── */
function autosize(el) {
  el.style.height = 'auto';
  el.style.height = Math.min(el.scrollHeight, 180) + 'px';
}

/* ── wiring ──────────────────────────────────────────────────────────── */
function wire() {
  $('#menu-btn').onclick = toggleDrawer;
  $('#drawer-close').onclick = closeDrawer;
  $('#scrim').onclick = closeDrawer;

  $('#proj-chip').onclick = openDrawer;

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

  $('#new-session').onclick = async () => {
    if (state.run) return;
    try {
      const s = await api('/api/session/new', {
        method: 'POST', body: JSON.stringify({ agent: state.agent }),
      });
      state.session = s.id;
      setTitle('New chat');
      showEmpty();
      await refreshSessions();
      setView('chat');
      closeDrawer();
      $('#prompt').focus();
    } catch { statusError('cannot create chat'); }
  };

  $('#open-chat').onclick = () => { setView('chat'); closeDrawer(); };
  $('#open-term').onclick = () => { setView('terminal'); closeDrawer(); };
  $('#open-files').onclick = () => { setView('files'); closeDrawer(); };
  $('#attach-btn').onclick = () => { setView('files'); };
  $('#back-files').onclick = () => {
    $('.files-wrap').classList.remove('file-open');
  };

  // chips: only "Auto" is a real switch; the rest are the app's readouts
  const auto = $$('.chip')[0];
  auto.onclick = () => {
    state.auto = !state.auto;
    auto.classList.toggle('on', state.auto);
    auto.title = state.auto
      ? 'Agents may use tools without asking'
      : 'Agents run read-only';
  };
  auto.title = 'Agents may use tools without asking';

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
    if (e.key === 'Escape') closeDrawer();
  });

  // desktop: the rail is permanent, so no scrim / drawer state
  matchMedia('(min-width: 1024px)').addEventListener('change', () => closeDrawer());
}

function hashView() {
  return decodeURIComponent(location.hash.slice(1)).split(':')[0];
}

function hashSession() {
  const h = decodeURIComponent(location.hash.slice(1));
  return h.startsWith('chat:') ? h.slice(5) : '';
}

function applyHash() {
  const h = decodeURIComponent(location.hash.slice(1));
  if (!h) return;
  const [view, arg] = h.split(':');
  if (view === 'files') {
    setView('files');
    if (arg) setTimeout(() => openFile(arg), 150);
  } else if (view === 'terminal') {
    setView('terminal');
  }
}

boot();
