#!/usr/bin/env bash
#
# This script builds nginx from source code for a Nextcloud server.
# It puts OpenSSL, PCRE2 and zlib into the nginx program file.
# It works on Raspberry Pi OS and on other Debian-based systems.
#
# Usage: sudo bash build-nginx.sh [--build-only] [--check] [--help]
#
# To change the configuration, set environment variables. Example:
#   sudo NGINX_BRANCH=stable bash build-nginx.sh
# To see all variables, run: bash build-nginx.sh --help

set -Eeuo pipefail
trap 'echo "ERROR: ${BASH_SOURCE[0]:-$0}:${LINENO}: \"${BASH_COMMAND}\" failed" >&2' ERR

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# The nginx release line: "mainline" or "stable".
# Mainline gets all fixes first. The nginx team recommends it.
# Stable gets only important fixes.
NGINX_BRANCH=${NGINX_BRANCH:-mainline}
# The OpenSSL release line. "3.5" has long-term support until 2030-04-08.
# Other lines (4.0, 4.1) get support for about 13 months only.
# "latest" selects the newest release of all lines.
OPENSSL_SERIES=${OPENSSL_SERIES:-3.5}
# To use one exact version, set it here. Example: NGINX_VERSION=1.31.9
# If a variable is empty, the script uses the latest version.
NGINX_VERSION=${NGINX_VERSION:-}
OPENSSL_VERSION=${OPENSSL_VERSION:-}
PCRE2_VERSION=${PCRE2_VERSION:-}
ZLIB_VERSION=${ZLIB_VERSION:-}
# 1 = include HTTP/3 (a newer web protocol). It stays off until you add
# "listen 443 quic" to the nginx configuration.
WITH_HTTP3=${WITH_HTTP3:-1}
# 1 = include the stream module (a TCP and UDP proxy). Nextcloud does not use it.
WITH_STREAM=${WITH_STREAM:-0}
# "native" = optimize for the CPU of this computer (-mcpu=native or -march=native).
# The speed gain is small. On an older CPU, the program can stop with SIGILL.
# Example: you move the SD card from a Pi 5 to a Pi 4.
CPU_TUNE=${CPU_TUNE:-}
# More arguments for ./configure. Example: "--with-http_sub_module"
EXTRA_CONFIGURE_ARGS=${EXTRA_CONFIGURE_ARGS:-}
# The script removes some default modules that Nextcloud does not use.
# To keep one of them, write its name here. Example: "autoindex grpc"
KEEP_MODULES=${KEEP_MODULES:-}
# The number of parallel compile jobs. If empty, the script allows one job
# for each 400 MB of free memory. This prevents memory errors on small boards.
# The minimum is 1 job. The maximum is the number of CPU cores.
JOBS=${JOBS:-}
BUILD_DIR=${BUILD_DIR:-$(pwd)/build}
KEEP_BUILD=${KEEP_BUILD:-0}

# Download addresses
url_nginx=https://nginx.org/download
url_openssl_list=https://openssl-library.org/source/
url_openssl_dl=https://github.com/openssl/openssl/releases/download
url_pcre2_api=https://api.github.com/repos/PCRE2Project/pcre2/releases/latest
url_pcre2_dl=https://github.com/PCRE2Project/pcre2/releases/download
# The zlib.net home page blocks scripts. The "fossils" list is plain HTML.
url_zlib_list=https://zlib.net/fossils/
url_zlib_dl=https://zlib.net
# The script uses GitHub if zlib.net fails.
url_zlib_api=https://api.github.com/repos/madler/zlib/releases/latest
url_zlib_gh=https://github.com/madler/zlib/releases/download

# The OpenPGP key fingerprints (unique key IDs) of the people who sign releases.
# The script accepts a file only if one of the keys for that package signed it.
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
# The script downloads the keys with curl. This works more reliably than
# the gpg keyserver tool (dirmngr). The source of a key is not important,
# because the script trusts only the fingerprints above.
keyservers=(
  'https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x'
  'https://keys.openpgp.org/vks/v1/by-fingerprint/'
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
# The exit code of die(). --check sets it to 2, so that 1 means "update available".
DIE_CODE=1
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit "$DIE_CODE"; }

# Download with HTTPS only, also after a redirect. Stop on an HTTP error.
# If the network fails, try again 3 times.
fetch() {
  curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --retry 3 --retry-delay 5 --connect-timeout 30 "$@"
}

usage() {
  cat <<EOF
Build nginx from source code for a Nextcloud server.

Usage: sudo bash build-nginx.sh [--build-only] [--check] [--help]

  (no flag)      Build nginx and install it. Your current nginx continues to
                 run during the build. The script restarts it at the end.
  --build-only   Build nginx, but do not install it.
  --check        Compare the installed nginx and OpenSSL with the latest
                 versions. Exit code 0: up to date. Exit code 1: a new version
                 is available. Exit code 2: the comparison failed.
  --help         Show this text.

Environment variables (current value):
  NGINX_BRANCH=$NGINX_BRANCH   OPENSSL_SERIES=$OPENSSL_SERIES
  NGINX_VERSION OPENSSL_VERSION PCRE2_VERSION ZLIB_VERSION  (exact versions)
  WITH_HTTP3=$WITH_HTTP3   WITH_STREAM=$WITH_STREAM   CPU_TUNE=${CPU_TUNE:-<off>}
  EXTRA_CONFIGURE_ARGS  KEEP_MODULES  JOBS  BUILD_DIR=$BUILD_DIR  KEEP_BUILD=$KEEP_BUILD

The README explains each variable.
EOF
}

# ---------------------------------------------------------------------------
# Find the latest versions
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
      || die "Cannot find the latest $v (result: '${!v}'). Set it yourself. Example: $v=x.y.z"
  done
  printf '  %-8s %s\n' nginx "$NGINX_VERSION ($NGINX_BRANCH)" \
    OpenSSL "$OPENSSL_VERSION (series: $OPENSSL_SERIES)" \
    PCRE2 "$PCRE2_VERSION" zlib "$ZLIB_VERSION"
}

# ---------------------------------------------------------------------------
# --check: compare the installed versions with the latest versions
# ---------------------------------------------------------------------------
check_versions() {
  # cron does not have /usr/sbin in PATH, so also look there.
  local nginx_bin
  nginx_bin=$(command -v nginx || echo /usr/sbin/nginx)
  [[ -x $nginx_bin ]] || die "nginx is not installed."
  local info cur_nginx cur_openssl outdated=0
  info=$("$nginx_bin" -V 2>&1)
  cur_nginx=$(sed -nE 's|^nginx version: nginx/([0-9.]+).*|\1|p' <<<"$info")
  cur_openssl=$(sed -nE 's|^built with OpenSSL ([0-9.]+).*|\1|p' <<<"$info")
  resolve_versions
  echo
  printf '  installed: nginx %s, OpenSSL %s\n' "$cur_nginx" "$cur_openssl"
  printf '  latest:    nginx %s, OpenSSL %s\n' "$NGINX_VERSION" "$OPENSSL_VERSION"
  [[ $cur_nginx == "$NGINX_VERSION" ]] || outdated=1
  [[ $cur_openssl == "$OPENSSL_VERSION" ]] || outdated=1
  if (( outdated )); then
    echo "  Result: a new version is available. Run the script to update nginx."; exit 1
  fi
  echo "  Result: nginx is up to date."
}

# ---------------------------------------------------------------------------
# Download the source code and make sure that the signatures are correct
# ---------------------------------------------------------------------------
import_keys() {
  local ks fpr
  for fpr in "$@"; do
    for ks in "${keyservers[@]}"; do
      fetch "$ks$fpr" 2>/dev/null | gpg --batch --quiet --import 2>/dev/null || true
      gpg --batch --list-keys "$fpr" &>/dev/null && continue 2
    done
    die "Cannot download the OpenPGP key $fpr from a keyserver."
  done
}

# verify <signature> <file> <allowed fingerprint>...
# Accept the file only if two conditions are true:
#   1. The signature is correct.
#   2. One of the allowed keys (or one of its subkeys) made the signature.
#      A subkey is a second key that belongs to a main key.
# "gpg --verify" alone accepts a signature from each key in the keyring.
verify() {
  local sig=$1 file=$2; shift 2
  local status signer fpr
  status=$(gpg --batch --status-fd 1 --verify "$sig" "$file" 2>/dev/null) \
    || die "The signature of $file is not correct, or it is missing."
  # Line format: VALIDSIG <signature key> ... <primary key>
  signer=$(awk '$2 == "VALIDSIG" { print $NF }' <<<"$status")
  for fpr in "$@"; do
    if [[ $signer == "$fpr" ]]; then
      echo "  OK  $file  (signed by $signer)"
      return 0
    fi
  done
  die "An unknown key signed $file: '${signer:-none}'. The script stops."
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
    warn "The download from zlib.net failed. The script tries GitHub."
    fetch -o "$z.tar.gz"     "$url_zlib_gh/v$ZLIB_VERSION/$z.tar.gz"
    fetch -o "$z.tar.gz.asc" "$url_zlib_gh/v$ZLIB_VERSION/$z.tar.gz.asc"
  fi

  log "Making sure that the OpenPGP signatures are correct"
  GNUPGHOME=$(mktemp -d)
  export GNUPGHOME
  import_keys "${keys_nginx[@]}" "${keys_openssl[@]}" "${keys_pcre2[@]}" "${keys_zlib[@]}"
  verify "$n.tar.gz.asc" "$n.tar.gz" "${keys_nginx[@]}"
  verify "$o.tar.gz.asc" "$o.tar.gz" "${keys_openssl[@]}"
  verify "$p.tar.gz.sig" "$p.tar.gz" "${keys_pcre2[@]}"
  verify "$z.tar.gz.asc" "$z.tar.gz" "${keys_zlib[@]}"

  log "Unpacking the archives"
  local archive
  for archive in "$n" "$o" "$p" "$z"; do
    tar --no-same-owner -xzf "$archive.tar.gz"
    [[ -d $archive ]] || die "$archive.tar.gz does not contain the folder $archive/."
  done
  rm -f ./*.tar.gz ./*.tar.gz.asc ./*.tar.gz.sig
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
install_build_deps() {
  log "Installing the packages that the build needs"
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

  # Hardening flags (compiler flags that make attacks more difficult).
  # They are the same as Debian uses (dpkg-buildflags hardening=+all).
  # The script writes them out, so the result is the same on each Debian release.
  harden="-fstack-protector-strong -fstack-clash-protection"
  harden+=" -Wformat -Werror=format-security"
  case $arch in
    aarch64|arm64) harden+=" -mbranch-protection=standard" ;;  # PAC and BTI: Arm CPU features that block code-reuse attacks. Older CPUs ignore them.
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

  # Each library keeps the optimization level that its developers use.
  # Without these flags, nginx gives PCRE2 and zlib an empty CFLAGS.
  # Then the compiler does not optimize them (-O0), and gzip is slow.
  cc_opt_nginx="-O2 $harden $cppflags $tune"
  cc_opt_pcre="-O2 $harden $cppflags $tune"
  cc_opt_zlib="-O3 $harden $cppflags $tune"

  # OpenSSL flags. They remove code that nginx does not use.
  #   no-tests no-docs   Do not build test programs and manual pages (saves time on a Pi).
  #   no-legacy          Remove old, weak algorithms (MD4, DES, RC4).
  #   enable-ktls        Allow kernel TLS (the Linux kernel encrypts the data). It stays off until you set
  #                      "ssl_conf_command Options KTLS" in nginx.
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

    # Modules (optional parts of nginx) that a Nextcloud server needs
    --with-threads                    # "aio threads" for large files
    --with-file-aio
    --with-http_ssl_module
    --with-http_v2_module
    --with-http_realip_module         # real client IP behind a proxy or tunnel
    --with-http_gzip_static_module
    --with-http_stub_status_module    # basic statistics. Limit access to it.

  )

  # Default modules that Nextcloud does not use. Less code gives attackers
  # less to attack. To keep one of them, add its name to KEEP_MODULES.
  # tunnel = CONNECT tunnels for a forward proxy (nginx 1.31 and later).
  local remove=(autoindex browser empty_gif geo grpc memcached mirror scgi
                split_clients ssi userid uwsgi tunnel)
  local help mod
  # "configure --help" ends with exit code 1, so ignore the exit code.
  help=$(./configure --help || true)
  for mod in "${remove[@]}"; do
    if [[ " $KEEP_MODULES " == *" $mod "* ]]; then continue; fi
    # Older nginx versions do not have all of these flags.
    if grep -q -- "--without-http_${mod}_module" <<<"$help"; then
      args+=("--without-http_${mod}_module")
    fi
  done

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
  log "Compiling with $JOBS parallel jobs. On a Raspberry Pi, this step takes the most time."
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

  # Make sure that the new nginx accepts your current configuration.
  # If it does not, stop before the script changes anything.
  # Example: your configuration uses a module that this build does not include.
  if [[ -f /etc/nginx/nginx.conf ]]; then
    log "Testing the existing configuration with the new nginx program"
    mkdir -p /var/cache/nginx /var/log/nginx
    objs/nginx -t -c /etc/nginx/nginx.conf \
      || die "The new nginx does not accept /etc/nginx/nginx.conf. \
The script installed nothing, and your current nginx continues to run. \
Add the missing module with EXTRA_CONFIGURE_ARGS, or change the configuration. \
Then run the script again."

    local backup
    backup=/etc/nginx-backup-$(date +%Y%m%d-%H%M%S)
    cp -a /etc/nginx "$backup"
    echo "  Backup of /etc/nginx: $backup"
  fi

  log "Installing"
  id -g www-data &>/dev/null || addgroup --system www-data
  id -u www-data &>/dev/null || adduser --system --no-create-home \
    --home /var/cache/nginx --shell /usr/sbin/nologin --ingroup www-data www-data
  install -d -m 0750 -o www-data -g www-data \
    /var/cache/nginx /var/cache/nginx/client_temp \
    /var/cache/nginx/proxy_temp /var/cache/nginx/fastcgi_temp
  # "make install" does not overwrite your configuration files.
  # It writes new reference copies with the name *.default (nginx.conf.default).
  # It keeps the previous program as /usr/sbin/nginx.old.
  make install

  install_service
}

install_service() {
  local unit=/etc/systemd/system/nginx.service
  if [[ -e $unit ]]; then
    echo "  $unit exists. The script did not change it."
  else
    echo "  Writing $unit"
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

# Sandboxing (limits on what nginx can do on the system).
# nginx writes only to /var/log/nginx, /var/cache/nginx and /run.
# Do not add MemoryDenyWriteExecute=yes. PCRE2 JIT stops working with it.
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
      echo "  This file takes priority over /lib/systemd/system/nginx.service."
    fi
  fi

  # The process ID of an nginx that runs now. Empty if nginx does not run.
  local pid=""
  if [[ -s /run/nginx.pid ]]; then
    pid=$(cat /run/nginx.pid)
    kill -0 "$pid" 2>/dev/null || pid=""
  fi

  if ! command -v systemctl >/dev/null || [[ ! -d /run/systemd/system ]]; then
    if [[ -n $pid ]]; then
      echo "  nginx runs without systemd. It uses the old program until you restart it."
      echo "  To restart it, run: sudo kill -QUIT $pid && sudo /usr/sbin/nginx"
    fi
    return 0
  fi

  systemctl daemon-reload
  if systemctl is-active --quiet nginx; then
    log "Restarting nginx"
    systemctl restart nginx
  elif [[ -n $pid ]]; then
    # Older versions of the README started nginx with "sudo nginx", not with
    # systemd. Stop that nginx, then start the new nginx with systemd.
    log "Stopping the nginx that systemd did not start, and starting it with systemd"
    stop_pid "$pid"
    systemctl enable --now nginx
  else
    echo "  To start nginx, run: sudo systemctl enable --now nginx"
    return 0
  fi

  if systemctl is-active --quiet nginx; then
    echo "  nginx runs."
  else
    die "nginx did not start. To see the cause, run: sudo journalctl -u nginx -n 30 \
The old program is /usr/sbin/nginx.old. The README section \"The service file\" explains how to go back."
  fi
}

# Stop an nginx master process. First wait up to 10 seconds for open
# connections to finish (QUIT). Then stop it at once (TERM).
stop_pid() {
  local pid=$1 _
  kill -QUIT "$pid" 2>/dev/null || return 0
  for _ in {1..20}; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.5
  done
  kill -TERM "$pid" 2>/dev/null || return 0
  for _ in {1..10}; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.5
  done
  die "nginx (process $pid) did not stop. Stop it, then run: sudo systemctl enable --now nginx"
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
    DIE_CODE=2
    for c in curl jq; do command -v "$c" >/dev/null || die "--check needs $c. Install it with: sudo apt install $c"; done
    check_versions
    exit 0
  fi

  [[ $EUID -eq 0 ]] || die "Run the script as root or with sudo."

  # An nginx package from apt uses the same files: /usr/sbin/nginx and /etc/nginx.
  # The two installations overwrite each other, so stop.
  if { dpkg-query -W -f='${Status}\n' nginx nginx-common nginx-core nginx-full \
         nginx-light nginx-extras 2>/dev/null || true; } | grep -c '^install ok installed' >/dev/null; then
    die "An nginx package from apt is installed. Remove it first: sudo apt remove nginx nginx-common"
  fi

  BUILD_DIR=$(realpath -m "$BUILD_DIR")
  [[ $(dirname "$BUILD_DIR") != / ]] || die "BUILD_DIR=$BUILD_DIR is directly below /. The script deletes this folder. Use a subfolder."
  trap 'rm -rf "${GNUPGHOME:-/nonexistent}"' EXIT

  install_build_deps
  resolve_versions
  compute_flags
  download_sources
  configure_nginx
  build_nginx

  if (( build_only )); then
    log "Build complete in $(( SECONDS / 60 )) minutes: $BUILD_DIR/nginx-$NGINX_VERSION/objs/nginx"
    echo "  The script did not install it. To build and install, run the script without --build-only."
    exit 0
  fi

  install_nginx
  if (( ! KEEP_BUILD )); then
    rm -rf "$BUILD_DIR"
  fi
  log "Installed nginx $NGINX_VERSION with OpenSSL $OPENSSL_VERSION. Total time: $(( SECONDS / 60 )) minutes."
}

main "$@"
