#!/usr/bin/env bash
# zehn installer — clone, build, and install in one shot.
#
#   bash <(curl -L https://raw.githubusercontent.com/al3rez/zehn/master/scripts/install.sh)
#
# Honors:
#   PREFIX  install prefix (default: ~/.local) — binary lands in $PREFIX/bin/zehn
set -euo pipefail

REPO="https://github.com/al3rez/zehn"
PREFIX="${PREFIX:-$HOME/.local}"

red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
info() { printf '\033[36m%s\033[0m\n' "$*"; }

if ! command -v zig >/dev/null 2>&1; then
  red "zehn needs Zig 0.16 or newer. Install it from https://ziglang.org/download/ and re-run."
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  red "git is required to fetch zehn."
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

info "Cloning $REPO ..."
git clone --depth 1 "$REPO" "$tmp/zehn"

info "Building (ReleaseFast) ..."
zig build -Doptimize=ReleaseFast --prefix "$PREFIX" --build-file "$tmp/zehn/build.zig"

bin="$PREFIX/bin/zehn"
info "Installed zehn to $bin"

case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) red "Note: $PREFIX/bin is not on your PATH. Add it, e.g.:"
     red "  export PATH=\"$PREFIX/bin:\$PATH\"" ;;
esac
