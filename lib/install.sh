# shellcheck shell=bash
# Install pinned upstream binaries into $ULA_OPT. Nothing here needs root.
#
# NOTE: under `set -o pipefail`, never let a reader exit early (awk exit, head, grep -q) on a
# pipe: the writer dies of SIGPIPE and the whole pipeline reports failure.

BINARIES="$ULA_ROOT/catalog/binaries.tsv"
OPENCODE_BIN() { echo "$ULA_BIN_DIR/opencode"; }

# version_ge A B  -> true if A >= B (dotted numeric)
version_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    na=split(a,x,"."); nb=split(b,y,"."); n=(na>nb)?na:nb
    for(i=1;i<=n;i++){ if((x[i]+0)>(y[i]+0)) exit 0; if((x[i]+0)<(y[i]+0)) exit 1 }
    exit 0 }'
}

# sha256 pinned in catalog/binaries.tsv. Fails closed: no pin -> no install (ULA_VERIFY=0 overrides).
pinned_sha() {
  local s; s="$(awk -F'|' -v a="$1" '!/^#/ && $1==a {print $2}' "$BINARIES")"
  if [ -z "$s" ] && [ "${ULA_VERIFY:-1}" != 0 ]; then
    die "no pinned sha256 for $1 in catalog/binaries.tsv (you changed a pinned version? add its hash, or set ULA_VERIFY=0 to install unverified)"
  fi
  printf '%s' "$s"
}

# Extract archive $1 into a fresh directory $2 (staged, then renamed: no half-installed dirs).
# A single top-level folder in the archive is flattened. Extra archives ($3...) are merged in.
extract_into() {
  local dest="$1"; shift
  local stage="$dest.partial.$$" tmp arc entries
  rm -rf "$stage"; mkdir -p "$stage"
  for arc in "$@"; do
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/ula.XXXXXX")"
    case "$arc" in
      *.zip) have unzip || die "unzip is required"; unzip -q "$arc" -d "$tmp" ;;
      *) tar -xzf "$arc" -C "$tmp" ;;
    esac
    entries="$(ls -A "$tmp")"
    if [ "$(printf '%s\n' "$entries" | wc -l | tr -d ' ')" = 1 ] && [ -d "$tmp/$entries" ]; then
      cp -R "$tmp/$entries/." "$stage/"
    else
      cp -R "$tmp/." "$stage/"
    fi
    rm -rf "$tmp"
  done
  rm -rf "$dest"; mkdir -p "$(dirname "$dest")"; mv "$stage" "$dest"
}

glibc_minor() { getconf GNU_LIBC_VERSION 2>/dev/null | awk '{split($2,v,"."); print v[2]+0}' || true; }

llama_flavor() {
  local accel f; accel="$(detect_accel)"
  if [ "$ULA_OS" = macos ]; then echo "macos-$ULA_ARCH"; return; fi
  case "$(ldd --version 2>&1 || true)" in *musl*|*MUSL*)
    die "musl libc (Alpine) can't run the prebuilt llama.cpp binaries; use a glibc distro (Debian/Ubuntu/Fedora/Arch)" ;;
  esac
  case "$accel" in
    cuda)
      local cm; cm="$(cuda_driver_major)"
      if [ "$cm" -ge 13 ]; then f="ubuntu-cuda-13.5-$ULA_ARCH"
      elif [ "$cm" -ge 12 ] && [ "$ULA_ARCH" = x64 ]; then f="ubuntu-cuda-12.8-x64"
      else warn "NVIDIA driver too old for the prebuilt CUDA builds (CUDA $cm); falling back to Vulkan"; f="ubuntu-vulkan-$ULA_ARCH"; fi ;;
    rocm) if [ "$ULA_ARCH" = x64 ]; then f="ubuntu-rocm-10.0-x64"; else f="ubuntu-vulkan-$ULA_ARCH"; fi ;;
    vulkan) f="ubuntu-vulkan-$ULA_ARCH" ;;
    *) f="ubuntu-$ULA_ARCH" ;;
  esac
  # Only the x64 CPU/Vulkan builds are made on Ubuntu 22.04; arm64, CUDA and ROCm need glibc >= 2.38.
  local g; g="$(glibc_minor)"; g="${g:-0}"
  case "$f" in ubuntu-x64|ubuntu-vulkan-x64) ;; *)
    if [ "$g" -gt 0 ] && [ "$g" -lt 38 ]; then
      if [ "$ULA_ARCH" = x64 ]; then
        warn "glibc 2.$g is older than 2.38, which $f needs (Ubuntu 24.04+/Debian 13+); using ubuntu-vulkan-x64"
        f=ubuntu-vulkan-x64
      else
        die "prebuilt llama.cpp for linux-arm64 needs glibc >= 2.38 (Ubuntu 24.04+/Debian 13+); this system has 2.$g"
      fi
    fi ;;
  esac
  echo "$f"
}

install_llama_cpp() {
  local tag="$ULA_LLAMA_CPP_TAG" flavor dest asset base
  flavor="${ULA_LLAMA_FLAVOR:-$(llama_flavor)}"
  dest="$ULA_OPT/llama.cpp/$tag-$flavor"
  base="https://github.com/ggml-org/llama.cpp/releases/download/$tag"
  if [ -x "$dest/llama-server" ]; then
    info "llama.cpp $tag ($flavor) already installed"
  else
    log "installing llama.cpp $tag ($flavor)"
    asset="llama-$tag-bin-$flavor.tar.gz"
    download "$base/$asset" "$ULA_HOME/cache/$asset" "$(pinned_sha "$asset")"
    set -- "$ULA_HOME/cache/$asset"
    case "$flavor" in *cuda*)
      local cr="cudart-llama-$tag-bin-$flavor.tar.gz"
      download "$base/$cr" "$ULA_HOME/cache/$cr" "$(pinned_sha "$cr")"
      set -- "$@" "$ULA_HOME/cache/$cr" ;;
    esac
    extract_into "$dest" "$@"
    [ -x "$dest/llama-server" ] || { rm -rf "$dest"; die "llama-server not found after extracting $asset"; }
    rm -f "$@"
  fi
  ln -sfn "$dest" "$ULA_OPT/llama.cpp/current"
  check_llama_libs "$dest/llama-server"
  local vout
  if ! vout="$("$dest/llama-server" --version 2>&1)"; then
    die "llama-server cannot run on this system: $(printf '%s\n' "$vout" | tail -n 3 | tr '\n' ' ')"
  fi
  printf '%s\n' "$vout" | grep -i 'version' | sed 's/^/    /' >&2 || true
}

# Prebuilt Linux binaries link system libraries (OpenMP, Vulkan loader) that minimal installs
# lack, and need a recent glibc. Say exactly what is wrong instead of failing later with a 500.
check_llama_libs() {
  [ "$ULA_OS" = linux ] || return 0
  have ldd || return 0
  local out ver missing pkgs="" lib
  out="$(ldd "$1" 2>&1 || true)"
  ver="$(printf '%s\n' "$out" | sed -n "s/.*version \`\([^']*\)' not found.*/\1/p" | sort -u | tr '\n' ' ')"
  [ -z "$ver" ] || die "llama-server needs newer system libraries ($ver); use a newer distro (Ubuntu 24.04+) or ULA_LLAMA_FLAVOR=ubuntu-x64 / ubuntu-vulkan-x64"
  missing="$(printf '%s\n' "$out" | awk '/=> not found/ {print $1}' | sort -u)"
  [ -n "$missing" ] || return 0
  for lib in $missing; do
    case "$lib" in
      libgomp.so*)   pkgs="$pkgs libgomp" ;;
      libvulkan.so*) pkgs="$pkgs vulkan" ;;
      libcuda.so*)   pkgs="$pkgs nvidia-driver" ;;
      *)             pkgs="$pkgs $lib" ;;
    esac
  done
  local hint="" p
  for p in $pkgs; do
    case "$p" in
      libgomp) if have apt-get; then hint="$hint libgomp1"; elif have pacman; then hint="$hint gcc-libs"; else hint="$hint libgomp"; fi ;;
      vulkan)  if have apt-get; then hint="$hint libvulkan1"; else hint="$hint vulkan-loader"; fi ;;
    esac
  done
  local cmd=""
  if [ -n "$hint" ]; then
    if have apt-get; then cmd="sudo apt-get install -y$hint"
    elif have dnf; then cmd="sudo dnf install -y$hint"
    elif have pacman; then cmd="sudo pacman -S --needed$hint"
    elif have zypper; then cmd="sudo zypper install -y$hint"; fi
  fi
  die "llama-server is missing system libraries: $(echo $missing).${cmd:+ Install them with:  $cmd  and re-run.}"
}

install_llama_swap() {
  local v="$ULA_LLAMA_SWAP_VER" os arch asset dest="$ULA_OPT/llama-swap/$ULA_LLAMA_SWAP_VER"
  if [ -x "$dest/llama-swap" ]; then info "llama-swap v$v already installed"
  else
    log "installing llama-swap v$v"
    os=darwin; [ "$ULA_OS" = linux ] && os=linux
    arch=arm64; [ "$ULA_ARCH" = x64 ] && arch=amd64
    asset="llama-swap_${v}_${os}_${arch}.tar.gz"
    download "https://github.com/mostlygeek/llama-swap/releases/download/v$v/$asset" "$ULA_HOME/cache/$asset" "$(pinned_sha "$asset")"
    extract_into "$dest" "$ULA_HOME/cache/$asset"
    rm -f "$ULA_HOME/cache/$asset"
    [ -x "$dest/llama-swap" ] || die "llama-swap binary not found in $asset"
  fi
  ln -sfn "$dest" "$ULA_OPT/llama-swap/current"
}

opencode_version() {
  "${1:-$(OPENCODE_BIN)}" --version 2>/dev/null | sed -n 's/[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | awk 'NR==1' || true
}

# ula always runs its own pinned OpenCode ($ULA_BIN_DIR/opencode); an older v1 or a newer
# major elsewhere on PATH can't misread the generated v2 config.
install_opencode() {
  local want="$ULA_OPENCODE_VER" have_v dest="$ULA_OPT/opencode/$ULA_OPENCODE_VER" asset os
  have_v="$(opencode_version)"
  if [ "$have_v" = "$want" ] && [ -x "$dest/opencode" ]; then info "opencode $have_v already installed"; return; fi
  if [ "$ULA_OS" = macos ]; then asset="opencode-darwin-$ULA_ARCH.zip"
  else
    os="linux-$ULA_ARCH"
    if [ "$ULA_ARCH" = x64 ] && ! grep -q avx2 /proc/cpuinfo 2>/dev/null; then os="$os-baseline"; fi
    case "$(ldd --version 2>&1 || true)" in *musl*|*MUSL*) os="$os-musl" ;; esac
    asset="opencode-$os.tar.gz"
  fi
  log "installing opencode v$want ($asset)"
  download "https://github.com/anomalyco/opencode/releases/download/v$want/$asset" "$ULA_HOME/cache/$asset" "$(pinned_sha "$asset")"
  extract_into "$dest" "$ULA_HOME/cache/$asset"
  rm -f "$ULA_HOME/cache/$asset"
  local bin; bin="$(find "$dest" -type f -name opencode | awk 'NR==1')"
  [ -n "$bin" ] || die "opencode binary not found in $asset"
  chmod +x "$bin"
  [ "$bin" = "$dest/opencode" ] || ln -sfn "$bin" "$dest/opencode"
  mkdir -p "$ULA_BIN_DIR"; ln -sfn "$dest/opencode" "$(OPENCODE_BIN)"
  have_v="$(opencode_version)"
  [ "$have_v" = "$want" ] || die "installed opencode reports version '${have_v:-?}', expected $want"
  local other; other="$(command -v opencode 2>/dev/null || true)"
  if [ -n "$other" ] && [ "$other" != "$(OPENCODE_BIN)" ]; then
    info "note: '$other' comes first on PATH ($(opencode_version "$other")); 'ula agent' always uses $(OPENCODE_BIN)"
  fi
}

# superpowers as a local OpenCode plugin directory (no git needed, pinned to a commit so
# OpenCode treats it as immutable and never auto-updates it).
SUPERPOWERS_DIR() { echo "$ULA_OPT/superpowers/$ULA_SUPERPOWERS_REF"; }
install_superpowers() {
  [ "${ULA_SUPERPOWERS:-1}" = 1 ] || return 0
  local d a; d="$(SUPERPOWERS_DIR)"; a="superpowers-$ULA_SUPERPOWERS_REF.tar.gz"
  if [ -f "$d/index.js" ]; then info "superpowers ${ULA_SUPERPOWERS_TAG} already installed"; return; fi
  log "installing superpowers ${ULA_SUPERPOWERS_TAG} (${ULA_SUPERPOWERS_REF:0:8})"
  download "https://github.com/obra/superpowers/archive/$ULA_SUPERPOWERS_REF.tar.gz" "$ULA_HOME/cache/$a" "$(pinned_sha "$a")"
  extract_into "$d" "$ULA_HOME/cache/$a"
  rm -f "$ULA_HOME/cache/$a"
  [ -f "$d/index.js" ] || die "superpowers archive has no index.js"
}
