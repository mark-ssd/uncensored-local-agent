#!/usr/bin/env bash
# End-to-end test of the Linux install inside a throwaway container (needs Docker).
#   tests/docker-e2e.sh [image]      default image: ubuntu:24.04
# Installs the tiny profile as an unprivileged user, runs the smoke tests, then asks the
# OpenCode agent to create a file through the local model.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
image="${1:-ubuntu:24.04}"
exec docker run --rm -e ULA_SUPERPOWERS="${ULA_SUPERPOWERS:-0}" -v "$here:/src:ro" "$image" bash -c '
set -e
if command -v apt-get >/dev/null; then export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y -qq curl ca-certificates unzip git libgomp1 >/dev/null
elif command -v dnf >/dev/null; then dnf install -y -q curl unzip git tar gzip findutils procps-ng libgomp util-linux >/dev/null
elif command -v pacman >/dev/null; then pacman -Sy --noconfirm --quiet curl unzip git gcc-libs >/dev/null; fi
useradd -m tester; cp -r /src /home/tester/ula; chown -R tester /home/tester/ula
su tester -c "
set -e; export ULA_SUPERPOWERS=$ULA_SUPERPOWERS
cd ~/ula && ./install.sh --profile tiny
export PATH=\$HOME/.local/bin:\$PATH
ula status; ula test
if [ \"\$ULA_SUPERPOWERS\" = 1 ]; then
  ls ~/.local/share/ula/opt/superpowers/*/index.js >/dev/null && echo SUPERPOWERS-INSTALLED
  grep -q superpowers ~/.config/opencode/opencode.jsonc && echo SUPERPOWERS-IN-CONFIG
fi
d=\$(mktemp -d); cd \$d; git init -q .
ula agent run --standalone \"Create a file hello.py containing: print(\\\"hello\\\"). Use the write tool.\" || true
ls -la; test -f hello.py && echo E2E-AGENT-OK || { echo E2E-AGENT-FAILED; tail -50 ~/.local/share/ula/logs/llama-swap.log; exit 1; }
"'
