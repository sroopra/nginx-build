# NGINX Build Script

This script builds NGINX from source with the latest OpenSSL, PCRE2 and zlib,
all linked statically. It is tuned for running Nextcloud on a Raspberry Pi
(Raspberry Pi OS / Debian), and works on other Debian-based distros too.

What it does:

* Looks up the latest versions: nginx mainline or stable, OpenSSL 3.5 LTS by default, PCRE2 and zlib.
* Downloads them over HTTPS only.
* Checks each archive's OpenPGP signature against that project's own pinned
  signing keys.
* Compiles with Debian's hardening flags (stack protector, stack-clash
  protection, `_FORTIFY_SOURCE`, full RELRO/BIND_NOW, branch protection on
  arm64). It also compiles PCRE2 and zlib with optimisation, which nginx
  leaves out by default.
* Builds only the modules a Nextcloud server needs, which means less code that can be attacked.
* Before installing, checks that your existing `/etc/nginx` config works with
  the new binary, and makes a backup.
* Installs a sandboxed systemd unit and restarts nginx only once the build has
  succeeded.

Compiling takes a while on a Raspberry Pi, mostly for OpenSSL. The number of parallel jobs is limited by free memory, so
small boards don't run out of RAM.

## Should you build from source at all?

Be honest with yourself about this first:

* **Easiest and safe:** the official nginx.org packages
  (<https://nginx.org/en/linux_packages.html>, Debian bookworm/trixie, arm64).
  `apt upgrade` and unattended-upgrades bring in security fixes
  automatically.
* **This script:** gives you the newest OpenSSL whatever your distro ships
  (e.g. post-quantum hybrid key exchange and native QUIC with OpenSSL 3.5+),
  and a smaller set of modules.
  The trade-off is that **you have to re-run it yourself for every nginx or
  OpenSSL security release**, because nothing updates a statically linked
  binary for you. nginx's changelog lists 36 security fixes in 2026 alone. Use `--check` (see below) so you don't miss them.

Compile flags won't make Nextcloud noticeably faster either way. On a Pi the
bottlenecks are PHP-FPM, the database and storage (use an SSD, not an SD card).
See [Performance notes](#performance-notes-for-nextcloud-on-a-pi).

## Usage

### Installation

```bash
sudo mkdir -p /usr/local/src/nginx && cd /usr/local/src/nginx
sudo curl -fL https://raw.githubusercontent.com/sroopra/nginx-build/master/build-nginx.sh -o build-nginx.sh
less build-nginx.sh     # review the code before running it
sudo bash build-nginx.sh
sudo systemctl enable --now nginx
```

If nginx from apt is installed, the script stops: the two would fight over
`/usr/sbin/nginx` and `/etc/nginx`. Remove it first with
`sudo apt remove nginx nginx-common`; your `/etc/nginx` config is kept.

### Upgrading

Download the latest script as above and run it again. Your running nginx keeps
serving during the build. The script then checks your config against the new
binary, backs up `/etc/nginx` to `/etc/nginx-backup-<date>`, installs the new
binary and restarts nginx. `make install` never overwrites your config files;
it only refreshes the `*.default` reference copies.

### Getting told about updates

`--check` compares the installed nginx and OpenSSL with the latest upstream
versions and exits with status 1 if a rebuild is due. It doesn't need root.
For example, in `crontab -e`:

```
0 7 * * * /usr/local/src/nginx/build-nginx.sh --check >/dev/null || echo "nginx rebuild due" | mail -s nginx you@example.com
```

Also consider subscribing to the nginx-announce list and to OpenSSL's security
advisories.

### Options

| Variable / flag | Default | Meaning |
| --- | --- | --- |
| `--build-only` | | Compile but don't install |
| `--check` | | Report whether a rebuild is due |
| `NGINX_BRANCH` | `mainline` | `mainline` (what nginx recommends) or `stable` |
| `OPENSSL_SERIES` | `3.5` | `3.5` = LTS, supported until 2030-04-08. `4.1` etc. are supported for about 13 months. `latest` = newest |
| `NGINX_VERSION`, `OPENSSL_VERSION`, `PCRE2_VERSION`, `ZLIB_VERSION` | latest | Pin an exact version |
| `WITH_HTTP3` | `1` | Build HTTP/3 (QUIC) support. Turn it on in the config with `listen 443 quic;` |
| `WITH_STREAM` | `0` | Build the TCP/UDP `stream` proxy |
| `CPU_TUNE` | off | `native` adds `-mcpu=native`. The gain is tiny, and the binary will crash on an older CPU (e.g. SD card moved from a Pi 5 to a Pi 4) |
| `EXTRA_CONFIGURE_ARGS` | | Extra `./configure` options, e.g. `--with-http_sub_module` |
| `JOBS` | based on RAM | Parallel compile jobs |
| `BUILD_DIR` | `./build` | Build directory (deleted afterwards unless `KEEP_BUILD=1`) |

Example: `sudo NGINX_BRANCH=stable WITH_STREAM=1 bash build-nginx.sh`

### Modules

Built in: SSL, HTTP/2, HTTP/3, realip, gzip_static, stub_status, threads
(`aio threads`), plus nginx's default modules: fastcgi, gzip, rewrite, map,
proxy, limit_req, auth_basic, …

Left out because Nextcloud doesn't use them: autoindex, browser, empty_gif,
geo, grpc, memcached, mirror, scgi, split_clients, ssi, userid, uwsgi, tunnel
(1.31+) and stream.

Older versions of this script also built **auth_request, gunzip, mp4,
secure_link, slice, sub and stream**. If your config uses any of these, the
config check stops the upgrade before anything is installed. Add them back,
e.g. `EXTRA_CONFIGURE_ARGS="--with-http_auth_request_module"` (or
`WITH_STREAM=1`).

## Performance notes for Nextcloud on a Pi

* Follow the official Nextcloud nginx configuration:
  <https://docs.nextcloud.com/server/latest/admin_manual/installation/nginx.html>.
  Use `http2 on;`, and optionally `listen 443 quic reuseport;` together with an
  `Alt-Svc` header for HTTP/3.
* **Raspberry Pi 4** CPUs have no AES hardware acceleration, so ChaCha20 is
  much faster there than AES-GCM. Keep `ssl_prefer_server_ciphers off;` (the
  default) so phones and browsers without AES hardware can choose
  ChaCha20-Poly1305. The Pi 5 does have AES instructions.
* Keep `gzip_comp_level` low (4 is what Nextcloud suggests). Higher levels cost
  CPU for very little saving.
* `ssl_session_cache shared:SSL:10m;` and `ssl_session_timeout 1d;` avoid
  repeating full TLS handshakes.
* Most of the speed comes from PHP: enable OPcache and JIT, use APCu for the
  local cache and Redis for file locking, and size `pm.max_children` to your
  RAM.

## Issues

If you have any problems with or questions about this script, please open a
[GitHub issue](https://github.com/sroopra/nginx-build/issues).

## Contributing

You are invited to contribute fixes and/or updates.

## Acknowledgments

Forked from [MatthewVance/nginx-build](https://github.com/MatthewVance/nginx-build).
The script was originally based on the [build_nginx.sh](https://gist.github.com/MattWilcox/402e2e8aa2e1c132ee24) script from [@MattWilcox](https://github.com/MattWilcox), but revised over time. You can find more details about the other Matt's version in his [blog post](https://mattwilcox.net/web-development/setting-up-a-secure-website-with-https-and-spdy-support-under-nginx-on-a-raspberry-pi).

## License

Unless otherwise specified, all code is released under the MIT License (MIT). See the [repository's `LICENSE` file](LICENSE) for details.
