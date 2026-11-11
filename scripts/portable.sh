#!/bin/sh
# ============================================================================
#  AntiGem Portable — a self-contained launcher for the AntiGem agent stack
#  Packaging technique modelled on techjarves/*-Portable:
#    bootstrap runtime  ->  verify checksums  ->  isolate HOME  ->  menu
#  Everything (config, sessions, credentials, downloads) stays inside this
#  folder, so it can live on a USB stick, an SD card, or a Termux home.
# ============================================================================
set -eu

APP_NAME="AntiGem Portable"
VERSION="0.2.0"

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
DATA="$ROOT/data"
RUNTIMES="$ROOT/runtimes"
PACKAGES="$ROOT/packages"
WORKSPACE_DEFAULT="$DATA/workspace"

NODE_PIN="v22.14.0"
NODE_MIN_MAJOR=20
NODE_URL_BASE="https://nodejs.org/dist"

ESC=$(printf '\033')
C_BOLD="$ESC[1m"; C_DIM="$ESC[2m"; C_RED="$ESC[31m"
C_GREEN="$ESC[32m"; C_YELLOW="$ESC[33m"; C_CYAN="$ESC[36m"; C_OFF="$ESC[0m"

log()  { printf '%s\n' "$*"; }
info() { printf '%s%s%s\n' "$C_CYAN" "$*" "$C_OFF"; }
ok()   { printf '%s%s%s\n' "$C_GREEN" "$*" "$C_OFF"; }
warn() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_OFF" >&2; }
die()  { printf '%s%s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
$APP_NAME $VERSION

usage: ${0##*/} [command]

  --menu | (none in a TTY)   interactive menu
  --doctor                   environment + engine report
  --agent NAME               start an agent (claude | codex | agy | opencode)
  --exec "CMD"               run a command inside the portable environment
  --import [--with-mcp]      copy host agent credentials into ./data/home
  --update                   refresh portable Node runtime
  --proot                    install the glibc sandbox (Ubuntu rootfs) for engines
                             that cannot run on Termux/bionic, e.g. opencode
  --list                     list detected engines
  --serve [PORT]             start the web face (chat/terminal/files) in a browser
  --workspace DIR            working directory for agents (default ./data/workspace)
  --no-isolate               keep the host HOME instead of ./data/home
  --dry-run                  print what would run, change nothing
  -h | --help                this text

env overrides:
  ANTIGEM_AGENT      default agent
  ANTIGEM_MODEL      exported to agents that read it (optional)
  ANTIGEM_WORKSPACE  default working directory
  ANTIGEM_HOME       override portable home (default ./data/home)
  ANTIGEM_STRICT     =1 -> fail instead of warning when an engine is missing
  ANTIGEM_BIND       web face bind address (default 127.0.0.1)
  ANTIGEM_PORT       web face port (default 8787)
  AUTO_LAUNCH_BROWSER =1 -> open the web face in a browser after starting
EOF
}

# ----------------------------------------------------------------------------
# platform + runtime
# ----------------------------------------------------------------------------
detect_platform() {
  OS=$(uname -s 2>/dev/null || echo unknown)
  ARCH=$(uname -m 2>/dev/null || echo unknown)
  case "$OS:$ARCH" in
    Linux:x86_64|Linux:amd64)   TARGET="linux-x64" ;;
    Linux:aarch64|Linux:arm64)  TARGET="linux-arm64" ;;
    Darwin:arm64)               TARGET="macos-arm64" ;;
    Darwin:x86_64)              TARGET="macos-x64" ;;
    MINGW*:x86_64|MSYS*:x86_64) TARGET="windows-x64" ;;
    *) TARGET="unsupported-$OS-$ARCH" ;;
  esac
  if [ "$TARGET" = "unsupported-$OS-$ARCH" ]; then
    die "Unsupported platform: $OS $ARCH (supported: Linux x64/arm64, macOS arm64/x64)"
  fi
}

is_android() {
  [ -n "${TERMUX_VERSION:-}" ] && return 0
  [ -d "/data/data/com.termux" ] && return 0
  case "${PREFIX:-}" in *com.termux*) return 0 ;; esac
  [ "$(uname -o 2>/dev/null || true)" = "Android" ] && return 0
  return 1
}

libc_kind() {
  if is_android; then echo "bionic (Termux)"; return; fi
  if getconf GNU_LIBC_VERSION >/dev/null 2>&1; then echo "glibc"; return; fi
  echo "unknown"
}

# capture the host environment BEFORE we redirect HOME
capture_host() {
  HOST_HOME=${HOME:-}
  SYS_NODE=$(command -v node || true)
  ENGINE_CLAUDE=$(command -v claude || true)
  ENGINE_CODEX=$(command -v codex || true)
  ENGINE_AGY=$(command -v agy || true)
  ENGINE_OPENCODE=$(command -v opencode || true)
  if [ -z "$ENGINE_OPENCODE" ] && [ -x "$HOST_HOME/.opencode/bin/opencode" ]; then
    ENGINE_OPENCODE="$HOST_HOME/.opencode/bin/opencode"
  fi
  ENGINE_DIRS=""
  for p in "$ENGINE_CLAUDE" "$ENGINE_CODEX" "$ENGINE_AGY" "$ENGINE_OPENCODE"; do
    [ -n "$p" ] || continue
    d=$(dirname "$p")
    case ":$ENGINE_DIRS:" in *":$d:"*) ;; *) ENGINE_DIRS="${ENGINE_DIRS:+$ENGINE_DIRS:}$d" ;; esac
  done
}

# does this binary target the host? glibc ELF cannot run on bionic
elf_usable() {
  bin=$1
  [ -n "$bin" ] && [ -x "$bin" ] || return 1
  if is_android && have readelf; then
    interp=$(readelf -l "$bin" 2>/dev/null | sed -n 's/.*program interpreter: \(.*\)\]/\1/p' | head -1)
    case "$interp" in
      /lib/ld-linux*|/lib64/ld-linux*) return 1 ;;   # glibc loader -> unusable on Android
    esac
  fi
  return 0
}

isolate_home() {
  [ "${NO_ISOLATE:-0}" = "1" ] && { info "isolation disabled (host HOME)"; return; }
  PORTABLE_HOME=${ANTIGEM_HOME:-$DATA/home}
  PORTABLE_TMP="$DATA/tmp"
  mkdir -p "$PORTABLE_HOME" "$PORTABLE_TMP"
  export HOME="$PORTABLE_HOME"
  export XDG_CONFIG_HOME="$HOME/.config"
  export XDG_DATA_HOME="$HOME/.local/share"
  export XDG_CACHE_HOME="$HOME/.cache"
  export XDG_STATE_HOME="$HOME/.local/state"
  export TMPDIR="$PORTABLE_TMP" TMP="$PORTABLE_TMP" TEMP="$PORTABLE_TMP"
  export ANTIGEM_PORTABLE=1
  export ANTIGEM_PORTABLE_ROOT="$ROOT"
  export ANTIGEM_HOST_HOME="$HOST_HOME"
  if [ -n "$ENGINE_DIRS" ]; then PATH="$ENGINE_DIRS:$PATH"; fi
  for d in "$HOME/.local/bin" "$HOME/bin" "$PREFIX/bin" /usr/local/bin; do
    [ -d "$d" ] && PATH="$PATH:$d"
  done
  export PATH
}

node_major() { node_out=$("$1" -v 2>/dev/null || echo v0); echo "${node_out#v}" | cut -d. -f1; }

ensure_node() {
  # 1) portable runtime inside the folder
  cand="$RUNTIMES/$TARGET/node/bin/node"
  if [ -x "$cand" ]; then
    RUN_NODE="$cand"; NODE_ORIGIN="portable"
  # 2) system runtime (Termux ships its own; that *is* a contained runtime)
  elif [ -n "$SYS_NODE" ] && [ -x "$SYS_NODE" ]; then
    RUN_NODE="$SYS_NODE"
    if is_android; then NODE_ORIGIN="Termux"; else NODE_ORIGIN="system"; fi
  else
    RUN_NODE=""
  fi
  if [ -z "$RUN_NODE" ]; then
    if [ "${DRY_RUN:-0}" = "1" ]; then
      warn "no node runtime present; --update would download $NODE_PIN for $TARGET"
      NODE_ORIGIN="missing"; return
    fi
    download_node
    RUN_NODE="$RUNTIMES/$TARGET/node/bin/node"; NODE_ORIGIN="portable"
  fi
  maj=$(node_major "$RUN_NODE")
  [ "$maj" -ge "$NODE_MIN_MAJOR" ] 2>/dev/null || warn "node $maj is older than the recommended $NODE_MIN_MAJOR"
  export ANTIGEM_NODE="$RUN_NODE"
}

download_node() {
  is_android && die "nodejs.org has no Android build — install Node through Termux (pkg install nodejs)"
  case "$TARGET" in
    linux-x64)    plat="linux-x64";    ext="tar.xz" ;;
    linux-arm64)  plat="linux-arm64";  ext="tar.xz" ;;
    macos-arm64)  plat="darwin-arm64"; ext="tar.gz" ;;
    macos-x64)    plat="darwin-x64";   ext="tar.gz" ;;
    *) die "no Node build for $TARGET" ;;
  esac
  file="node-$NODE_PIN-$plat.$ext"
  url="$NODE_URL_BASE/$NODE_PIN/$file"
  sums="$NODE_URL_BASE/$NODE_PIN/SHASUMS256.txt"
  mkdir -p "$PACKAGES" "$RUNTIMES"
  info "Downloading portable Node $NODE_PIN for $TARGET…"
  fetch "$url" "$PACKAGES/$file"
  info "Verifying checksum…"
  fetch "$sums" "$PACKAGES/SHASUMS256.txt"
  want=$(grep " $file\$" "$PACKAGES/SHASUMS256.txt" | awk '{print $1}' | head -1)
  [ -n "$want" ] || die "checksum for $file not found in SHASUMS256.txt"
  got=$(sha256_file "$PACKAGES/$file")
  [ "$want" = "$got" ] || die "checksum mismatch for $file
  expected $want
  got      $got"
  info "Extracting…"
  rm -rf "$RUNTIMES/.tmp"
  mkdir -p "$RUNTIMES/.tmp"
  tar -xf "$PACKAGES/$file" -C "$RUNTIMES/.tmp"
  # normalise to runtimes/<target>/node
  dir=$(find "$RUNTIMES/.tmp" -maxdepth 1 -mindepth 1 -type d | head -1)
  [ -n "$dir" ] || die "archive did not contain a node directory"
  mkdir -p "$RUNTIMES/$TARGET"
  rm -rf "$RUNTIMES/$TARGET/node"
  mv "$dir" "$RUNTIMES/$TARGET/node"
  rm -rf "$RUNTIMES/.tmp" "$PACKAGES/$file" "$PACKAGES/SHASUMS256.txt"
  [ -x "$RUNTIMES/$TARGET/node/bin/node" ] || die "portable Node extraction failed"
  ok "Portable Node ready."
}

sha256_file() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  elif have shasum; then shasum -a 256 "$1" | awk '{print $1}'
  else die "sha256sum or shasum is required"; fi
}

fetch() {
  url=$1; out=$2
  mkdir -p "$(dirname -- "$out")"
  if have curl; then curl -fL --retry 3 -C - -o "$out.part" "$url"
  elif have wget; then wget -c -O "$out.part" "$url"
  else die "curl or wget is required"; fi
  mv -f "$out.part" "$out"
}

# ----------------------------------------------------------------------------
# config
# ----------------------------------------------------------------------------
load_config() {
  CFG="$DATA/config.env"
  if [ ! -f "$CFG" ]; then
    mkdir -p "$DATA"
    cat > "$CFG" <<'CFGEOF'
# AntiGem Portable — edit freely
ANTIGEM_AGENT=claude
ANTIGEM_MODEL=
ANTIGEM_WORKSPACE=data/workspace
AUTO_LAUNCH_BROWSER=false
CFGEOF
  fi
  # shellcheck disable=SC1090
  . "$CFG"
  [ -n "${ANTIGEM_AGENT:-}" ] || ANTIGEM_AGENT=claude
}

resolve_workspace() {
  ws=${WORKSPACE_OVERRIDE:-${ANTIGEM_WORKSPACE:-$WORKSPACE_DEFAULT}}
  case "$ws" in
    data/*) ws="$ROOT/$ws" ;;
    ./*|../*) ws=$(CDPATH= cd -- "$ROOT" && cd -- "$ws" 2>/dev/null && pwd -P) || ws="$ROOT/${ws#./}" ;;
  esac
  [ -n "$ws" ] || ws="$WORKSPACE_DEFAULT"
  mkdir -p "$ws" 2>/dev/null || true
  WORKSPACE="$ws"
}

# ----------------------------------------------------------------------------
# engines
# ----------------------------------------------------------------------------
engine_path() {
  case "$1" in
    claude) echo "$ENGINE_CLAUDE" ;;
    codex)  echo "$ENGINE_CODEX" ;;
    agy)    echo "$ENGINE_AGY" ;;
    opencode) echo "$ENGINE_OPENCODE" ;;
    *) echo "" ;;
  esac
}

engine_status() {
  name=$1; p=$(engine_path "$name")
  if [ -z "$p" ]; then echo "missing"; return; fi
  if [ ! -x "$p" ]; then echo "not-executable"; return; fi
  if elf_usable "$p"; then echo "ready"; else echo "incompatible"; fi
}

engine_ready() { [ "$(engine_status "$1")" = "ready" ]; }

proot_rootfs() { [ -x "$ROOT/runtimes/proot/ubuntu/bin/sh" ]; }
proot_engine() { [ -x "$ROOT/runtimes/proot/ubuntu/usr/local/bin/$1" ]; }
engine_display() {
  name=$1; st=$(engine_status "$name")
  if proot_engine "$name"; then
    case "$st" in incompatible|missing) echo "ready (proot)"; return ;; esac
  fi
  echo "$st"
}

list_engines() {
  for e in claude codex agy opencode; do
    st=$(engine_display "$e"); p=$(engine_path "$e")
    printf '  %-9s %-13s %s\n' "$e" "$st" "${p:--}"
  done
}

pick_engine() {
  for e in "$@"; do
    if engine_ready "$e"; then echo "$e"; return 0; fi
  done
  return 1
}

start_agent() {
  name=${1:-$ANTIGEM_AGENT}
  st=$(engine_display "$name")
  case "$st" in
    ready) ;;
    "ready (proot)")
      info "Starting $name inside the glibc sandbox · workspace: $WORKSPACE"
      if [ "${DRY_RUN:-0}" = "1" ]; then log "would run: $ROOT/scripts/proot.sh $name"; return; fi
      exec /bin/sh "$ROOT/scripts/proot.sh" "$name"
      ;;
    missing)     die "engine '$name' not found. Install it (claude: npm i -g @anthropic-ai/claude-code, codex: pkg install codex) or run --doctor" ;;
    incompatible) die "engine '$name' needs glibc, which $(libc_kind) does not provide.
  run: $ROOT/linux.sh --proot     (installs a self-contained Ubuntu rootfs, ~30 MB)" ;;
    *)           die "engine '$name' is not executable: $(engine_path "$name")" ;;
  esac
  bin=$(engine_path "$name")
  info "Starting $name  ·  workspace: $WORKSPACE"
  log "${C_DIM}engine: $bin${C_OFF}"
  if [ "${DRY_RUN:-0}" = "1" ]; then log "would run: cd '$WORKSPACE' && exec '$bin'"; return; fi
  if [ -n "${ANTIGEM_MODEL:-}" ]; then export ANTIGEM_MODEL; fi
  cd "$WORKSPACE"
  exec "$bin"
}

# ----------------------------------------------------------------------------
# commands
# ----------------------------------------------------------------------------
cmd_doctor() {
  log ""
  log "${C_BOLD}$APP_NAME $VERSION${C_OFF}"
  log "${C_DIM}root${C_OFF}      $ROOT"
  log "${C_DIM}platform${C_OFF}  $TARGET ($(uname -s) $(uname -m)) · libc: $(libc_kind)"
  log "${C_DIM}node${C_OFF}      ${RUN_NODE:-missing} ${NODE_ORIGIN:+($NODE_ORIGIN)} $( [ -n "${RUN_NODE:-}" ] && "$RUN_NODE" -v 2>/dev/null || true)"
  log "${C_DIM}home${C_OFF}      ${HOME:-}"
  log "${C_DIM}workspace${C_OFF} $WORKSPACE"
  log ""
  log "${C_BOLD}engines${C_OFF}"
  list_engines
  log ""
  log "${C_BOLD}storage${C_OFF}"
  log "  data      $(du -sh "$DATA" 2>/dev/null | awk '{print $1}')"
  log "  runtimes  $(du -sh "$RUNTIMES" 2>/dev/null | awk '{print $1}')"
  log "  free      $(df -h "$ROOT" 2>/dev/null | awk 'NR==2{print $4}')"
  log ""
  log "${C_BOLD}capabilities${C_OFF}"
  log "  terminal shell   $(have sh && echo yes || echo no)"
  log "  curl/wget        $(have curl || have wget && echo yes || echo no)"
  log "  sha256           $(have sha256sum || have shasum && echo yes || echo no)"
  log "  glibc sandbox    $(proot_rootfs && echo "present ($ROOT/runtimes/proot/ubuntu)" || echo "missing (--proot)")"
  log "  imported creds   $(creds_count) file(s) in data/home"
  printf '\n'
}

creds_count() {
  n=0
  for f in "$HOME/.claude.json" "$HOME/.codex/auth.json" "$HOME/.gemini/oauth_creds.json" "$HOME/.config/opencode/opencode.json"; do
    [ -f "$f" ] && n=$((n+1))
  done
  echo "$n"
}

cmd_import() {
  counts=0
  [ "${WITH_MCP:-0}" = "1" ] && MCP_SRC="$DATA/../../.antigem_bridge/opencode/mcp_servers.json" || MCP_SRC=""
  info "Importing agent credentials from $HOST_HOME into $HOME"
  import_one() {
    src=$1; dst=$2
    [ -f "$src" ] || return 0
    if [ "${DRY_RUN:-0}" = "1" ]; then log "  would copy ${src#$HOST_HOME/}"; return 0; fi
    mkdir -p "$(dirname -- "$dst")"
    cp -f "$src" "$dst" && log "  ${C_GREEN}copied${C_OFF} ${src#$HOST_HOME/}"
    counts=$((counts+1))
  }
  import_one "$HOST_HOME/.claude.json"                    "$HOME/.claude.json"
  import_one "$HOST_HOME/.claude/settings.json"           "$HOME/.claude/settings.json"
  import_one "$HOST_HOME/.codex/config.toml"              "$HOME/.codex/config.toml"
  import_one "$HOST_HOME/.codex/auth.json"                "$HOME/.codex/auth.json"
  import_one "$HOST_HOME/.gemini/oauth_creds.json"        "$HOME/.gemini/oauth_creds.json"
  import_one "$HOST_HOME/.gemini/settings.json"           "$HOME/.gemini/settings.json"
  import_one "$HOST_HOME/.config/opencode/opencode.json"  "$HOME/.config/opencode/opencode.json"
  if [ -n "$MCP_SRC" ]; then import_one "$MCP_SRC" "$HOME/.config/opencode/mcp_servers.json"; fi
  [ "${DRY_RUN:-0}" = "1" ] || ok "Imported $counts file(s). Credentials are copied, not moved — host installs keep working."
}

cmd_update() {
  detect_platform
  download_node
}

cmd_proot() {
  info "installing glibc sandbox for $TARGET"
  exec /bin/sh "$ROOT/scripts/proot.sh" install
}

cmd_list() {
  log "${C_BOLD}detected engines${C_OFF} ($TARGET · $(libc_kind))"
  list_engines
}

cmd_exec() {
  cmd=$1
  info "portable shell: HOME=$HOME"
  if [ "${DRY_RUN:-0}" = "1" ]; then log "would run: $cmd"; return; fi
  cd "$WORKSPACE"
  sh -c "$cmd"
}

cmd_serve() {
  port=${1:-${ANTIGEM_PORT:-8787}}
  bind=${ANTIGEM_BIND:-127.0.0.1}
  have python3 || die "the web face needs python3 (pkg install python / apt install python3)"
  [ -f "$ROOT/scripts/serve.py" ] || die "scripts/serve.py is missing from this checkout"
  info "AntiGem web face  ·  http://$bind:$port"
  log "${C_DIM}workspace: $WORKSPACE${C_OFF}"
  log "${C_DIM}ctrl-c to stop${C_OFF}"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    log "would run: python3 '$ROOT/scripts/serve.py' --port $port --host $bind --workspace '$WORKSPACE'"
    return
  fi
  if [ "${AUTO_LAUNCH_BROWSER:-0}" = "1" ]; then
    ( sleep 1
      for b in xdg-open open termux-open-url sensible-browser; do
        have "$b" && { "$b" "http://127.0.0.1:$port" >/dev/null 2>&1; break; }
      done ) &
  fi
  python3 "$ROOT/scripts/serve.py" --port "$port" --host "$bind" --workspace "$WORKSPACE" || true
}

cmd_menu() {
  printf '\n%s%s%s\n' "$C_BOLD" "$APP_NAME $VERSION" "$C_OFF"
  printf '%s%s · %s · node %s%s\n\n' "$C_DIM" "$TARGET" "$(libc_kind)" "${RUN_NODE:-none}" "$C_OFF"
  while :; do
    printf '%s1)%s Workspace — start an agent      %s4)%s Import host credentials\n' "$C_CYAN" "$C_OFF" "$C_CYAN" "$C_OFF"
    printf '%s2)%s Doctor    — environment report   %s5)%s Update portable Node\n' "$C_CYAN" "$C_OFF" "$C_CYAN" "$C_OFF"
    printf '%s3)%s Terminal  — portable shell      %s6)%s Web face — open in a browser\n' "$C_CYAN" "$C_OFF" "$C_CYAN" "$C_OFF"
    printf '                                    %s7)%s Quit\n\n' "$C_CYAN" "$C_OFF"
    printf 'choice> '
    read -r choice || exit 0
    case "$choice" in
      1) printf 'agent [claude/codex/agy/opencode] (%s)> ' "$ANTIGEM_AGENT"; read -r a || exit 0
         [ -n "$a" ] || a=$ANTIGEM_AGENT
         start_agent "$a" ;;
      2) cmd_doctor ;;
      3) ( cd "$WORKSPACE" && exec "${SHELL:-sh}" ) ;;
      4) cmd_import; cmd_doctor | tail -3 ;;
      5) cmd_update ;;
      6) printf 'port (%s)> ' "${ANTIGEM_PORT:-8787}"; read -r p || exit 0
         cmd_serve "${p:-${ANTIGEM_PORT:-8787}}" ;;
      7|q|quit|exit) exit 0 ;;
      *) warn "unknown choice: $choice" ;;
    esac
    printf '\n'
  done
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------
CMD="menu"
AGENT_ARG=""
EXEC_ARG=""
WORKSPACE_OVERRIDE=""
DRY_RUN=0
NO_ISOLATE=0
SERVE_PORT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --menu)      CMD="menu" ;;
    --doctor)    CMD="doctor" ;;
    --list)      CMD="list" ;;
    --update)    CMD="update" ;;
    --import)    CMD="import" ;;
    --proot)     CMD="proot" ;;
    --serve)     CMD="serve"
                 case "${2:-}" in ''|--*|[!0-9]*) SERVE_PORT="" ;; *) SERVE_PORT=$2; shift ;; esac ;;
    --agent)     CMD="agent"; AGENT_ARG=${2:?--agent needs a name}; shift ;;
    --exec)      CMD="exec";  EXEC_ARG=${2:?--exec needs a command}; shift ;;
    --workspace) WORKSPACE_OVERRIDE=${2:?--workspace needs a path}; shift ;;
    --no-isolate) NO_ISOLATE=1 ;;
    --with-mcp)  WITH_MCP=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    -h|--help)   usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

detect_platform
capture_host
load_config
export DRY_RUN NO_ISOLATE
isolate_home
ensure_node
resolve_workspace

case "$CMD" in
  doctor) cmd_doctor ;;
  list)   cmd_list ;;
  update) cmd_update ;;
  proot)  cmd_proot ;;
  serve)  cmd_serve "${SERVE_PORT:-${ANTIGEM_PORT:-8787}}" ;;
  import) cmd_import; cmd_doctor | sed -n '/imported creds/p' ;;
  agent)  start_agent "$AGENT_ARG" ;;
  exec)   cmd_exec "$EXEC_ARG" ;;
  menu)
    if [ -t 0 ]; then cmd_menu; else cmd_doctor; fi ;;
esac
