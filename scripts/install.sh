#!/usr/bin/env bash
# zehn installer — clone, build, and install in one shot.
#
#   bash <(curl -L https://al3rez.com/zehn)
#
# Honors:
#   PREFIX     install prefix (default: ~/.local) — binary lands in $PREFIX/bin/zehn
#   ZIG_MIN    minimum Zig version to accept (default: 0.16.0)
#   NO_INSTALL_ZIG=1   don't try to install Zig; just fail if it's missing/too old
set -euo pipefail

REPO="https://github.com/al3rez/zehn"
PREFIX="${PREFIX:-$HOME/.local}"
ZIG_MIN="${ZIG_MIN:-0.16.0}"

red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
info() { printf '\033[36m%s\033[0m\n' "$*"; }

need() { command -v "$1" >/dev/null 2>&1; }

# Return 0 if "$1" (x.y.z) >= "$2" (x.y.z), comparing major.minor.patch numerically.
version_ge() {
  local have="$1" want="$2" h w i
  IFS='.- ' read -r -a h <<<"$have"
  IFS='.- ' read -r -a w <<<"$want"
  for i in 0 1 2; do
    local hi="${h[i]:-0}" wi="${w[i]:-0}"
    hi="${hi//[!0-9]/}"; wi="${wi//[!0-9]/}"
    hi="${hi:-0}"; wi="${wi:-0}"
    if   ((10#$hi > 10#$wi)); then return 0
    elif ((10#$hi < 10#$wi)); then return 1
    fi
  done
  return 0
}

zig_ok() {
  need zig || return 1
  local v; v="$(zig version 2>/dev/null)" || return 1
  version_ge "$v" "$ZIG_MIN"
}

# Map uname output to Zig's release naming.
zig_platform() {
  local os arch
  case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux)  os=linux ;;
    *) red "Unsupported OS: $(uname -s). Install Zig $ZIG_MIN+ manually from https://ziglang.org/download/"; return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch=x86_64 ;;
    arm64|aarch64) arch=aarch64 ;;
    *) red "Unsupported arch: $(uname -m). Install Zig $ZIG_MIN+ manually from https://ziglang.org/download/"; return 1 ;;
  esac
  printf '%s-%s\n' "$arch" "$os"
}

# Download the official Zig tarball into $PREFIX/lib and symlink the binary.
install_zig_tarball() {
  local plat tarball url dest
  plat="$(zig_platform)" || return 1

  # Ask ziglang.org for the matching build. Prefer an exact ZIG_MIN release,
  # otherwise fall back to the current master (0.16 ships as a dev build).
  local index; index="$(curl -fsSL https://ziglang.org/download/index.json)" || {
    red "Could not reach ziglang.org to download Zig."; return 1; }

  url="$(printf '%s' "$index" | _json_tarball "$ZIG_MIN" "$plat")"
  [ -n "$url" ] || url="$(printf '%s' "$index" | _json_tarball master "$plat")"
  if [ -z "$url" ]; then
    red "No Zig build found for $plat. Install manually from https://ziglang.org/download/"; return 1
  fi

  info "Downloading Zig for $plat ..."
  tarball="$tmp/$(basename "$url")"
  curl -fSL "$url" -o "$tarball"

  dest="$PREFIX/lib/zig"
  mkdir -p "$dest" "$PREFIX/bin"
  rm -rf "$dest"/*
  tar -xf "$tarball" -C "$dest" --strip-components=1
  ln -sf "$dest/zig" "$PREFIX/bin/zig"
  info "Installed Zig to $PREFIX/bin/zig"
  export PATH="$PREFIX/bin:$PATH"
}

# Pull a tarball URL out of ziglang's index.json for a given version key + platform.
# Uses python3 if present (reliable), else jq. Prints nothing if unavailable.
_json_tarball() {
  local key="$1" plat="$2"
  if need python3; then
    python3 -c '
import json,sys
key,plat=sys.argv[1],sys.argv[2]
d=json.load(sys.stdin)
v=d.get(key) or {}
e=v.get(plat) or {}
print(e.get("tarball",""))
' "$key" "$plat"
  elif need jq; then
    jq -r --arg k "$key" --arg p "$plat" '.[$k][$p].tarball // empty'
  fi
}

ensure_zig() {
  if zig_ok; then
    info "Found Zig $(zig version)"
    return 0
  fi

  if [ "${NO_INSTALL_ZIG:-0}" = "1" ]; then
    red "Zig $ZIG_MIN+ required (found: $(zig version 2>/dev/null || echo none)). Install from https://ziglang.org/download/"
    exit 1
  fi

  info "Zig $ZIG_MIN+ not found — installing ..."

  # Try a package manager first (fast, cached), then verify the version.
  if need brew; then
    brew install zig || true
  elif need pacman; then
    sudo pacman -S --needed --noconfirm zig || true
  fi

  if zig_ok; then
    info "Found Zig $(zig version)"
    return 0
  fi

  # Package manager missing or too old (apt/dnf ship stale Zig): use the
  # official tarball, which is the only reliable source for 0.16 dev builds.
  install_zig_tarball

  if ! zig_ok; then
    red "Installed Zig is still older than $ZIG_MIN. Install manually from https://ziglang.org/download/"
    exit 1
  fi
  info "Found Zig $(zig version)"
}

need git  || { red "git is required to fetch zehn."; exit 1; }
need curl || { red "curl is required."; exit 1; }
need tar  || { red "tar is required."; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

ensure_zig

bin="$PREFIX/bin/zehn"

# If zehn is already here, this run is an upgrade: note the old version so we
# can report what changed. Re-running always rebuilds from the latest master,
# so a plain re-run is all you need to update.
old_ver=""
if [ -x "$bin" ]; then
  old_ver="$("$bin" --version 2>/dev/null | awk '{print $2}')"
  info "Found existing zehn ${old_ver:-(unknown version)} — upgrading to latest"
fi

info "Cloning $REPO ..."
git clone --depth 1 "$REPO" "$tmp/zehn"
git -C "$tmp/zehn" fetch --depth 1 origin 'refs/tags/v*:refs/tags/v*' >/dev/null 2>&1 || true

info "Building (ReleaseFast) ..."
rev="$(git -C "$tmp/zehn" rev-parse HEAD 2>/dev/null || echo unknown)"
ver="$(git -C "$tmp/zehn" describe --tags --match 'v*' --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)"
zig build -Doptimize=ReleaseFast -Dgit-rev="$rev" -Dversion="$ver" --prefix "$PREFIX" --build-file "$tmp/zehn/build.zig"

new_ver="$("$bin" --version 2>/dev/null | awk '{print $2}')"
if [ -n "$old_ver" ] && [ "$old_ver" != "$new_ver" ]; then
  info "Upgraded zehn $old_ver -> ${new_ver:-?} at $bin"
elif [ -n "$old_ver" ]; then
  info "Reinstalled zehn ${new_ver:-?} (already latest) at $bin"
else
  info "Installed zehn ${new_ver:-?} to $bin"
fi

case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) red "Note: $PREFIX/bin is not on your PATH. Add it, e.g.:"
     red "  export PATH=\"$PREFIX/bin:\$PATH\"" ;;
esac
