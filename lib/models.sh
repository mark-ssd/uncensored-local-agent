# shellcheck shell=bash
# Catalog + profile handling.

CATALOG="$ULA_ROOT/catalog/models.tsv"

# catalog_field ID N  -> field N (1-based) of the catalog row for ID
catalog_field() {
  awk -F'|' -v id="$1" -v n="$2" '!/^#/ && $1==id {print $n; found=1; exit} END{if(!found) exit 1}' "$CATALOG"
}
catalog_has() { catalog_field "$1" 1 >/dev/null 2>&1; }

# Profile entries, one per line: alias|catalog_id|ctx|extra args
profile_entries() {
  printf '%s\n' "$ULA_MODELS" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' | grep -v '^#' |
    while IFS= read -r line; do
      local alias="${line%%=*}" rest="${line#*=}" id ctx extra
      id="${rest%%@*}"; rest="${rest#"$id"}"; rest="${rest#@}"
      ctx="${rest%%@*}"; extra=""
      case "$rest" in *@*) extra="${rest#*@}" ;; esac
      [ -n "$ctx" ] || ctx=8192
      printf '%s|%s|%s|%s\n' "$alias" "$id" "$ctx" "$extra"
    done
}

entry_for_alias() { profile_entries | awk -F'|' -v a="$1" '!f && $1==a {print; f=1}'; }   # no early exit: SIGPIPE + pipefail would abort the caller
profile_aliases() { profile_entries | cut -d'|' -f1; }

model_path() { echo "$ULA_MODELS_DIR/$(catalog_field "$1" 4)"; }
model_installed() { [ -f "$(model_path "$1")" ]; }

load_profile() {
  local name="$1" f="$ULA_ROOT/profiles/$1.env"
  [ -f "$f" ] || die "unknown profile '$name' (see: ls $ULA_ROOT/profiles)"
  ULA_MODELS=""; ULA_DEFAULT=""; ULA_GPU_ARGS=""; ULA_SWAP_LLMS=true; ULA_TTL=900; ULA_MIN_DISK_GIB=5
  ULA_CODER=coder; ULA_ARCHITECT=architect; PROFILE_DESC=""; ULA_SERVER_ENV=""; ULA_CHAT_ARGS="--cache-ram 4096"
  # shellcheck disable=SC1090
  . "$f"
  ULA_PROFILE="$name"
  local a id
  for a in $(profile_aliases); do
    id="$(entry_for_alias "$a" | cut -d'|' -f2)"
    catalog_has "$id" || die "profile $name: alias '$a' references unknown catalog id '$id'"
  done
}

# Pick a profile for this machine. Explicit ULA_PROFILE / --profile always wins.
auto_profile() {
  local mem accel vram
  mem="$(mem_gib)"; accel="$(detect_accel)"
  if [ "$ULA_OS" = macos ] && [ "$ULA_ARCH" = arm64 ]; then
    if   [ "$mem" -ge 120 ]; then echo mac-128gb
    elif [ "$mem" -ge 60 ];  then echo mac-64gb
    elif [ "$mem" -ge 34 ];  then echo mac-36gb
    elif [ "$mem" -ge 22 ];  then echo mac-24gb
    elif [ "$mem" -ge 15 ];  then echo mac-16gb
    else echo tiny; fi
    return
  fi
  if [ "$accel" = cuda ]; then
    vram="$(nvidia_vram_gib)"
    if   [ "$vram" -ge 90 ]; then echo gpu-96gb; return
    elif [ "$vram" -ge 44 ]; then echo gpu-48gb; return
    elif [ "$vram" -ge 30 ]; then echo gpu-32gb; return
    elif [ "$vram" -ge 22 ]; then echo gpu-24gb; return
    elif [ "$vram" -ge 14 ]; then echo gpu-16gb; return
    fi
  fi
  # CPU / Vulkan / ROCm / Intel Macs: size by RAM. unified-128gb needs a GPU backend (Strix Halo, DGX Spark).
  if   [ "$mem" -ge 110 ] && [ "$accel" != cpu ]; then echo unified-128gb
  elif [ "$mem" -ge 60 ];  then echo cpu-64gb
  elif [ "$mem" -ge 30 ];  then echo cpu-32gb
  elif [ "$mem" -ge 15 ];  then echo cpu-16gb
  else echo tiny; fi
}

# Aliases selected for download: "default" | "all" | explicit list
selected_aliases() {
  case "${1:-default}" in
    all) profile_aliases ;;
    default) printf '%s\n' $ULA_DEFAULT ;;
    *) printf '%s\n' "$@" ;;
  esac
}

# Unique catalog ids for a list of aliases (stdin)
ids_for_aliases() {
  while read -r a; do
    [ -n "$a" ] || continue
    local e; e="$(entry_for_alias "$a")"
    [ -n "$e" ] || die "alias '$a' is not in profile $ULA_PROFILE (aliases: $(profile_aliases | tr '\n' ' '))"
    echo "$e" | cut -d'|' -f2
  done | awk '!seen[$0]++'
}

pull_models() {
  local ids id total=0 bytes need free
  ids="$(selected_aliases "$@" | ids_for_aliases)" || exit 1
  for id in $ids; do
    model_installed "$id" && continue
    bytes="$(catalog_field "$id" 5)"; total=$((total + bytes / 1000000))
  done
  mkdir -p "$ULA_MODELS_DIR"
  need=$(( total / 1074 + ULA_MIN_DISK_GIB ))
  free="$(free_gib "$ULA_MODELS_DIR")"
  if [ "$total" -gt 0 ] && [ "$free" -lt "$need" ]; then
    die "not enough disk: need ~${need} GiB free in $ULA_MODELS_DIR (incl. ${ULA_MIN_DISK_GIB} GiB headroom), have ${free} GiB. Free space or set ULA_MODELS_DIR to a bigger disk."
  fi
  # Hugging Face throttles single connections; parallel files are several times faster.
  local jobs="${ULA_JOBS:-4}" pids="" n=0 failed=0 p
  [ "$jobs" -gt 1 ] && ULA_CURL_OPTS="${ULA_CURL_OPTS:-} -sS"
  for id in $ids; do
    local repo file sha
    repo="$(catalog_field "$id" 3)"; file="$(catalog_field "$id" 4)"
    sha="$(catalog_field "$id" 6)"; bytes="$(catalog_field "$id" 5)"
    if model_installed "$id" && [ "${ULA_REVERIFY:-0}" != 1 ]; then
      info "ok      $file"
      continue
    fi
    log "downloading $file ($(human_gb "$bytes")) from huggingface.co/$repo"
    if [ "$jobs" -le 1 ]; then
      download "https://huggingface.co/$repo/resolve/main/$file" "$ULA_MODELS_DIR/$file" "$sha"
      continue
    fi
    ( download "https://huggingface.co/$repo/resolve/main/$file" "$ULA_MODELS_DIR/$file" "$sha" && info "done    $file (sha256 ok)" ) &
    pids="$pids $!"; n=$((n + 1))
    if [ "$n" -ge "$jobs" ]; then
      for p in $pids; do wait "$p" || failed=1; done
      pids=""; n=0
    fi
  done
  for p in $pids; do wait "$p" || failed=1; done
  [ "$failed" = 0 ] || die "some downloads failed; re-run 'ula pull' to resume them"
  pull_templates $ids
}

TEMPLATES="$ULA_ROOT/catalog/templates.tsv"
template_path() { echo "$ULA_HOME/templates/$1.jinja"; }

# Download chat templates referenced as {tpl:NAME} by the given catalog ids.
pull_templates() {
  local id t url sha
  for id in "$@"; do
    for t in $(catalog_field "$id" 8 | grep -o '{tpl:[a-z0-9-]*}' | sed 's/{tpl:\(.*\)}/\1/' || true); do
      url="$(awk -F'|' -v n="$t" '!/^#/ && $1==n {print $2}' "$TEMPLATES")"
      sha="$(awk -F'|' -v n="$t" '!/^#/ && $1==n {print $3}' "$TEMPLATES")"
      [ -n "$url" ] || die "catalog row $id references unknown template '$t' (catalog/templates.tsv)"
      download "$url" "$(template_path "$t")" "$sha"
    done
  done
}

# Expand {tpl:NAME} in llama-server args to the local template path.
expand_args() {
  local a="$1" t
  for t in $(printf '%s\n' "$a" | grep -o '{tpl:[a-z0-9-]*}' | sed 's/{tpl:\(.*\)}/\1/' || true); do
    a="$(printf '%s' "$a" | sed "s|{tpl:$t}|\"$(template_path "$t")\"|g")"
  done
  printf '%s' "$a"
}

# HEAD every catalog row and compare size/sha with the pinned values.
catalog_verify() {
  local out; out="$(catalog_verify_rows)"; printf '%s\n' "$out"
  case "$out" in FAIL*|*"
FAIL"*) return 1 ;; esac
}
catalog_verify_rows() {
  grep -v '^#' "$CATALOG" | grep -v '^$' | while IFS='|' read -r id kind repo file bytes sha lic args; do
    local hdr size etag code
    hdr="$(curl -sIL --max-redirs 0 "https://huggingface.co/$repo/resolve/main/$file" | tr -d '\r')"
    code="$(printf '%s\n' "$hdr" | awk '/^HTTP/{c=$2} END{print c}')"
    size="$(printf '%s\n' "$hdr" | awk 'tolower($1)=="x-linked-size:"{print $2}')"
    etag="$(printf '%s\n' "$hdr" | awk 'tolower($1)=="x-linked-etag:"{gsub(/"/,"",$2); print $2}')"
    if [ "$size" = "$bytes" ] && [ "$etag" = "$sha" ]; then
      printf 'ok    %s\n' "$id"
    else
      printf 'FAIL  %s  (http %s, size %s vs %s, sha %s)\n' "$id" "${code:-?}" "${size:-?}" "$bytes" "${etag:-?}"
    fi
  done
}
