#!/usr/bin/env python3
"""
AntiGem Portable — local web face.

Serves a single-page workspace (chat / terminal / files) on 127.0.0.1 and runs
the agent CLIs from the portable environment. Standard library only: no npm,
no pip, nothing to install.

    python3 scripts/serve.py --port 8787
"""
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import uuid
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse, parse_qs, unquote

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
WEB = ROOT / "web"
SESSIONS = DATA / "sessions"
SESSIONS.mkdir(parents=True, exist_ok=True)
WORKSPACE = Path(os.environ.get("ANTIGEM_WORKSPACE") or (DATA / "workspace")).resolve()
WORKSPACE.mkdir(parents=True, exist_ok=True)
VERSION = "0.2.0"

HOST = os.environ.get("ANTIGEM_BIND", "127.0.0.1")
PORT = int(os.environ.get("ANTIGEM_PORT", "8787"))

RUNS = {}          # run_id -> {proc, queue, kind, session, agent, chunks}
RUNS_LOCK = threading.Lock()
TERM_LOG = []      # last terminal runs, so the tab has scrollback after a reload
TERM_LOCK = threading.Lock()
TERM_MAX = 60

_ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)|\x1b[@-Z\\-_]")


def strip_ansi(s):
    return _ANSI.sub("", s)



# --------------------------------------------------------------------------- env
def portable_env():
    env = os.environ.copy()
    home = str(DATA / "home")
    tmp = str(DATA / "tmp")
    Path(home).mkdir(parents=True, exist_ok=True)
    Path(tmp).mkdir(parents=True, exist_ok=True)
    env.update({
        "HOME": home,
        "XDG_CONFIG_HOME": os.path.join(home, ".config"),
        "XDG_DATA_HOME": os.path.join(home, ".local", "share"),
        "XDG_CACHE_HOME": os.path.join(home, ".cache"),
        "TMPDIR": tmp, "TMP": tmp, "TEMP": tmp,
        "ANTIGEM_PORTABLE": "1",
        "TERM": "xterm-256color",
        "FORCE_COLOR": "1",
        "NO_COLOR": "",
    })
    return env


ENV = portable_env()


def which(name):
    return shutil.which(name, path=ENV.get("PATH"))


def detect_agents():
    found = []
    for key, label in (("claude", "Claude Code"), ("codex", "Codex"),
                       ("agy", "Antigravity"), ("opencode", "OpenCode")):
        p = which(key)
        status = "ready" if p else "missing"
        if key == "opencode" and not p:
            cand = ROOT / "runtimes" / "proot" / "ubuntu" / "usr/local/bin/opencode"
            if cand.exists():
                status, p = "ready (proot)", str(cand)
            else:
                hb = Path(ENV.get("ANTIGEM_HOST_HOME", "")) / ".opencode/bin/opencode"
                if hb.exists():
                    status, p = "glibc (needs proot)", str(hb)
        found.append({"id": key, "label": label, "path": p or "", "status": status})
    found.append({"id": "shell", "label": "Shell", "path": "/bin/sh", "status": "ready"})
    return found


AGENTS = detect_agents()


def build_cmd(agent, prompt):
    auto = os.environ.get("ANTIGEM_AUTO_APPROVE", "1") != "0"
    if agent == "claude":
        cmd = [which("claude"), "-p", prompt, "--output-format", "stream-json", "--verbose"]
        if auto:
            cmd.append("--dangerously-skip-permissions")
        return cmd
    if agent == "agy":
        cmd = [which("agy"), "-p", prompt, "--output-format", "stream-json"]
        if auto:
            cmd.append("--dangerously-skip-permissions")
        return cmd
    if agent == "codex":
        return [which("codex"), "exec", "--json", "--skip-git-repo-check",
                "-s", "workspace-write" if auto else "read-only", prompt]
    if agent == "opencode":
        return ["/bin/sh", str(ROOT / "scripts" / "proot.sh"), "run",
                "/usr/local/bin/opencode", "run", prompt]
    return ["/bin/sh", "-c", prompt]


def json_agent(agent):
    return agent in ("claude", "codex", "agy")



# --------------------------------------------------------------------------- sessions
def sfile(sid):
    return SESSIONS / f"{sid}.json"


def load_session(sid):
    p = sfile(sid)
    if not p.exists():
        return None
    return json.loads(p.read_text())


def save_session(s):
    sfile(s["id"]).write_text(json.dumps(s, indent=1))


def create_session(agent="claude", title="New session"):
    sid = uuid.uuid4().hex[:12]
    s = {"id": sid, "title": title, "agent": agent, "created": time.time(),
         "updated": time.time(), "messages": []}
    save_session(s)
    return s


def list_sessions():
    out = []
    for p in sorted(SESSIONS.glob("*.json"), key=lambda x: x.stat().st_mtime, reverse=True):
        try:
            s = json.loads(p.read_text())
            out.append({"id": s["id"], "title": s.get("title", "session"),
                        "agent": s.get("agent", "claude"), "updated": s.get("updated", 0),
                        "count": len(s.get("messages", []))})
        except Exception:
            continue
    return out[:60]


# --------------------------------------------------------------------------- runs
def start_run(kind, agent, prompt, sid=None):
    rid = uuid.uuid4().hex[:12]
    cmd = build_cmd(agent, prompt)
    if not cmd or not cmd[0]:
        raise RuntimeError(f"agent '{agent}' is not installed")

    run = {"id": rid, "kind": kind, "agent": agent, "session": sid,
           "queue": [], "chunks": [], "parts": [], "done": False, "code": None,
           "started": time.time(), "proc": None}
    run["queue"] = _Queue()
    with RUNS_LOCK:
        RUNS[rid] = run

    if sid:
        s = load_session(sid) or create_session(agent)
        s["messages"].append({"role": "user", "content": prompt, "ts": time.time()})
        s["updated"] = time.time()
        if s["title"] in ("New session", "") or not s["title"]:
            s["title"] = prompt.strip().splitlines()[0][:48]
        save_session(s)

    def pump():
        try:
            proc = subprocess.Popen(
                cmd, cwd=str(WORKSPACE), env=ENV, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, bufsize=1, start_new_session=True)
            run["proc"] = proc
            had_text = False
            for line in proc.stdout:  # type: ignore[union-attr]
                for ev_kind, payload in parse_line(line):
                    if ev_kind == "final":
                        if had_text:
                            continue
                        ev_kind = "message"
                    if ev_kind == "message":
                        if not str(payload).strip():
                            continue
                        had_text = True
                        text = str(payload)
                        run["chunks"].append(text)
                        if run["parts"] and run["parts"][-1]["type"] == "text":
                            prev = run["parts"][-1]["text"]
                            sep = "" if (prev.endswith("\n") or text.startswith("\n")) else "\n\n"
                            run["parts"][-1]["text"] = prev + sep + text
                        else:
                            run["parts"].append({"type": "text", "text": text})
                    elif ev_kind == "tool":
                        run["parts"].append({"type": "tool", "name": payload.get("name"),
                                             "input": payload.get("input")})
                    run["queue"].put((ev_kind, payload))
            proc.wait()
            run["code"] = proc.returncode
        except Exception as e:  # noqa: BLE001
            run["queue"].put(("message", f"\n[error] {e}\n"))
            run["code"] = -1
        finally:
            run["done"] = True
            text = "".join(run["chunks"]).strip()
            if sid and text:
                s = load_session(sid) or create_session(agent)
                s["messages"].append({"role": "assistant", "content": text,
                                      "parts": run["parts"],
                                      "ts": time.time(), "agent": agent})
                s["updated"] = time.time()
                save_session(s)
            if kind == "term":
                with TERM_LOCK:
                    TERM_LOG.append({"cmd": prompt, "out": "".join(run["chunks"]),
                                     "code": run["code"], "ts": time.time()})
                    del TERM_LOG[:-TERM_MAX]
            run["queue"].put(("done", {"code": run["code"]}))

    threading.Thread(target=pump, daemon=True).start()
    return rid


def parse_line(line):
    """Turn one CLI output line into ('message'|'tool'|'final', payload) events."""
    txt = strip_ansi(line).rstrip("\n")
    if not txt.strip():
        return []
    stripped = txt.strip()

    if stripped in _NOISE:
        return []

    if stripped.startswith("{"):
        try:
            obj = json.loads(stripped)
        except Exception:
            obj = None
        if isinstance(obj, dict):
            return _parse_object(obj)

    return [("message", txt + "\n")]


_NOISE = {
    "Reading additional input from stdin...",
    "--------",
}


def _parse_object(obj):
    t = obj.get("type")

    # ---- claude code / agy stream-json
    if t == "assistant":
        out = []
        for c in (obj.get("message") or {}).get("content", []):
            if not isinstance(c, dict):
                continue
            if c.get("type") == "text" and c.get("text"):
                out.append(("message", c["text"]))
            elif c.get("type") == "tool_use":
                out.append(("tool", {"name": c.get("name"), "input": c.get("input")}))
        return out
    if t == "result":
        r = obj.get("result")
        return [("final", str(r))] if r else []
    if t == "system" or t == "user":
        return []

    # ---- agy wraps everything in {"event": ...}
    if obj.get("event") == "result":
        r = obj.get("result") or {}
        txt = r.get("response") or r.get("error") or ""
        return [("final", str(txt))] if txt else []

    # ---- codex exec --json
    if t in ("thread.started", "turn.started", "turn.completed"):
        return []
    if t in ("item.started", "item.completed", "item.updated"):
        item = obj.get("item") or {}
        kind = item.get("type")
        if kind == "agent_message":
            txt = item.get("text")
            return [("message", str(txt))] if txt else []
        if t == "item.completed" and kind == "command_execution":
            cmd = item.get("command") or ""
            return [("tool", {"name": "shell", "input": {
                "command": cmd,
                "exit_code": item.get("exit_code"),
                "output": (item.get("aggregated_output") or "").strip()[:4000],
            }})]
        if t == "item.completed" and kind in ("file_change", "patch"):
            return [("tool", {"name": kind, "input": item.get("changes") or item})]
        if t == "item.completed" and kind == "reasoning":
            return []
        return []

    # ---- anything else with a text field
    for key in ("text", "message", "content", "response"):
        v = obj.get(key)
        if isinstance(v, str) and v.strip():
            return [("message", v)]
    return []



class _Queue:
    """Tiny thread-safe queue (avoids importing queue twice)."""

    def __init__(self):
        self.items = []
        self.lock = threading.Condition()
        self.closed = False

    def put(self, item):
        with self.lock:
            self.items.append(item)
            self.lock.notify_all()

    def get(self, timeout=1.0):
        with self.lock:
            if not self.items:
                self.lock.wait(timeout)
            return self.items.pop(0) if self.items else None


# --------------------------------------------------------------------------- http
class Handler(BaseHTTPRequestHandler):
    server_version = f"AntiGemPortable/{VERSION}"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):  # quieter logs
        if os.environ.get("ANTIGEM_VERBOSE"):
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % a))

    # ---- helpers
    def send_json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def send_file(self, path, ctype):
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if not n:
            return {}
        return json.loads(self.rfile.read(n) or b"{}")

    def safe_path(self, rel):
        p = (WORKSPACE / unquote(rel or "")).resolve()
        if not str(p).startswith(str(WORKSPACE)):
            raise ValueError("outside workspace")
        return p

    # ---- GET
    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        path = u.path

        if path in ("/", "/index.html"):
            return self.send_file(WEB / "index.html", "text/html; charset=utf-8")
        if path.startswith("/static/"):
            f = WEB / path[len("/static/"):]
            if not f.exists():
                return self.send_json({"error": "not found"}, 404)
            ctype = {"css": "text/css", "js": "text/javascript",
                     "svg": "image/svg+xml", "png": "image/png"}.get(f.suffix.lstrip("."), "text/plain")
            return self.send_file(f, ctype + ("; charset=utf-8" if f.suffix in (".css", ".js") else ""))

        if path == "/api/info":
            return self.send_json({
                "version": VERSION,
                "workspace": str(WORKSPACE),
                "agents": AGENTS,
                "platform": os.uname().machine,
                "node": which("node") or "",
                "sessions": list_sessions(),
                "default_agent": os.environ.get("ANTIGEM_AGENT", "claude"),
            })

        if path == "/api/sessions":
            return self.send_json({"sessions": list_sessions()})

        if path.startswith("/api/session/"):
            sid = path.rsplit("/", 1)[-1]
            s = load_session(sid)
            return self.send_json(s or {"error": "no such session"}, 200 if s else 404)

        if path == "/api/files":
            try:
                p = self.safe_path((q.get("path") or ["."])[0])
            except ValueError:
                return self.send_json({"error": "outside workspace"}, 400)
            if p.is_file():
                return self.send_json({"type": "file", "path": str(p.relative_to(WORKSPACE))})
            items = []
            try:
                for e in sorted(p.iterdir(), key=lambda x: (x.is_file(), x.name.lower()))[:400]:
                    if e.name in (".git", "node_modules", "__pycache__"):
                        continue
                    items.append({"name": e.name, "dir": e.is_dir(),
                                  "size": e.stat().st_size if e.is_file() else 0})
            except PermissionError:
                pass
            return self.send_json({"type": "dir", "path": str(p.relative_to(WORKSPACE)) or ".",
                                   "items": items})

        if path == "/api/file":
            try:
                p = self.safe_path((q.get("path") or [""])[0])
            except ValueError:
                return self.send_json({"error": "outside workspace"}, 400)
            if not p.is_file():
                return self.send_json({"error": "not a file"}, 404)
            if p.stat().st_size > 512_000:
                return self.send_json({"error": "file too large"}, 413)
            try:
                return self.send_json({"path": str(p.relative_to(WORKSPACE)),
                                       "content": p.read_text(errors="replace")})
            except Exception as e:  # noqa: BLE001
                return self.send_json({"error": str(e)}, 400)

        if path.startswith("/api/stream/"):
            rid = path.rsplit("/", 1)[-1]
            return self.stream_run(rid)

        if path == "/api/plan":
            agent = (q.get("agent") or ["claude"])[0]
            prompt = (q.get("prompt") or [""])[0]
            return self.send_json({"agent": agent, "cmd": build_cmd(agent, prompt)})

        if path == "/api/term/history":
            with TERM_LOCK:
                return self.send_json({"items": list(TERM_LOG)})

        return self.send_json({"error": "not found"}, 404)

    # ---- POST
    def do_POST(self):
        u = urlparse(self.path)
        path = u.path
        try:
            data = self.body()
        except Exception:
            return self.send_json({"error": "bad json"}, 400)

        if path == "/api/chat":
            agent = data.get("agent") or "claude"
            prompt = (data.get("prompt") or "").strip()
            sid = data.get("session")
            if not prompt:
                return self.send_json({"error": "empty prompt"}, 400)
            if not sid:
                sid = create_session(agent)["id"]
            try:
                rid = start_run("chat", agent, prompt, sid)
            except Exception as e:  # noqa: BLE001
                return self.send_json({"error": str(e)}, 500)
            return self.send_json({"run": rid, "session": sid})

        if path == "/api/term":
            cmd = (data.get("cmd") or "").strip()
            if not cmd:
                return self.send_json({"error": "empty command"}, 400)
            rid = start_run("term", "shell", cmd)
            return self.send_json({"run": rid})

        if path == "/api/session/new":
            s = create_session(data.get("agent", "claude"))
            return self.send_json(s)

        if path == "/api/session/rename":
            s = load_session(data.get("id", ""))
            if not s:
                return self.send_json({"error": "no such session"}, 404)
            s["title"] = (data.get("title") or s["title"])[:80]
            save_session(s)
            return self.send_json(s)

        if path == "/api/cancel":
            rid = data.get("run", "")
            run = RUNS.get(rid)
            if run and run["proc"]:
                try:
                    run["proc"].kill()
                except Exception:
                    pass
                return self.send_json({"cancelled": rid})
            return self.send_json({"error": "no such run"}, 404)

        if path == "/api/save":
            try:
                p = self.safe_path(data.get("path", ""))
            except ValueError:
                return self.send_json({"error": "outside workspace"}, 400)
            p.write_text(data.get("content", ""))
            return self.send_json({"saved": str(p.relative_to(WORKSPACE))})

        return self.send_json({"error": "not found"}, 404)

    # ---- SSE
    def stream_run(self, rid):
        run = RUNS.get(rid)
        if not run:
            return self.send_json({"error": "no such run"}, 404)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            while True:
                item = run["queue"].get(timeout=15)
                if item is None:
                    self.wfile.write(b": keepalive\n\n")
                    self.wfile.flush()
                    if run["done"]:
                        break
                    continue
                kind, payload = item
                self.wfile.write(f"event: {kind}\n".encode())
                self.wfile.write(b"data: " + json.dumps(payload).encode() + b"\n\n")
                self.wfile.flush()
                if kind == "done":
                    break
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self.close_connection = True


def main():
    global HOST, PORT
    args = sys.argv[1:]
    if "--port" in args:
        PORT = int(args[args.index("--port") + 1])
    if "--host" in args:
        HOST = args[args.index("--host") + 1]
    if "--workspace" in args:
        global WORKSPACE
        WORKSPACE = Path(args[args.index("--workspace") + 1]).resolve()
        WORKSPACE.mkdir(parents=True, exist_ok=True)

    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    srv.daemon_threads = True
    url = f"http://{HOST if HOST != '0.0.0.0' else '127.0.0.1'}:{PORT}"
    print(f"AntiGem Portable {VERSION} — web face")
    print(f"  url        {url}")
    print(f"  workspace  {WORKSPACE}")
    print(f"  agents     " + ", ".join(f"{a['id']}={a['status']}" for a in AGENTS))
    if HOST == "0.0.0.0":
        print("  warning    bound to all interfaces — anyone on this network can use it")
    sys.stdout.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
