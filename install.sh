#!/usr/bin/env bash
# uncensored-local-agent installer for macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/mark-ssd/uncensored-local-agent/v0.1.0/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --profile mac-24gb --all-models
#   ./install.sh [--profile P] [--all-models|--no-models] [--no-service] [--no-superpowers]
#
# Installs (no root needed): llama.cpp (pinned release), llama-swap, OpenCode, the models of
# the hardware profile, a per-user service for the router, and the `ula` CLI in ~/.local/bin.
set -euo pipefail

REPO_URL="${ULA_REPO_URL:-https://github.com/mark-ssd/uncensored-local-agent}"
REF="${ULA_REF:-v0.1.0}"   # pinned release; ULA_REF=main for the development branch
HOME_DIR="${ULA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/ula}"

here=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
fi

for t in curl tar gzip uname awk sed cut find mktemp od; do
  command -v "$t" >/dev/null 2>&1 || { echo "error: '$t' is required" >&2; exit 1; }
done

if [ -n "$here" ] && [ -f "$here/lib/common.sh" ] && [ -x "$here/bin/ula" ]; then
  root="$here"
else
  root="$HOME_DIR/repo"
  echo "==> fetching uncensored-local-agent ($REF) into $root" >&2
  if command -v git >/dev/null 2>&1; then
    if [ -d "$root/.git" ]; then git -C "$root" fetch -q --depth 1 origin "$REF" && git -C "$root" checkout -q FETCH_HEAD
    else rm -rf "$root"; mkdir -p "$(dirname "$root")"; git clone -q --depth 1 --branch "$REF" "$REPO_URL" "$root"; fi
  else
    rm -rf "$root"; mkdir -p "$root"
    curl -fsSL "$REPO_URL/archive/$REF.tar.gz" | tar -xz -C "$root" --strip-components 1
  fi
fi

exec bash "$root/bin/ula" setup "$@"
