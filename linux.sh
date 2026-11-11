#!/bin/sh
# AntiGem Portable — Linux / Termux entry point
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
exec /bin/sh "$ROOT/scripts/portable.sh" "$@"
