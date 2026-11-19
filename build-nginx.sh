#!/usr/bin/env bash
#
# Build NGINX from source with statically linked OpenSSL, PCRE2 and zlib.
# Tuned for a Nextcloud server on a Raspberry Pi (Raspberry Pi OS / Debian),
# works on any Debian-based system.
#
# Usage: sudo ./build-nginx.sh [--build-only] [--check] [--help]
#
# Settings can be overridden with environment variables, e.g.
#   sudo NGINX_BRANCH=stable OPENSSL_SERIES=3.5 ./build-nginx.sh
# Run with --help for the full list.

set -Eeuo pipefail
trap 'echo "ERROR: ${BASH_SOURCE[0]:-$0}:${LINENO}: \"${BASH_COMMAND}\" failed" >&2' ERR

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
# nginx branch: "mainline" (odd minor, nginx's own recommendation, gets fixes
# first) or "stable" (even minor, only critical fixes).
NGINX_BRANCH=${NGINX_BRANCH:-mainline}
# OpenSSL series: "3.5" is the LTS release (supported until 2030-04-08).
# Non-LTS releases (4.0, 4.1, ...) are supported for only ~13 months.
# Use "latest" for the newest release of any series.
OPENSSL_SERIES=${OPENSSL_SERIES:-3.5}
# Pin exact versions (optional), e.g. NGINX_VERSION=1.31.9 OPENSSL_VERSION=3.5.9
NGINX_VERSION=${NGINX_VERSION:-}
OPENSSL_VERSION=${OPENSSL_VERSION:-}
PCRE2_VERSION=${PCRE2_VERSION:-}
ZLIB_VERSION=${ZLIB_VERSION:-}
# Optional HTTP/3 (QUIC) support; enabled at runtime only with "listen ... quic".
WITH_HTTP3=${WITH_HTTP3:-1}
# The stream (TCP/UDP proxy) module is not needed for Nextcloud.
WITH_STREAM=${WITH_STREAM:-0}
# CPU_TUNE=native adds -mcpu=native (ARM) / -march=native (x86). Small gain,
# but the binary may crash with SIGILL on an older CPU (e.g. moving an SD card
# from a Pi 5 to a Pi 4), so it is off by default.
CPU_TUNE=${CPU_TUNE:-}
# Extra ./configure arguments, e.g. EXTRA_CONFIGURE_ARGS="--with-http_sub_module"
EXTRA_CONFIGURE_ARGS=${EXTRA_CONFIGURE_ARGS:-}
# Parallel jobs; default is limited by free RAM (~400 MB per job) so that
# low-memory boards (Pi Zero 2 W, 1 GB Pi 3/4) don't run out of memory.
JOBS=${JOBS:-}
BUILD_DIR=${BUILD_DIR:-$(pwd)/build}
KEEP_BUILD=${KEEP_BUILD:-0}

# Download locations
url_nginx=https://nginx.org/download
url_openssl_list=https://openssl-library.org/source/
url_openssl_dl=https://github.com/openssl/openssl/releases/download
url_pcre2_api=https://api.github.com/repos/PCRE2Project/pcre2/releases/latest
url_pcre2_dl=https://github.com/PCRE2Project/pcre2/releases/download
# zlib.net's front page is behind a bot check; the fossils index is plain HTML.
url_zlib_list=https://zlib.net/fossils/
url_zlib_dl=https://zlib.net
# Fallback if zlib.net is unavailable or serves its bot check
url_zlib_api=https://api.github.com/repos/madler/zlib/releases/latest
url_zlib_gh=https://github.com/madler/zlib/releases/download

# OpenPGP fingerprints of the release signers (full primary-key fingerprints).
# A signature is only accepted if it was made by one of the keys listed for
# that particular package.
# nginx:   https://nginx.org/en/pgp_keys.html
keys_nginx=(
  D6786CE303D9A9022998DC6CC8464D549AF75C0A # Sergey Kandaurov
  43387825DDB1BB97EC36BA5D007C8D7C15D87369 # Roman Arutyunyan
  13C82A63B603576156E30A4EA0EA981B66B0D967 # Konstantin Pavlov
)
# OpenSSL: https://openssl-library.org/source/ and doc/fingerprints.txt
keys_openssl=(
  B146647E45A7B33947AB226B2A2C87D161692D40 # OpenSSL <openssl@openssl.org> (2026-2031)
)
# PCRE2:   https://github.com/PCRE2Project/pcre2/releases
keys_pcre2=(
  A95536204A3BB489715231282A98E77EB6F24CA8 # Nicholas Wilson (10.45 onwards)
)
# zlib:    https://zlib.net/
keys_zlib=(
  5ED46A6721D365587791E2AA783FCD8E58BCAFBA # Mark Adler
)
# Keys are fetched over HTTPS with curl (more reliable than gpg's dirmngr).
# Where they come from doesn't matter for security: only the pinned
# fingerprints above are trusted.
keyservers=(
  'https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x'
  'https://keys.openpgp.org/vks/v1/by-fingerprint/'
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# HTTPS only (also on redirects), fail on HTTP errors, retry transient errors.
fetch() {
  curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --retry 3 --retry-delay 5 --connect-timeout 30 "$@"
}

usage() {
  sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF

Options:
  --build-only   Download, verify and compile, but do not install (e.g. to try
                 a new version first). Without it, the running nginx keeps
                 serving during the build and is restarted only at the end.
  --check        Compare the installed nginx/OpenSSL with the latest upstream
                 versions; exit 1 if a rebuild is due (handy for cron).
  --help         Show this help.

Environment variables (current value):
  NGINX_BRANCH=$NGINX_BRANCH   OPENSSL_SERIES=$OPENSSL_SERIES
  NGINX_VERSION OPENSSL_VERSION PCRE2_VERSION ZLIB_VERSION  (pin versions)
  WITH_HTTP3=$WITH_HTTP3   WITH_STREAM=$WITH_STREAM   CPU_TUNE=${CPU_TUNE:-<off>}
  EXTRA_CONFIGURE_ARGS  JOBS  BUILD_DIR=$BUILD_DIR  KEEP_BUILD=$KEEP_BUILD
EOF
}

# ---------------------------------------------------------------------------
# Version lookup
# ---------------------------------------------------------------------------
latest_nginx() {
  local parity
  case $NGINX_BRANCH in
    mainline) parity=1 ;;
    stable)   parity=0 ;;
    *) die "NGINX_BRANCH must be 'mainline' or 'stable'" ;;
  esac
  fetch "$url_nginx/" \
    | grep -oE 'nginx-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' \
    | sed -E 's/^nginx-(.*)\.tar\.gz$/\1/' \
    | awk -F. -v p="$parity" '$2 % 2 == p' \
    | sort -uV | tail -n 1
}

latest_openssl() {
  local filter='.'
  if [[ $OPENSSL_SERIES != latest ]]; then filter="^${OPENSSL_SERIES//./\\.}\\."; fi
  fetch "$url_openssl_list" \
    | grep -oE 'openssl-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' \
    | sed -E 's/^openssl-(.*)\.tar\.gz$/\1/' \
    | grep -E "$filter" \
    | sort -uV | tail -n 1
}

latest_pcre2() {
  fetch -H 'Accept: application/vnd.github+json' "$url_pcre2_api" \
    | jq -r '.tag_name' | sed -E 's/^pcre2-//'
}

latest_zlib() {
  local v
  v=$(fetch "$url_zlib_list" \
    | grep -oE 'zlib-[0-9]+(\.[0-9]+)+\.tar\.gz' \
    | sed -E 's/^zlib-(.*)\.tar\.gz$/\1/' \
    | sort -uV | tail -n 1) || true
  if [[ -z $v ]]; then
    v=$(fetch -H 'Accept: application/vnd.github+json' "$url_zlib_api" \
      | jq -r '.tag_name' | sed -E 's/^v//')
  fi
  echo "$v"
}

resolve_versions() {
  log "Looking up versions"
  NGINX_VERSION=${NGINX_VERSION:-$(latest_nginx || true)}
  OPENSSL_VERSION=${OPENSSL_VERSION:-$(latest_openssl || true)}
  PCRE2_VERSION=${PCRE2_VERSION:-$(latest_pcre2 || true)}
  ZLIB_VERSION=${ZLIB_VERSION:-$(latest_zlib || true)}

  local v
  for v in NGINX_VERSION OPENSSL_VERSION PCRE2_VERSION ZLIB_VERSION; do
    [[ ${!v} =~ ^[0-9]+(\.[0-9]+)+$ ]] \
      || die "could not determine $v (got '${!v}'); set it manually, e.g. $v=x.y.z"
  done
  printf '  %-8s %s\n' nginx "$NGINX_VERSION ($NGINX_BRANCH)" \
    OpenSSL "$OPENSSL_VERSION (series: $OPENSSL_SERIES)" \
    PCRE2 "$PCRE2_VERSION" zlib "$ZLIB_VERSION"
}

# ---------------------------------------------------------------------------
# --check: is a rebuild due?
# ---------------------------------------------------------------------------
check_versions() {
  command -v nginx >/dev/null || die "nginx is not installed"
  local info cur_nginx cur_openssl outdated=0
  info=$(nginx -V 2>&1)
  cur_nginx=$(sed -nE 's|^nginx version: nginx/([0-9.]+).*|\1|p' <<<"$info")
  cur_openssl=$(sed -nE 's|^built with OpenSSL ([0-9.]+).*|\1|p' <<<"$info")
  resolve_versions
  echo
  printf '  installed: nginx %s, OpenSSL %s\n' "$cur_nginx" "$cur_openssl"
  printf '  latest:    nginx %s, OpenSSL %s\n' "$NGINX_VERSION" "$OPENSSL_VERSION"
  [[ $cur_nginx == "$NGINX_VERSION" ]] || outdated=1
  [[ $cur_openssl == "$OPENSSL_VERSION" ]] || outdated=1
  if (( outdated )); then
    echo "  -> rebuild recommended"; exit 1
  fi
  echo "  -> up to date"
}

# ---------------------------------------------------------------------------
# Download and verify
# ---------------------------------------------------------------------------
import_keys() {
  local ks fpr
  for fpr in "$@"; do
    for ks in "${keyservers[@]}"; do
      fetch "$ks$fpr" 2>/dev/null | gpg --batch --quiet --import 2>/dev/null || true
      gpg --batch --list-keys "$fpr" &>/dev/null && continue 2
    done
    die "could not fetch OpenPGP key $fpr from any keyserver"
  done
}

# verify <signature> <file> <allowed fingerprint>...
# Accept the file only if the signature is good AND was made by one of the
# allowed keys (or one of their subkeys). Plain "gpg --verify" would accept a
# signature from any key in the keyring.
verify() {
  local sig=$1 file=$2; shift 2
  local status signer fpr
  status=$(gpg --batch --status-fd 1 --verify "$sig" "$file" 2>/dev/null) \
    || die "bad or missing signature for $file"
  # VALIDSIG <sig-fpr> ... <primary-key-fpr>
  signer=$(awk '$2 == "VALIDSIG" { print $NF }' <<<"$status")
  for fpr in "$@"; do
    if [[ $signer == "$fpr" ]]; then
      echo "  OK  $file  (signed by $signer)"
      return 0
    fi
  done
  die "$file was signed by unexpected key '${signer:-none}'"
}

download_sources() {
  log "Downloading sources into $BUILD_DIR"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"
  cd "$BUILD_DIR"

  local o=openssl-$OPENSSL_VERSION p=pcre2-$PCRE2_VERSION
  local n=nginx-$NGINX_VERSION z=zlib-$ZLIB_VERSION
  fetch -o "$n.tar.gz"     "$url_nginx/$n.tar.gz"
  fetch -o "$n.tar.gz.asc" "$url_nginx/$n.tar.gz.asc"
  fetch -o "$o.tar.gz"     "$url_openssl_dl/$o/$o.tar.gz"
  fetch -o "$o.tar.gz.asc" "$url_openssl_dl/$o/$o.tar.gz.asc"
  fetch -o "$p.tar.gz"     "$url_pcre2_dl/$p/$p.tar.gz"
  fetch -o "$p.tar.gz.sig" "$url_pcre2_dl/$p/$p.tar.gz.sig"
  if ! { fetch -o "$z.tar.gz"     "$url_zlib_dl/$z.tar.gz" &&
          fetch -o "$z.tar.gz.asc" "$url_zlib_dl/$z.tar.gz.asc"; }; then
    warn "zlib.net download failed, trying GitHub"
    fetch -o "$z.tar.gz"     "$url_zlib_gh/v$ZLIB_VERSION/$z.tar.gz"
    fetch -o "$z.tar.gz.asc" "$url_zlib_gh/v$ZLIB_VERSION/$z.tar.gz.asc"
  fi

  log "Verifying OpenPGP signatures"
  GNUPGHOME=$(mktemp -d)
  export GNUPGHOME
  import_keys "${keys_nginx[@]}" "${keys_openssl[@]}" "${keys_pcre2[@]}" "${keys_zlib[@]}"
  verify "$n.tar.gz.asc" "$n.tar.gz" "${keys_nginx[@]}"
  verify "$o.tar.gz.asc" "$o.tar.gz" "${keys_openssl[@]}"
  verify "$p.tar.gz.sig" "$p.tar.gz" "${keys_pcre2[@]}"
  verify "$z.tar.gz.asc" "$z.tar.gz" "${keys_zlib[@]}"

  log "Extracting"
  local archive
  for archive in "$n" "$o" "$p" "$z"; do
    tar --no-same-owner -xzf "$archive.tar.gz"
    [[ -d $archive ]] || die "$archive.tar.gz did not contain $archive/"
  done
  rm -f ./*.tar.gz ./*.tar.gz.asc ./*.tar.gz.sig
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
install_build_deps() {
  log "Installing build dependencies"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl gnupg jq perl
}

compute_flags() {
  local arch gcc_major fortify=2
  arch=$(uname -m)
  gcc_major=$(gcc -dumpversion | cut -d. -f1)
  if (( gcc_major >= 12 )); then fortify=3; fi

  # Hardening flags as used by Debian (dpkg-buildflags hardening=+all),
  # spelled out so the result is the same on every distro/release.
  harden="-fstack-protector-strong -fstack-clash-protection"
  harden+=" -Wformat -Werror=format-security"
  case $arch in
    aarch64|arm64) harden+=" -mbranch-protection=standard" ;;  # PAC/BTI, no-op on older CPUs
    x86_64)        harden+=" -fcf-protection" ;;
  esac
  cppflags="-U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=$fortify"
  ldflags="-Wl,-z,relro -Wl,-z,now"

  tune=""
  if [[ $CPU_TUNE == native ]]; then
    case $arch in
      x86_64) tune="-march=native" ;;
      *)      tune="-mcpu=native" ;;
    esac
  fi

  # Each library keeps its upstream optimisation level. nginx otherwise
  # passes an *empty* CFLAGS to PCRE2 and zlib, which builds them without
  # any optimisation (-O0).
  cc_opt_nginx="-O2 $harden $cppflags $tune"
  cc_opt_pcre="-O2 $harden $cppflags $tune"
  cc_opt_zlib="-O3 $harden $cppflags $tune"

  # OpenSSL: smaller attack surface and a faster build.
  #   no-tests no-docs   skip test programs and man pages (big time saver on a Pi)
  #   no-legacy          drop the legacy provider (MD4, DES, RC4, ...)
  #   enable-ktls        allow kernel TLS (opt-in in nginx: ssl_conf_command Options KTLS)
  openssl_opt="no-tests no-docs no-legacy enable-ktls $harden $cppflags $tune"
  if gcc -dM -E - </dev/null | grep -c __SIZEOF_INT128__ >/dev/null; then
    openssl_opt+=" enable-ec_nistp_64_gcc_128"
  fi

  if [[ -z $JOBS ]]; then
    local mem_mb
    mem_mb=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
    JOBS=$(( mem_mb / 400 ))
    if (( JOBS < 1 )); then JOBS=1; fi
    if (( JOBS > $(nproc) )); then JOBS=$(nproc); fi
  fi
}

configure_nginx() {
  local src=$BUILD_DIR/nginx-$NGINX_VERSION
  cd "$src"

  local args=(
    --prefix=/etc/nginx
    --sbin-path=/usr/sbin/nginx
    --modules-path=/usr/lib/nginx/modules
    --conf-path=/etc/nginx/nginx.conf
    --error-log-path=/var/log/nginx/error.log
    --http-log-path=/var/log/nginx/access.log
    --pid-path=/run/nginx.pid
    --lock-path=/run/nginx.lock
    --http-client-body-temp-path=/var/cache/nginx/client_temp
    --http-proxy-temp-path=/var/cache/nginx/proxy_temp
    --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp
    --user=www-data
    --group=www-data

    --with-cc-opt="$cc_opt_nginx"
    --with-ld-opt="$ldflags"
    --with-openssl="$BUILD_DIR/openssl-$OPENSSL_VERSION"
    --with-openssl-opt="$openssl_opt"
    --with-pcre="$BUILD_DIR/pcre2-$PCRE2_VERSION"
    --with-pcre-opt="$cc_opt_pcre"
    --with-pcre-jit
    --with-zlib="$BUILD_DIR/zlib-$ZLIB_VERSION"
    --with-zlib-opt="$cc_opt_zlib"

    # What a Nextcloud server needs
    --with-threads                    # "aio threads" for large static files
    --with-file-aio
    --with-http_ssl_module
    --with-http_v2_module
    --with-http_realip_module         # real client IP behind a proxy/tunnel
    --with-http_gzip_static_module
    --with-http_stub_status_module    # basic metrics; restrict access to it

    # Modules Nextcloud doesn't use: less code = less attack surface
    --without-http_autoindex_module
    --without-http_browser_module
    --without-http_empty_gif_module
    --without-http_geo_module
    --without-http_grpc_module
    --without-http_memcached_module
    --without-http_mirror_module
    --without-http_scgi_module
    --without-http_split_clients_module
    --without-http_ssi_module
    --without-http_userid_module
    --without-http_uwsgi_module
  )
  # Options that only exist in newer nginx versions
  local help
  help=$(./configure --help)
  if grep -q -- '--without-http_tunnel_module' <<<"$help"; then
    args+=(--without-http_tunnel_module)   # forward-proxy CONNECT tunnels (1.31+)
  fi

  if (( WITH_HTTP3 )); then args+=(--with-http_v3_module); fi
  if (( WITH_STREAM )); then
    args+=(--with-stream --with-stream_ssl_module --with-stream_ssl_preread_module)
  fi

  if [[ -n $EXTRA_CONFIGURE_ARGS ]]; then
    local extra
    read -r -a extra <<<"$EXTRA_CONFIGURE_ARGS"
    args+=("${extra[@]}")
  fi

  log "Configuring nginx $NGINX_VERSION"
  ./configure "${args[@]}"
}

build_nginx() {
  log "Compiling with $JOBS parallel job(s) - this takes a while on a Raspberry Pi"
  make -j"$JOBS"
  strip -s objs/nginx
  objs/nginx -V
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
install_nginx() {
  local src=$BUILD_DIR/nginx-$NGINX_VERSION
  cd "$src"

  # Refuse to install the new binary if it can't load the existing config,
  # e.g. because the config uses a module this build leaves out.
  if [[ -f /etc/nginx/nginx.conf ]]; then
    log "Testing the existing configuration with the new binary"
    mkdir -p /var/cache/nginx /var/log/nginx
    objs/nginx -t -c /etc/nginx/nginx.conf \
      || die "the new nginx rejects /etc/nginx/nginx.conf - nothing was installed. \
Add the missing module(s) via EXTRA_CONFIGURE_ARGS or fix the config, then re-run."

    local backup
    backup=/etc/nginx-backup-$(date +%Y%m%d-%H%M%S)
    cp -a /etc/nginx "$backup"
    echo "  backed up /etc/nginx to $backup"
  fi

  log "Installing"
  id -g www-data &>/dev/null || addgroup --system www-data
  id -u www-data &>/dev/null || adduser --system --no-create-home \
    --home /var/cache/nginx --shell /usr/sbin/nologin --ingroup www-data www-data
  install -d -m 0750 -o www-data -g www-data \
    /var/cache/nginx /var/cache/nginx/client_temp \
    /var/cache/nginx/proxy_temp /var/cache/nginx/fastcgi_temp
  # "make install" never overwrites existing config files: it only refreshes
  # the *.default copies (nginx.conf.default, mime.types.default, ...) and
  # keeps the previous binary as /usr/sbin/nginx.old.
  make install

  install_service
}

install_service() {
  local unit=/etc/systemd/system/nginx.service
  if [[ -e $unit ]]; then
    echo "  $unit exists - left untouched"
  else
    echo "  writing $unit"
    cat >"$unit" <<'EOF'
[Unit]
Description=nginx - high performance web server
Documentation=https://nginx.org/en/docs/
After=network-online.target remote-fs.target nss-lookup.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/usr/sbin/nginx -t -q
ExecStart=/usr/sbin/nginx
ExecReload=/usr/sbin/nginx -t -q
ExecReload=/bin/kill -s HUP $MAINPID
ExecStop=/bin/kill -s QUIT $MAINPID
TimeoutStopSec=10
KillMode=mixed
Restart=on-failure
RestartSec=5s

# Sandboxing. nginx only needs to write to /var/log/nginx, /var/cache/nginx
# and /run. Do NOT add MemoryDenyWriteExecute=yes: PCRE2 JIT needs it off.
PrivateTmp=true
PrivateDevices=true
ProtectSystem=full
ProtectHome=read-only
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
NoNewPrivileges=true
LockPersonality=true
RestrictRealtime=true
RestrictSUIDSGID=true
RestrictNamespaces=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
EOF
    if [[ -e /lib/systemd/system/nginx.service ]]; then
      echo "  note: it overrides the older /lib/systemd/system/nginx.service"
    fi
  fi

  if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload
    if systemctl is-active --quiet nginx; then
      log "Restarting nginx"
      systemctl restart nginx
    else
      echo "  Start nginx with:  sudo systemctl enable --now nginx"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local build_only=0 check_only=0
  while (( $# )); do
    case $1 in
      --build-only) build_only=1 ;;
      --check)      check_only=1 ;;
      -h|--help)    usage; exit 0 ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  if [[ ${DEBUG:-0} == 1 ]]; then set -x; fi

  if (( check_only )); then
    for c in curl jq; do command -v "$c" >/dev/null || die "--check needs $c"; done
    check_versions
    exit 0
  fi

  [[ $EUID -eq 0 ]] || die "run as root or with sudo"

  # A distro nginx package would fight over /usr/sbin/nginx and /etc/nginx.
  if { dpkg-query -W -f='${Status}\n' nginx nginx-common nginx-core nginx-full \
         nginx-light nginx-extras 2>/dev/null || true; } | grep -c '^install ok installed' >/dev/null; then
    die "an nginx package from apt is installed; remove it first (sudo apt remove nginx nginx-common)"
  fi

  BUILD_DIR=$(realpath -m "$BUILD_DIR")
  [[ $(dirname "$BUILD_DIR") != / ]] || die "BUILD_DIR=$BUILD_DIR is too close to / (it gets deleted)"
  trap 'rm -rf "${GNUPGHOME:-/nonexistent}"' EXIT

  install_build_deps
  resolve_versions
  compute_flags
  download_sources
  configure_nginx
  build_nginx

  if (( build_only )); then
    log "Build finished: $BUILD_DIR/nginx-$NGINX_VERSION/objs/nginx (not installed)"
    echo "  Run the script without --build-only to build and install."
    exit 0
  fi

  install_nginx
  if (( ! KEEP_BUILD )); then
    rm -rf "$BUILD_DIR"
  fi
  log "Done: $(/usr/sbin/nginx -v 2>&1)"
}

main "$@"
