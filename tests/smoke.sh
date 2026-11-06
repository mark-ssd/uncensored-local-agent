#!/usr/bin/env bash
# Smoke test against the running llama-swap router.
# For every installed chat alias: plain chat, a tool call, a tool call after a late system
# message (templates that reject it break some harnesses), and the ':fast' no-thinking alias.
# For embed/rerank aliases: one embedding and one rerank request.
# Usage: tests/smoke.sh [alias...]     exit code = number of failed checks
set -uo pipefail
ULA_ROOT="${ULA_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
. "$ULA_ROOT/lib/common.sh"; . "$ULA_ROOT/lib/models.sh"
detect_platform
_port="${ULA_PORT_OVERRIDE:-}"
# shellcheck disable=SC1090
[ -f "$ULA_CONFIG/ula.env" ] && . "$ULA_CONFIG/ula.env"
[ -n "$_port" ] && ULA_PORT="$_port"
KEY="$(cat "$ULA_CONFIG/api-key" 2>/dev/null || true)"
load_profile "${ULA_PROFILE:-$(auto_profile)}"
BASE="http://$ULA_HOST:$ULA_PORT"
FAIL=0; TMP="$(mktemp -d "${TMPDIR:-/tmp}/ula-test.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
note() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

post() { # path body outfile -> prints "http_code seconds"
  curl -sS -o "$3" -w '%{http_code} %{time_total}' --max-time "${MAX_TIME:-900}" \
    -H 'Content-Type: application/json' -H "Authorization: Bearer $KEY" -d "$2" "$BASE$1" 2>/dev/null || echo "000 0"
}

TOOLS='[{"type":"function","function":{"name":"get_weather","description":"Get current weather for a city","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]'

curl -fsS --max-time 5 -H "Authorization: Bearer $KEY" "$BASE/v1/models" >/dev/null || { echo "router is not reachable at $BASE (ula up)"; exit 99; }

aliases="$*"; [ -n "$aliases" ] || aliases="$(profile_aliases)"
for a in $aliases; do
  e="$(entry_for_alias "$a")"; [ -n "$e" ] || { fail "$a: not in profile"; continue; }
  id="$(echo "$e" | cut -d'|' -f2)"; model_installed "$id" || { echo "- $a: not downloaded, skipped"; continue; }
  kind="$(catalog_field "$id" 2)"
  echo "- $a ($id)"
  case "$kind" in
  chat)
    r="$(post /v1/chat/completions "{\"model\":\"$a\",\"max_tokens\":2048,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: pong\"}]}" "$TMP/c.json")"
    if [ "${r%% *}" = 200 ] && grep -Eqi '"content":"([^"\\]|\\.)*pong' "$TMP/c.json"; then pass "chat (${r#* }s incl. load)"; else fail "chat: http ${r%% *} $(head -c 300 "$TMP/c.json")"; fi

    r="$(post /v1/chat/completions "{\"model\":\"$a\",\"max_tokens\":4096,\"tools\":$TOOLS,\"messages\":[{\"role\":\"user\",\"content\":\"What is the weather in Berlin? Use the tool.\"}]}" "$TMP/t.json")"
    if [ "${r%% *}" = 200 ] && grep -q '"finish_reason":"tool_calls"' "$TMP/t.json" && grep -q '"name":"get_weather"' "$TMP/t.json" && grep -Eqi '"arguments":"([^"\\]|\\.)*berlin' "$TMP/t.json"; then
      pass "tool call (${r#* }s)"; else fail "tool call: http ${r%% *} $(head -c 400 "$TMP/t.json")"; fi

    r="$(post /v1/chat/completions "{\"model\":\"$a\",\"max_tokens\":4096,\"tools\":$TOOLS,\"messages\":[{\"role\":\"system\",\"content\":\"You are a helpful agent.\"},{\"role\":\"user\",\"content\":\"Hi\"},{\"role\":\"assistant\",\"content\":\"Hello! How can I help?\"},{\"role\":\"system\",\"content\":\"Reminder: prefer tools when they apply.\"},{\"role\":\"user\",\"content\":\"Weather in Paris? Use the tool.\"}]}" "$TMP/s.json")"
    if [ "${r%% *}" = 200 ] && grep -q '"name":"get_weather"' "$TMP/s.json"; then pass "tool call after late system message"
    else note "late system message rejected (OpenCode/superpowers don't send these; Claude Code-style clients do): http ${r%% *} $(head -c 200 "$TMP/s.json")"; fi

    r="$(post /v1/chat/completions "{\"model\":\"$a:fast\",\"max_tokens\":256,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: pong\"}]}" "$TMP/f.json")"
    if [ "${r%% *}" = 200 ] && grep -Eqi '"content":"([^"\\]|\\.)*pong' "$TMP/f.json"; then
      if grep -q '"reasoning_content":"[^"]' "$TMP/f.json"; then pass "$a:fast (${r#* }s; model still emits some reasoning)"; else pass "$a:fast (thinking off, ${r#* }s)"; fi
    else fail "$a:fast: http ${r%% *} $(head -c 300 "$TMP/f.json")"; fi
    ;;
  embed)
    r="$(post /v1/embeddings "{\"model\":\"$a\",\"input\":[\"def add(a, b): return a + b\"]}" "$TMP/e.json")"
    if [ "${r%% *}" = 200 ] && grep -q '"embedding":\[' "$TMP/e.json"; then pass "embedding"; else fail "embedding: http ${r%% *} $(head -c 300 "$TMP/e.json")"; fi ;;
  rerank)
    r="$(post /v1/rerank "{\"model\":\"$a\",\"query\":\"how to add two numbers in python\",\"documents\":[\"The Eiffel Tower is in Paris\",\"def add(a, b): return a + b\"]}" "$TMP/r.json")"
    if [ "${r%% *}" = 200 ] && grep -q '"relevance_score"' "$TMP/r.json"; then
      # document 1 (the code) must get the highest score, whatever order results come in
      best="$(tr '{' '\n' < "$TMP/r.json" | sed -n 's/.*"index":\([0-9]*\),"relevance_score":\([-0-9.e+]*\).*/\1 \2/p' | sort -k2 -g -r | awk 'NR==1{print $1}')"
      [ "$best" = 1 ] && pass "rerank (relevant doc scored highest)" || fail "rerank order wrong: $(head -c 300 "$TMP/r.json")"
    else fail "rerank: http ${r%% *} $(head -c 300 "$TMP/r.json")"; fi ;;
  esac
done
echo; [ "$FAIL" = 0 ] && echo "all checks passed" || echo "$FAIL check(s) failed"
exit "$FAIL"
