#!/bin/sh
# install.sh — Mirror-aware installer for nps (server) and npc (client)
#
# Usage:
#   ./install.sh [mode] [version] [install_dir]
#   mode:        npc | nps | all (default: all)
#   version:     release tag (default: latest)
#   install_dir: extract here instead of installing into /usr/bin + /etc/nps
#
# Mirrors:
#   The script probes every known download mirror in parallel (GitHub direct,
#   jsDelivr CDN edges and public GitHub proxies), then uses the fastest
#   reachable one first and falls back through the rest. No region lookup is
#   needed: the measurement itself reflects the local network.
#
# Environment:
#   NPS_MIRROR_ORDER   force a comma/space separated mirror order, e.g.
#                      "jsdelivr,ghproxy,github" (skips probing)
#   NPS_MIRRORS        override the candidate mirror list
#   NPS_MIRROR_PROBE=0 disable probing, use the built-in default order
#   NPS_PROBE_TIMEOUT  per-mirror probe timeout in seconds (default 4)
#   NPS_CONNECT_TIMEOUT connect timeout for downloads (default 10)
#   NPS_DOWNLOAD_TIMEOUT total time allowed per download (default 300)
#   NPS_INSTALL_DIR / NPS_INSTALL_MODE / NPS_INSTALL_VERSION  same as args
#   NPS_IPV4=1         force IPv4 for curl/wget
#   NPS_INSECURE=1     skip TLS verification
#   NPS_NO_MIRROR=1    only use GitHub direct URLs

# Must run as root
if command -v id >/dev/null 2>&1; then
  if [ "$(id -u)" -ne 0 ]; then
    echo "Error: Please run as root or use sudo." >&2
    exit 1
  fi
fi

set -e

has() { command -v "$1" >/dev/null 2>&1; }

# Pre-flight checks: ensure all external commands we rely on are present
for cmd in uname tar; do
  if ! has "$cmd"; then
    echo "Error: missing required command: $cmd" >&2
    exit 1
  fi
done
if ! has curl && ! has wget && ! has uclient-fetch; then
  echo "Error: need curl or wget or uclient-fetch" >&2
  exit 1
fi

# Tunables for downloaders (optional)
CONNECT_TIMEOUT="${NPS_CONNECT_TIMEOUT:-10}"
PROBE_TIMEOUT="${NPS_PROBE_TIMEOUT:-4}"
DOWNLOAD_TIMEOUT="${NPS_DOWNLOAD_TIMEOUT:-300}"
if [ "${NPS_INSECURE:-0}" = "1" ]; then
  CURL_INSECURE="--insecure"
  WGET_INSECURE="--no-check-certificate"
  UCLIENT_INSECURE="--no-check-certificate"
else
  CURL_INSECURE=""
  WGET_INSECURE=""
  UCLIENT_INSECURE=""
fi
if [ "${NPS_IPV4:-0}" = "1" ]; then
  CURL_IP="-4"
  WGET_IP="-4"
else
  CURL_IP=""
  WGET_IP=""
fi

# Fix one fetch tool
if has curl; then
  FETCH_TOOL="curl"
elif has wget; then
  FETCH_TOOL="wget"
else
  FETCH_TOOL="uclient-fetch"
fi

# ---------------------------------------------------------------------------
# Mirror catalogue
#
# Each id maps to three URL shapes:
#   probe : a small file used to measure latency/throughput
#   asset : the release tarball for a concrete tag
#   api   : the "latest release" JSON endpoint (empty when the mirror has none)
# ---------------------------------------------------------------------------
DEFAULT_MIRRORS="github jsdelivr fastly gcore testingcf ghproxy ghproxycom ghfast gitmirror moeyy"

VERIFY_REPO="djylb/nps"
RELEASE_REPO="djylb/nps"
MIRROR_REPO="djylb/nps-mirror"

mirror_valid() {
  case "$1" in
    github|jsdelivr|fastly|gcore|testingcf|ghproxy|ghproxycom|ghfast|gitmirror|moeyy) return 0 ;;
  esac
  return 1
}

# Prefix used by GitHub proxies; empty for direct/CDN mirrors.
mirror_proxy_prefix() {
  case "$1" in
    ghproxy)    echo "https://ghproxy.net/" ;;
    ghproxycom) echo "https://gh-proxy.com/" ;;
    ghfast)     echo "https://ghfast.top/" ;;
    gitmirror)  echo "https://hub.gitmirror.com/" ;;
    moeyy)      echo "https://github.moeyy.xyz/" ;;
    *)          echo "" ;;
  esac
}

mirror_cdn_host() {
  case "$1" in
    jsdelivr)   echo "https://cdn.jsdelivr.net" ;;
    fastly)     echo "https://fastly.jsdelivr.net" ;;
    gcore)      echo "https://gcore.jsdelivr.net" ;;
    testingcf)  echo "https://testingcf.jsdelivr.net" ;;
    *)          echo "" ;;
  esac
}

mirror_probe_url() {
  _p=$(mirror_proxy_prefix "$1")
  _c=$(mirror_cdn_host "$1")
  if [ -n "$_p" ]; then
    echo "${_p}https://raw.githubusercontent.com/${VERIFY_REPO}/master/install.sh"
  elif [ -n "$_c" ]; then
    echo "${_c}/gh/${VERIFY_REPO}@master/install.sh"
  elif [ "$1" = "github" ]; then
    echo "https://raw.githubusercontent.com/${VERIFY_REPO}/master/install.sh"
  fi
}

# Release tags on GitHub are "v0.35.6" while jsDelivr addresses them as
# "0.35.6"; keep one canonical tag and adapt it per mirror.
normalize_tag() {
  case "$1" in
    latest) echo latest ;;
    v*)     echo "$1" ;;
    [0-9]*) echo "v$1" ;;
    *)      echo "$1" ;;
  esac
}

mirror_asset_url() {
  _id="$1"
  _file="$2"
  _tag="$3"
  _p=$(mirror_proxy_prefix "$_id")
  _c=$(mirror_cdn_host "$_id")
  if [ -n "$_p" ]; then
    if [ "$_tag" = "latest" ]; then
      echo "${_p}https://github.com/${RELEASE_REPO}/releases/latest/download/${_file}"
    else
      echo "${_p}https://github.com/${RELEASE_REPO}/releases/download/${_tag}/${_file}"
    fi
  elif [ -n "$_c" ]; then
    _ctag=${_tag#v}
    echo "${_c}/gh/${MIRROR_REPO}@${_ctag}/${_file}"
  elif [ "$_id" = "github" ]; then
    if [ "$_tag" = "latest" ]; then
      echo "https://github.com/${RELEASE_REPO}/releases/latest/download/${_file}"
    else
      echo "https://github.com/${RELEASE_REPO}/releases/download/${_tag}/${_file}"
    fi
  fi
}

mirror_api_url() {
  _id="$1"
  _p=$(mirror_proxy_prefix "$_id")
  if [ -n "$_p" ]; then
    echo "${_p}https://api.github.com/repos/${RELEASE_REPO}/releases/latest"
  elif [ "$_id" = "github" ]; then
    echo "https://api.github.com/repos/${RELEASE_REPO}/releases/latest"
  fi
}

# Safe cleanup (mirror probe and download temp dirs)
TMP_DIRS=""
cleanup() {
  for d in $TMP_DIRS; do
    case "$d" in
      /tmp/*|/var/tmp/*)
        [ -n "$d" ] && [ "$d" != "/" ] && [ -d "$d" ] && rm -rf "$d"
        ;;
    esac
  done
}
trap cleanup 0 INT TERM

# ---------------------------------------------------------------------------
# Time helpers
# ---------------------------------------------------------------------------
HAVE_DATE_NS=0
if _t=$(date +%s%N 2>/dev/null); then
  case "$_t" in
    *[!0-9]*|'') : ;;
    *) HAVE_DATE_NS=1 ;;
  esac
fi

now_ms() {
  if [ "$HAVE_DATE_NS" -eq 1 ]; then
    _n=$(date +%s%N)
    echo $(( _n / 1000000 ))
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

# Convert seconds returned by curl (%{time_total}) to whole milliseconds.
sec_to_ms() {
  _t="$1"
  case "$_t" in
    ''|*[!0-9.]*) echo 999999; return 0 ;;
  esac
  _int=${_t%%.*}
  case "$_t" in
    *.*) _frac=${_t#*.} ;;
    *)   _frac=0 ;;
  esac
  _frac="${_frac}000"
  _frac=${_frac%"${_frac#???}"}
  case "$_frac" in ''|*[!0-9]*) _frac=0 ;; esac
  [ -n "$_int" ] || _int=0
  echo $(( _int * 1000 + _frac ))
}

# ---------------------------------------------------------------------------
# Mirror probing
# ---------------------------------------------------------------------------
probe_one() {
  _id="$1"
  _url=$(mirror_probe_url "$_id")
  _score=999999
  if [ -n "$_url" ]; then
    case "$FETCH_TOOL" in
      curl)
        _t=$(curl $CURL_IP -sS $CURL_INSECURE -o /dev/null -w '%{time_total}' \
              --connect-timeout 2 --max-time "$PROBE_TIMEOUT" \
              -r 0-65535 "$_url" 2>/dev/null) || _t=""
        _score=$(sec_to_ms "$_t")
        ;;
      wget)
        _s=$(now_ms)
        if wget $WGET_IP -q $WGET_INSECURE -T "$PROBE_TIMEOUT" -t 1 \
             -O /dev/null "$_url" 2>/dev/null; then
          _score=$(( $(now_ms) - _s ))
        fi
        ;;
      uclient-fetch)
        _s=$(now_ms)
        if uclient-fetch -q $UCLIENT_INSECURE -T "$PROBE_TIMEOUT" \
             -O /dev/null "$_url" 2>/dev/null; then
          _score=$(( $(now_ms) - _s ))
        fi
        ;;
    esac
  fi
  printf '%s %s\n' "$_score" "$_id"
}

build_mirror_order() {
  _candidates="$DEFAULT_MIRRORS"
  [ -n "$NPS_MIRRORS" ] && _candidates=$(printf '%s' "$NPS_MIRRORS" | tr ',' ' ')
  if [ "${NPS_NO_MIRROR:-0}" = "1" ]; then
    _candidates="github"
  fi

  if [ -n "$NPS_MIRROR_ORDER" ]; then
    MIRROR_ORDER=$(printf '%s' "$NPS_MIRROR_ORDER" | tr ',' ' ')
    [ -n "$MIRROR_ORDER" ] || MIRROR_ORDER="github"
    echo "Mirror order: forced (NPS_MIRROR_ORDER)"
    return 0
  fi

  if [ "${NPS_MIRROR_PROBE:-1}" = "0" ]; then
    MIRROR_ORDER="$_candidates"
    echo "Mirror order: default (probing disabled)"
    return 0
  fi

  echo "Probing mirrors for the fastest route..." >&2
  if has mktemp; then
    _pd=$(mktemp -d 2>/dev/null || mktemp -d -t nps-probe.XXXXXX)
  else
    _pd="/tmp/nps-probe.$$"
    mkdir -p "$_pd"
  fi
  case "$_pd" in /tmp/*|/var/tmp/*) TMP_DIRS="$TMP_DIRS $_pd" ;; esac

  for _id in $_candidates; do
    mirror_valid "$_id" || continue
    ( probe_one "$_id" > "$_pd/$_id" 2>/dev/null ) &
  done
  wait

  : > "$_pd/all"
  for _id in $_candidates; do
    mirror_valid "$_id" || continue
    if [ -s "$_pd/$_id" ]; then
      cat "$_pd/$_id" >> "$_pd/all"
    else
      printf '999999 %s\n' "$_id" >> "$_pd/all"
    fi
  done

  if has sort; then
    _sorted=$(sort -n "$_pd/all")
  else
    _sorted=$(cat "$_pd/all")
  fi

  MIRROR_ORDER=""
  while read -r _score _id; do
    [ -n "$_id" ] || continue
    MIRROR_ORDER="$MIRROR_ORDER $_id"
    if [ "$_score" = "999999" ]; then
      echo "  $_id: unreachable (kept as last resort)" >&2
    else
      echo "  $_id: ${_score}ms" >&2
    fi
  done <<EOF
$_sorted
EOF
  MIRROR_ORDER=${MIRROR_ORDER# }
  [ -n "$MIRROR_ORDER" ] || MIRROR_ORDER="github"
  echo "Mirror order: $MIRROR_ORDER" >&2
}

# ---------------------------------------------------------------------------
# Fetch helpers
# ---------------------------------------------------------------------------
fetch_to_file() {
  _url="$1"
  _out="$2"
  rm -f -- "$_out"
  case "$FETCH_TOOL" in
    curl)
      curl $CURL_IP -sfSL $CURL_INSECURE --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$DOWNLOAD_TIMEOUT" -o "$_out" "$_url" 2>/dev/null
      ;;
    wget)
      wget $WGET_IP -q $WGET_INSECURE -T "$CONNECT_TIMEOUT" -t 1 \
        -O "$_out" "$_url" 2>/dev/null
      ;;
    uclient-fetch)
      uclient-fetch -q $UCLIENT_INSECURE -T "$CONNECT_TIMEOUT" \
        -O "$_out" "$_url" 2>/dev/null
      ;;
  esac
}

fetch_stdout() {
  _url="$1"
  case "$FETCH_TOOL" in
    curl)
      curl $CURL_IP -sfSL $CURL_INSECURE --connect-timeout 5 \
        --max-time 8 "$_url" 2>/dev/null
      ;;
    wget)
      wget $WGET_IP -q $WGET_INSECURE -T 8 -t 1 -O - "$_url" 2>/dev/null
      ;;
    uclient-fetch)
      uclient-fetch -q $UCLIENT_INSECURE -T 8 -O - "$_url" 2>/dev/null
      ;;
  esac
}

# Return the Location header of a URL without following it.
fetch_redirect() {
  _url="$1"
  case "$FETCH_TOOL" in
    curl)
      curl $CURL_IP -sS $CURL_INSECURE -o /dev/null -w '%{redirect_url}' \
        --connect-timeout 5 --max-time 8 "$_url" 2>/dev/null
      ;;
    wget)
      wget $WGET_IP -qS $WGET_INSECURE --spider --max-redirect=0 -T 8 "$_url" 2>&1 \
        | sed -n 's/^[[:space:]]*[Ll]ocation:[[:space:]]*//p' | tr -d '\r' | head -n 1
      ;;
    *)
      echo ""
      ;;
  esac
}

INSTALL_MODE="${1:-${NPS_INSTALL_MODE:-all}}"
INSTALL_VERSION="${2:-${NPS_INSTALL_VERSION:-latest}}"
INSTALL_DIR="${3:-${NPS_INSTALL_DIR:-}}"

# Validate mode
case "$INSTALL_MODE" in
  npc|nps|all) ;;
  *)
    echo "Error: unsupported mode: $INSTALL_MODE" >&2
    exit 1
    ;;
esac

echo "Mode: $INSTALL_MODE"

build_mirror_order

USE_CF_LATEST=0

# Resolve the newest release tag. Three independent routes are tried so a
# blocked api.github.com does not force the @latest fallback:
#   1. GitHub release API (direct first, then through proxies)
#   2. jsDelivr package metadata API (CDN infrastructure)
#   3. the releases/latest redirect surfaced by any reachable proxy
detect_version() {
  for _id in github $MIRROR_ORDER; do
    _api=$(mirror_api_url "$_id")
    [ -n "$_api" ] || continue
    _json=$(fetch_stdout "$_api" || true)
    _v=$(printf '%s' "$_json" \
      | grep -m1 '"tag_name"' \
      | sed 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/')
    if [ -n "$_v" ]; then
      echo "Version source: GitHub API via $_id" >&2
      echo "$_v"
      return 0
    fi
  done

  _json=$(fetch_stdout "https://data.jsdelivr.com/v1/packages/gh/${RELEASE_REPO}/resolved" || true)
  _v=$(printf '%s' "$_json" \
    | grep -m1 '"version"' \
    | sed 's/.*"version":[[:space:]]*"\([^"]*\)".*/\1/')
  case "$_v" in
    [0-9]*.[0-9]*)
      echo "Version source: jsDelivr data API" >&2
      echo "$_v"
      return 0
      ;;
  esac

  for _id in $MIRROR_ORDER; do
    _p=$(mirror_proxy_prefix "$_id")
    [ -n "$_p" ] || continue
    _loc=$(fetch_redirect "${_p}https://github.com/${RELEASE_REPO}/releases/latest")
    case "$_loc" in
      */tag/*)
        _v=${_loc##*/tag/}
        _v=${_v%%\?*}
        if [ -n "$_v" ]; then
          echo "Version source: redirect via $_id" >&2
          echo "$_v"
          return 0
        fi
        ;;
    esac
  done

  return 1
}

# Fetch latest version if unspecified; try mirrors in measured order.
if [ "$INSTALL_VERSION" = "latest" ]; then
  echo "Get latest version..."
  if has grep && has sed; then
    _detected=$(detect_version || true)
    if [ -n "$_detected" ]; then
      INSTALL_VERSION=$(normalize_tag "$_detected")
    else
      echo "Warn: failed to detect version from any mirror, will use CDN @latest." >&2
      USE_CF_LATEST=1
      INSTALL_VERSION=latest
    fi
  else
    echo "No grep/sed; use CDN @latest." >&2
    USE_CF_LATEST=1
    INSTALL_VERSION=latest
  fi
fi

if [ "$USE_CF_LATEST" -eq 1 ]; then
  echo "Version: latest (CDN @latest fallback)"
else
  echo "Version: $INSTALL_VERSION"
fi

# Determine OS
OS="$(uname -s)"
case "$OS" in
  Linux)   OS=linux;;
  Darwin)  OS=darwin;;
  FreeBSD) OS=freebsd;;
  *)
    echo "Error: OS not supported: $OS" >&2
    exit 1
    ;;
esac

# Determine ARCH
RAW_ARCH="$(uname -m)"
case "$RAW_ARCH" in
  x86_64|amd64)      ARCH=amd64;;
  i?86)              ARCH=386;;
  aarch64|arm64)     ARCH=arm64;;
  armv7*|armv7l)     ARCH=arm_v7;;
  armv6*|armv6l)     ARCH=arm_v6;;
  armv5*|armv5l)     ARCH=arm_v5;;
  arm)               ARCH=arm;;
  mips64le)          ARCH=mips64le;;
  mips64)            ARCH=mips64;;
  mipsle)            ARCH=mipsle;;
  mips)              ARCH=mips;;
  loongarch64)       ARCH=loong64;;
  riscv64)           ARCH=riscv64;;
  *)
    echo "Error: ARCH not supported: $RAW_ARCH" >&2
    exit 1
    ;;
esac

echo "Detected OS/ARCH: $OS/$ARCH"

# MIPS float ABI detection
if [ "$ARCH" = "mips64" ] || [ "$ARCH" = "mips64le" ]; then
  # 64-bit MIPS userlands are hard-float; only a CPU without FPU needs soft-float
  if [ -r /proc/cpuinfo ] && ! grep -qi 'fpu' /proc/cpuinfo; then
    ARCH="${ARCH}_softfloat"
    echo "No FPU in /proc/cpuinfo; use soft-float, new ARCH: $ARCH"
  else
    echo "Use hard-float for $ARCH"
  fi
elif [ "$ARCH" = "mips" ] || [ "$ARCH" = "mipsle" ]; then
  if has file; then
    out="$(file /bin/sh 2>/dev/null || true)"
    case "$out" in
      *hard[-\ ]float*)
        echo "Use hard-float for $ARCH"
        ;;
      *)
        ARCH="${ARCH}_softfloat"
        echo "Use soft-float, new ARCH: $ARCH"
        ;;
    esac
  else
    ARCH="${ARCH}_softfloat"
    echo "No 'file' tool; default to soft-float: $ARCH"
  fi
fi

# Extraction
tar_extract() {
  f="$1"

  if tar -xzf "$f" 2>/dev/null; then
    return 0
  fi

  if tar xf "$f" 2>/dev/null; then
    return 0
  fi

  if has gzip; then
    if gzip -dc "$f" | tar xf -; then
      return 0
    fi
  fi

  if has gunzip; then
    if gunzip -c "$f" | tar xf -; then
      return 0
    fi
  fi

  return 1
}

# Download helper: walks the measured mirror order, first success wins.
download() {
  NAME=$1
  FILE="${OS}_${ARCH}_${NAME}.tar.gz"

  if [ "$USE_CF_LATEST" -eq 1 ]; then
    TAG_FOR_URL="latest"
  else
    TAG_FOR_URL=$(normalize_tag "$INSTALL_VERSION")
  fi

  # Decide workdir
  if [ -n "$INSTALL_DIR" ]; then
    mkdir -p "$INSTALL_DIR"
    WORKDIR="$INSTALL_DIR"
  else
    if has mktemp; then
      TMPD=$(mktemp -d 2>/dev/null || mktemp -d -t nps-install.XXXXXX)
    else
      TS="$(date +%s 2>/dev/null || echo 0)"
      TMPD="/tmp/nps-$$.$TS"
      mkdir -p "$TMPD"
    fi
    TMP_DIRS="$TMP_DIRS $TMPD"
    WORKDIR="$TMPD"
  fi

  cd "$WORKDIR"

  success=0
  for id in $MIRROR_ORDER; do
    URL=$(mirror_asset_url "$id" "$FILE" "$TAG_FOR_URL")
    [ -n "$URL" ] || continue
    echo "Trying [$id] $URL" >&2

    rm -f -- "./$FILE"

    _start=$(now_ms)
    if fetch_to_file "$URL" "$FILE" && [ -s "$FILE" ]; then
      success=1
      _cost=$(( $(now_ms) - _start ))
      echo "Downloaded via $id (${_cost}ms)" >&2
      break
    fi
  done

  if [ "$success" -ne 1 ] || [ ! -f "$FILE" ]; then
    echo "Error: Download failed for all mirrors:" >&2
    for id in $MIRROR_ORDER; do
      URL=$(mirror_asset_url "$id" "$FILE" "$TAG_FOR_URL")
      [ -n "$URL" ] && echo "  - $URL" >&2
    done
    exit 1
  fi

  if ! tar_extract "$FILE"; then
    echo "Error: failed to extract $FILE" >&2
    exit 1
  fi

  if [ -n "$INSTALL_DIR" ]; then
    rm -f -- "./$FILE"
    printf '%s\n' "$INSTALL_DIR"
  else
    printf '%s\n' "$WORKDIR"
  fi
}

# Install NPC (client)
install_npc() {
  SRC=$(download client)
  echo "Install npc..."

  if [ -n "$INSTALL_DIR" ]; then
    echo "npc installed in $INSTALL_DIR"
    return
  fi

  if [ -x "$SRC/npc" ]; then
    if cp -f "$SRC/npc" /usr/bin/npc 2>/dev/null; then
      chmod 755 /usr/bin/npc
    else
      mkdir -p /usr/local/bin
      cp -f "$SRC/npc" /usr/local/bin/npc
      chmod 755 /usr/local/bin/npc
    fi
  else
    echo "Error: 'npc' binary not found in $SRC" >&2
    exit 1
  fi

  mkdir -p /etc/nps/conf
  if [ ! -f /etc/nps/conf/npc.conf ]; then
    cp "$SRC/conf/npc.conf" /etc/nps/conf/npc.conf 2>/dev/null || true
  else
    cp -f "$SRC/conf/npc.conf" /etc/nps/conf/npc.conf.default 2>/dev/null || true
  fi
  echo "npc done"
}

# Install NPS (server)
install_nps() {
  SRC=$(download server)
  echo "Install nps..."

  if [ -n "$INSTALL_DIR" ]; then
    echo "nps installed in $INSTALL_DIR"
    return
  fi

  if [ -x "$SRC/nps" ]; then
    if cp -f "$SRC/nps" /usr/bin/nps 2>/dev/null; then
      chmod 755 /usr/bin/nps
    else
      mkdir -p /usr/local/bin
      cp -f "$SRC/nps" /usr/local/bin/nps
      chmod 755 /usr/local/bin/nps
    fi
  else
    echo "Error: 'nps' binary not found in $SRC" >&2
    exit 1
  fi

  mkdir -p /etc/nps/conf /etc/nps/web
  if [ ! -f /etc/nps/conf/nps.conf ]; then
    cp "$SRC/conf/nps.conf" /etc/nps/conf/nps.conf 2>/dev/null || true
  else
    cp -f "$SRC/conf/nps.conf" /etc/nps/conf/nps.conf.default 2>/dev/null || true
  fi
  cp -rf "$SRC/web/"* /etc/nps/web/ 2>/dev/null || true
  echo "nps done"
}

# Run installation per mode
case "$INSTALL_MODE" in
  npc) install_npc ;;
  nps) install_nps ;;
  all) install_npc; install_nps ;;
esac

echo "All done"
