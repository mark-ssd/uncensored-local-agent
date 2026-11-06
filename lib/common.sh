# shellcheck shell=bash
# Shared helpers. Must stay compatible with bash 3.2 (macOS /bin/bash):
# no associative arrays, no ${var,,}, no mapfile, no &>> .

ULA_VERSION="0.1.0"

# ---------- pinned upstream versions (override with env) ----------
: "${ULA_LLAMA_CPP_TAG:=b12176}"     # github.com/ggml-org/llama.cpp releases
: "${ULA_LLAMA_SWAP_VER:=270}"       # github.com/mostlygeek/llama-swap releases (tag v270)
: "${ULA_OPENCODE_VER:=2.2.5}"       # github.com/anomalyco/opencode releases (tag v2.2.5)

# superpowers v7.0.2 (tag c62ffea8) -> commit 22f0b463; a full commit makes OpenCode treat it as immutable
: "${ULA_SUPERPOWERS:=1}"
: "${ULA_SUPERPOWERS_TAG:=v7.0.2}"
: "${ULA_SUPERPOWERS_REF:=22f0b463e7a5e579904dd6211a520321035526f7}"

# ---------- paths ----------
: "${ULA_HOME:=${XDG_DATA_HOME:-$HOME/.local/share}/ula}"
: "${ULA_CONFIG:=${XDG_CONFIG_HOME:-$HOME/.config}/ula}"
: "${ULA_MODELS_DIR:=$ULA_HOME/models}"
: "${ULA_BIN_DIR:=$HOME/.local/bin}"
: "${ULA_PORT:=8090}"
: "${ULA_HOST:=127.0.0.1}"
ULA_OPT="$ULA_HOME/opt"
ULA_RUN="$ULA_HOME/run"
ULA_LOGS="$ULA_HOME/logs"
OPENCODE_CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"

# ---------- output ----------
if [ -t 2 ]; then _c_b=$'\033[1m'; _c_g=$'\033[32m'; _c_y=$'\033[33m'; _c_r=$'\033[31m'; _c_0=$'\033[0m'
else _c_b=""; _c_g=""; _c_y=""; _c_r=""; _c_0=""; fi
log()  { printf '%s==>%s %s\n' "$_c_b$_c_g" "$_c_0" "$*" >&2; }
info() { printf '    %s\n' "$*" >&2; }
warn() { printf '%swarn:%s %s\n' "$_c_y" "$_c_0" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$_c_r" "$_c_0" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ---------- platform ----------
detect_platform() {
  case "$(uname -s)" in
    Darwin) ULA_OS=macos ;;
    Linux)  ULA_OS=linux ;;
    *) die "unsupported OS: $(uname -s) (macOS and Linux only)" ;;
  esac
  case "$(uname -m)" in
    arm64|aarch64) ULA_ARCH=arm64 ;;
    x86_64|amd64)  ULA_ARCH=x64 ;;
    *) die "unsupported CPU architecture: $(uname -m)" ;;
  esac
  export ULA_OS ULA_ARCH
}

# Total system memory in whole GiB.
mem_gib() {
  if [ "$ULA_OS" = macos ]; then
    echo $(( $(sysctl -n hw.memsize) / 1073741824 ))
  else
    awk '/^MemTotal:/ {printf "%d\n", $2/1048576}' /proc/meminfo
  fi
}

# Largest single NVIDIA GPU memory in GiB, or 0.
nvidia_vram_gib() {
  have nvidia-smi || { echo 0; return; }
  nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
    | awk 'BEGIN{m=0} {v=int($1/1024); if (v>m) m=v} END{print m}'
}

# Accelerator used to pick the llama.cpp build: metal|cuda|rocm|vulkan|cpu
detect_accel() {
  if [ -n "${ULA_ACCEL:-}" ]; then echo "$ULA_ACCEL"; return; fi
  if [ "$ULA_OS" = macos ]; then
    if [ "$ULA_ARCH" = arm64 ]; then echo metal; else echo cpu; fi
    return
  fi
  if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then echo cuda; return; fi
  if [ "$ULA_ARCH" = x64 ] && { have rocminfo || [ -e /dev/kfd ]; }; then echo rocm; return; fi
  if have vulkaninfo; then
    case "$(vulkaninfo --summary 2>/dev/null || true)" in *DISCRETE_GPU*|*INTEGRATED_GPU*) echo vulkan; return ;; esac
  fi
  echo cpu
}

# Driver-reported CUDA version major (e.g. 13), or 0.
cuda_driver_major() {
  have nvidia-smi || { echo 0; return; }
  local v; v="$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: *\([0-9][0-9]*\)\..*/\1/p' | awk 'NR==1' || true)"
  echo "${v:-0}"
}

# Free disk space in GiB for the filesystem holding $1.
free_gib() {
  local p="$1"; while [ ! -d "$p" ]; do p="$(dirname "$p")"; done
  df -Pk "$p" | awk 'NR==2 {printf "%d\n", $4/1048576}'
}

sha256_of() {
  if have sha256sum; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# download URL DEST [SHA256]  -- resumable, verified, atomic.
download() {
  local url="$1" dest="$2" sha="${3:-}" part="$2.part" got
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ]; then
    if [ -z "$sha" ] || [ "${ULA_VERIFY:-1}" = 0 ]; then return 0; fi
    got="$(sha256_of "$dest")"
    [ "$got" = "$sha" ] && return 0
    warn "checksum mismatch for existing $(basename "$dest"); re-downloading"
    rm -f "$dest"
  fi
  local tries=0
  local progress="-sS"; [ -t 2 ] && progress="--progress-bar"
  # shellcheck disable=SC2086
  until curl -fL $progress --retry 5 --retry-delay 3 --connect-timeout 20 -C - ${ULA_CURL_OPTS:-} -o "$part" "$url"; do
    tries=$((tries + 1))
    [ "$tries" -ge 3 ] && die "download failed: $url"
    warn "download interrupted, resuming ($tries/3)"
    sleep 2
  done
  if [ -n "$sha" ] && [ "${ULA_VERIFY:-1}" != 0 ]; then
    got="$(sha256_of "$part")"
    if [ "$got" != "$sha" ]; then
      rm -f "$part"
      die "checksum mismatch for $(basename "$dest"): expected $sha, got $got (upstream file changed? re-run with ULA_VERIFY=0 to accept)"
    fi
  fi
  mv "$part" "$dest"
}

human_gb() { awk -v b="$1" 'BEGIN{printf "%.1f GB", b/1e9}'; }

# Resolve the repository root from a script path, following symlinks (no readlink -f on old macOS).
resolve_root() {
  local src="$1" dir
  while [ -h "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  dir="$(cd -P "$(dirname "$src")" && pwd)"
  (cd "$dir/.." && pwd)
}
