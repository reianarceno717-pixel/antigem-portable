#!/bin/sh
# ============================================================================
#  AntiGem Portable — proot glibc sandbox
#  Some engines (notably the upstream opencode build) are glibc binaries and
#  cannot execute on Termux/bionic. This keeps a self-contained Ubuntu rootfs
#  inside runtimes/proot/ so those engines still run from this folder.
# ============================================================================
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
ROOTFS="$ROOT/runtimes/proot/ubuntu"
PKG="$ROOT/packages"
UBUNTU_REL="24.04.5"

ESC=$(printf '\033')
C_GREEN="$ESC[32m"; C_CYAN="$ESC[36m"; C_YELLOW="$ESC[33m"; C_RED="$ESC[31m"; C_OFF="$ESC[0m"
info() { printf '%s%s%s\n' "$C_CYAN" "$*" "$C_OFF"; }
ok()   { printf '%s%s%s\n' "$C_GREEN" "$*" "$C_OFF"; }
warn() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_OFF" >&2; }
die()  { printf '%s%s%s\n' "$C_RED" "$*" "$C_OFF" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

arch() {
  case "$(uname -m)" in
    aarch64|arm64) echo arm64 ;;
    x86_64|amd64)  echo amd64 ;;
    *) die "unsupported CPU: $(uname -m)" ;;
  esac
}

url() { echo "https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-$UBUNTU_REL-base-$(arch).tar.gz"; }

need_proot() {
  have proot || die "proot not found — install it with: pkg install proot"
}

cmd_install() {
  need_proot
  if [ -x "$ROOTFS/bin/sh" ]; then ok "rootfs already present: $ROOTFS"; return; fi
  mkdir -p "$PKG" "$ROOTFS"
  tarball="$PKG/ubuntu-base.tar.gz"
  info "Downloading Ubuntu $UBUNTU_REL base rootfs (~30 MB)…"
  if have curl; then curl -fL --retry 3 -C - -o "$tarball.part" "$(url)"
  else wget -c -O "$tarball.part" "$(url)"; fi
  mv -f "$tarball.part" "$tarball"
  info "Extracting…"
  # --hard-dereference: Android's /data often refuses hard links; copy instead
  tar -xzf "$tarball" -C "$ROOTFS" --hard-dereference 2>/dev/null || \
    tar -xzf "$tarball" -C "$ROOTFS" 2>/dev/null || true
  rm -f "$tarball"
  [ -x "$ROOTFS/bin/sh" ] || die "extraction failed"
  # resolv.conf + markers so apt/curl work inside the sandbox
  cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$ROOTFS/etc/resolv.conf"
  printf 'antigem-portable\n' > "$ROOTFS/etc/hostname"
  ok "Ubuntu rootfs ready: $ROOTFS ($(du -sh "$ROOTFS" | awk '{print $1}'))"
}

# run a command inside the rootfs with the portable env
cmd_run() {
  need_proot
  [ -x "$ROOTFS/bin/sh" ] || die "no rootfs yet — run: $0 install"
  data="$ROOT/data"
  mkdir -p "$data/home" "$data/tmp"
  exec proot \
    --link2symlink -0 \
    -r "$ROOTFS" \
    -b /dev -b /proc -b /sys -b /data -b /sdcard \
    -b "$data/home:/root" \
    -w /root \
    /usr/bin/env -i \
      HOME=/root \
      TMPDIR=/root/.tmp \
      ANTIGEM_PORTABLE=1 \
      TERM="${TERM:-xterm-256color}" \
      LANG="${LANG:-C.UTF-8}" \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      "$@"
}

# install opencode inside the rootfs: reuse the host glibc build when present
cmd_opencode() {
  cmd_install
  bin_in="$ROOTFS/usr/local/bin/opencode"
  if [ ! -x "$bin_in" ]; then
    host_bin=""
    for c in "${ANTIGEM_HOST_HOME:-}/.opencode/bin/opencode" "${HOME:-}/.opencode/bin/opencode" "$(command -v opencode || true)"; do
      [ -n "$c" ] && [ -x "$c" ] && { host_bin="$c"; break; }
    done
    if [ -n "$host_bin" ]; then
      info "Reusing host opencode binary: $host_bin"
      mkdir -p "$ROOTFS/usr/local/bin"
      cp -f "$host_bin" "$bin_in"
    else
      info "Installing opencode inside the rootfs…"
      run_root /bin/sh -c 'set -e; apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ca-certificates curl xz-utils unzip >/dev/null; curl -fsSL https://opencode.ai/install | bash'
      return 0
    fi
    chmod +x "$bin_in"
  fi
  exec "$0" run /usr/local/bin/opencode "$@"
}

run_root() {
  exec proot --link2symlink -0 -r "$ROOTFS" -b /dev -b /proc -b /sys -b /data \
    -w /root /usr/bin/env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TERM="${TERM:-xterm-256color}" "$@"
}

cmd_shell() { cmd_run /bin/bash -l; }

cmd_status() {
  if [ -x "$ROOTFS/bin/sh" ]; then
    ok "rootfs: $ROOTFS ($(du -sh "$ROOTFS" | awk '{print $1}'))"
    cmd_run /bin/sh -c 'cat /etc/os-release | head -2' || true
  else
    warn "rootfs: not installed (run: $0 install)"
  fi
  if [ -x "$ROOTFS/usr/local/bin/opencode" ]; then ok "opencode: present in rootfs"; else warn "opencode: not installed in rootfs"; fi
}

case "${1:---help}" in
  install)  cmd_install ;;
  run)      shift; cmd_run "$@" ;;
  opencode) shift; cmd_opencode "$@" ;;
  shell)    cmd_shell ;;
  status)   cmd_status ;;
  *) cat <<EOF
usage: ${0##*/} <command>
  install          download + extract the Ubuntu rootfs (~30 MB)
  run CMD…         run a command inside the rootfs
  opencode         run opencode inside the rootfs (reuses the host glibc build)
  shell            interactive bash inside the rootfs
  status           what is installed
EOF
  ;;
esac
