#!/bin/sh
# ============================================================================
#  AntiGem Portable — acceptance tests
#  Runs headless on any POSIX host (Termux included) so the packaging can be
#  verified before it ever touches a laptop.
#
#    ./tests/smoke.sh            # all tests
#    ./tests/smoke.sh --quick    # skip the node download test
# ============================================================================
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

ESC=$(printf '\033')
G="$ESC[32m"; R="$ESC[31m"; Y="$ESC[33m"; D="$ESC[2m"; B="$ESC[1m"; O="$ESC[0m"

PASS=0; FAIL=0; SKIP=0; FAILED=""

pass() { PASS=$((PASS+1)); printf '  %sPASS%s %s\n' "$G" "$O" "$1"; }
fail() { FAIL=$((FAIL+1)); FAILED="$FAILED\n  - $1"; printf '  %sFAIL%s %s\n' "$R" "$O" "$1"; }
skip() { SKIP=$((SKIP+1)); printf '  %sSKIP%s %s\n' "$Y" "$O" "$1"; }

check() { # check <label> <needle> <haystack>
  case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (expected to find: $2)" ;; esac
}

section() { printf '\n%s%s%s\n' "$B" "$1" "$O"; }

# ----------------------------------------------------------------------------
section "1. repository integrity"
for f in linux.sh mac.sh windows.bat scripts/portable.sh scripts/proot.sh scripts/portable.ps1 README.md version.json .gitignore; do
  if [ -f "$ROOT/$f" ]; then pass "present: $f"; else fail "missing: $f"; fi
done
for f in linux.sh mac.sh scripts/portable.sh scripts/proot.sh; do
  [ -x "$ROOT/$f" ] && pass "executable: $f" || fail "not executable: $f"
done
sh -n "$ROOT/scripts/portable.sh" 2>/dev/null && pass "syntax: portable.sh" || fail "syntax error: portable.sh"
sh -n "$ROOT/scripts/proot.sh"    2>/dev/null && pass "syntax: proot.sh"     || fail "syntax error: proot.sh"

# no credentials or blobs in the tracked tree
if [ -d "$ROOT/.git" ]; then
  if git -C "$ROOT" ls-files | grep -qE '^(data|runtimes|packages)/'; then
    fail "git tracks data/, runtimes/ or packages/"
  else
    pass "git tracks no runtime/credential paths"
  fi
  if git -C "$ROOT" grep -lIE "sk-[A-Za-z0-9]{10}|gho_|apiKey\"?[[:space:]]*:[[:space:]]*\"[A-Za-z0-9]" \
       -- . ':(exclude)tests/*' >/dev/null 2>&1; then
    fail "possible secret committed"
  else
    pass "no obvious secrets in commits"
  fi
fi

# ----------------------------------------------------------------------------
section "2. launcher commands (current checkout)"
out=$("$ROOT/linux.sh" --doctor 2>&1); rc=$?
[ "$rc" -eq 0 ] && pass "--doctor exits 0" || fail "--doctor exit=$rc"
check "--doctor reports platform" "platform" "$out"
check "--doctor reports libc"     "libc:"    "$out"
check "--doctor lists engines"    "engines"   "$out"

out=$("$ROOT/linux.sh" --list 2>&1); rc=$?
[ "$rc" -eq 0 ] && pass "--list exits 0" || fail "--list exit=$rc"
check "--list shows claude"   "claude"   "$out"
check "--list shows codex"    "codex"    "$out"
check "--list shows opencode" "opencode" "$out"

out=$("$ROOT/linux.sh" --exec 'echo HOME=$HOME; echo MARKER_OK' 2>&1)
check "--exec runs commands" "MARKER_OK" "$out"
case "$out" in
  *"HOME=$ROOT/data/home"*) pass "--exec isolates HOME inside data/home" ;;
  *) fail "--exec HOME not isolated: $(printf '%s' "$out" | grep HOME= | head -1)" ;;
esac

out=$("$ROOT/linux.sh" --exec 'echo HOME=$HOME' --no-isolate 2>&1)
case "$out" in
  *"HOME=$ROOT"*) fail "--no-isolate still redirected HOME" ;;
  *) pass "--no-isolate keeps host HOME" ;;
esac

out=$("$ROOT/linux.sh" --agent codex --dry-run 2>&1)
check "--agent dry-run prints the command" "would run:" "$out"

out=$("$ROOT/linux.sh" --import --dry-run 2>&1)
check "--import dry-run lists files" "would copy" "$out"

# unknown flag must fail loudly
"$ROOT/linux.sh" --definitely-not-a-flag >/dev/null 2>&1
[ $? -ne 0 ] && pass "unknown flag rejected" || fail "unknown flag accepted"

# ----------------------------------------------------------------------------
section "3. glibc sandbox (Termux / bionic only)"
if "$ROOT/scripts/proot.sh" status 2>&1 | grep -q "rootfs:"; then
  out=$("$ROOT/scripts/proot.sh" run /bin/sh -c 'echo SANDBOX_OK; id -u' 2>&1)
  check "sandbox executes commands" "SANDBOX_OK" "$out"
  check "sandbox runs as fake root"  "0"          "$out"
  if [ -x "$ROOT/runtimes/proot/ubuntu/usr/local/bin/opencode" ]; then
    out=$("$ROOT/scripts/proot.sh" opencode --version 2>&1 | tail -1)
    check "opencode runs inside sandbox" "opencode v" "$out"
  else
    skip "opencode not installed in sandbox (run --proot then proot.sh opencode)"
  fi
else
  skip "no glibc sandbox on this host (not needed outside Termux)"
fi

# ----------------------------------------------------------------------------
section "4. fresh install from the published repo"
if command -v git >/dev/null 2>&1 && git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
  url=$(git -C "$ROOT" remote get-url origin)
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/agp-test.XXXXXX")
  if git clone -q --depth 1 "$url" "$tmp/repo" 2>/dev/null; then
    pass "clone from $url"
    out=$("$tmp/repo/linux.sh" --doctor 2>&1)
    check "fresh clone runs --doctor" "platform" "$out"
    out=$("$tmp/repo/linux.sh" --exec 'echo FRESH_OK' 2>&1)
    check "fresh clone --exec works" "FRESH_OK" "$out"
    [ -d "$tmp/repo/data/home" ] && pass "fresh clone creates data/home" || fail "fresh clone did not create data/home"
  else
    fail "clone failed (offline?)"
  fi
  rm -rf "$tmp"
else
  skip "no git remote to clone from"
fi

# ----------------------------------------------------------------------------
section "5. laptop path: portable Node download + checksum + layout"
if [ "$QUICK" -eq 1 ]; then
  skip "node download test (--quick)"
elif ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  skip "no curl/wget"
else
  work=$(mktemp -d "${TMPDIR:-/tmp}/agp-node.XXXXXX")
  pin=v22.14.0; file="node-$pin-linux-x64.tar.xz"
  if curl -fsL --retry 2 -o "$work/$file" "https://nodejs.org/dist/$pin/$file" 2>/dev/null; then
    pass "downloaded $file (the file a laptop would fetch)"
    if curl -fsL -o "$work/SHASUMS256.txt" "https://nodejs.org/dist/$pin/SHASUMS256.txt" 2>/dev/null; then
      want=$(grep " $file\$" "$work/SHASUMS256.txt" | awk '{print $1}' | head -1)
      got=$(sha256sum "$work/$file" 2>/dev/null | awk '{print $1}')
      [ -n "$want" ] && [ "$want" = "$got" ] && pass "checksum matches SHASUMS256.txt" || fail "checksum mismatch"
    else
      fail "could not fetch SHASUMS256.txt"
    fi
    mkdir -p "$work/x"
    if tar -xf "$work/$file" -C "$work/x" 2>/dev/null; then
      nodebin=$(find "$work/x" -maxdepth 3 -name node -type f | head -1)
      [ -n "$nodebin" ] && pass "extracts to <dir>/bin/node (layout the script normalises)" || fail "no node binary in archive"
      # can it execute? on bionic it cannot — that is expected and must be reported, not fatal
      if "$nodebin" -v >/dev/null 2>&1; then
        pass "glibc node executes on this host"
      else
        skip "glibc node cannot execute on $(uname -s)/$(uname -m) (expected on Termux; laptops will)"
      fi
    else
      fail "extraction failed"
    fi
  else
    fail "download failed (offline?)"
  fi
  rm -rf "$work"
fi

# ----------------------------------------------------------------------------
section "6. Windows path (static only)"
if command -v pwsh >/dev/null 2>&1; then
  if pwsh -NoLogo -NoProfile -Command "[void][System.Management.Automation.Language.Parser]::ParseFile('$ROOT/scripts/portable.ps1',[ref]\$null,[ref]\$e); if (\$e) { exit 1 }" 2>/dev/null; then
    pass "portable.ps1 parses"
  else
    fail "portable.ps1 has parse errors"
  fi
else
  skip "pwsh not installed — PowerShell syntax unverified on this device"
fi
grep -q 'PROCESSOR_ARCHITECTURE' "$ROOT/scripts/portable.ps1" && pass "ps1 handles ARCH" || fail "ps1 missing arch detection"
grep -q 'Get-FileHash'           "$ROOT/scripts/portable.ps1" && pass "ps1 verifies checksums" || fail "ps1 missing checksum verify"

# ----------------------------------------------------------------------------
section "7. web face"
for f in scripts/serve.py web/index.html web/app.css web/app.js; do
  [ -f "$ROOT/$f" ] && pass "present: $f" || fail "missing: $f"
done

if ! command -v python3 >/dev/null 2>&1; then
  skip "python3 not installed — the web face cannot start here"
else
  if python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$ROOT/scripts/serve.py" 2>/dev/null; then
    pass "serve.py parses"
  else
    fail "serve.py has a syntax error"
  fi

  if command -v node >/dev/null 2>&1; then
    node --check "$ROOT/web/app.js" 2>/dev/null && pass "app.js parses" || fail "app.js has a syntax error"
  else
    skip "node not available to check app.js"
  fi

  if ! command -v curl >/dev/null 2>&1; then
    skip "curl not available — live web face checks skipped"
  else
    sport=8899
    slog=$(mktemp "${TMPDIR:-/tmp}/agp-serve.XXXXXX")
    python3 "$ROOT/scripts/serve.py" --port "$sport" > "$slog" 2>&1 &
    srv=$!
    n=0
    while [ "$n" -lt 40 ]; do
      curl -sf -m 1 "http://127.0.0.1:$sport/api/info" >/dev/null 2>&1 && break
      n=$((n+1)); sleep 0.25
    done

    if curl -sf -m 5 "http://127.0.0.1:$sport/api/info" > "$slog.info" 2>/dev/null; then
      pass "server starts and answers /api/info"
      check "info reports a version" '"version"' "$(cat "$slog.info")"
      check "info lists agents"      '"id"'      "$(cat "$slog.info")"

      body=$(curl -sf -m 5 "http://127.0.0.1:$sport/" 2>/dev/null)
      check "serves the face at /" "AntiGem" "$body"
      curl -sf -m 5 "http://127.0.0.1:$sport/static/app.js"  >/dev/null 2>&1 && pass "serves /static/app.js"  || fail "app.js not served"
      curl -sf -m 5 "http://127.0.0.1:$sport/static/app.css" >/dev/null 2>&1 && pass "serves /static/app.css" || fail "app.css not served"

      files=$(curl -sf -m 5 "http://127.0.0.1:$sport/api/files?path=." 2>/dev/null)
      check "lists the workspace" '"type": "dir"' "$files"

      plan=$(curl -sf -m 5 "http://127.0.0.1:$sport/api/plan?agent=claude&prompt=hi" 2>/dev/null)
      check "plan resolves a real command" '"cmd"' "$plan"

      run=$(curl -sf -m 5 -X POST "http://127.0.0.1:$sport/api/term" \
              -H 'Content-Type: application/json' \
              -d '{"cmd":"echo FACE_MARKER"}' 2>/dev/null)
      rid=$(printf '%s' "$run" | sed -n 's/.*"run": *"\([^"]*\)".*/\1/p')
      if [ -n "$rid" ]; then
        stream=$(curl -sf -m 15 -N "http://127.0.0.1:$sport/api/stream/$rid" 2>/dev/null)
        check "streams command output over SSE" "FACE_MARKER" "$stream"
        check "stream ends with done"            "event: done" "$stream"
      else
        fail "could not start a terminal run"
      fi
    else
      fail "web face did not start (see $slog)"
      tail -3 "$slog" 2>/dev/null
    fi

    kill "$srv" 2>/dev/null
    rm -f "$slog" "$slog.info"
  fi
fi

# ----------------------------------------------------------------------------
printf '\n%s%d passed, %d failed, %d skipped%s\n' "$B" "$PASS" "$FAIL" "$SKIP" "$O"
if [ "$FAIL" -ne 0 ]; then printf '%sfailures:%s%b\n' "$R" "$O" "$FAILED"; exit 1; fi
printf '%sAll good — this checkout is portable-ready.%s\n' "$G" "$O"
