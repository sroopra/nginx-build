# nginx build script for Nextcloud on a Raspberry Pi

This script builds nginx from source code and installs it. It is for a Nextcloud server on Raspberry Pi OS or another Debian-based system. To install, read [Before you start](#before-you-start), then do the 5 steps in [Install](#install).

## Before you start

You can get nginx in two ways:

1. Official nginx.org packages. If you want the least work, use these. `apt upgrade` installs each security fix automatically. The instructions are at <https://nginx.org/en/linux_packages.html>.
2. This script. It gives you the newest OpenSSL and a smaller nginx. You must run the script again for each security fix. nginx published 36 security fixes in 2026.

The speed of Nextcloud on a Pi depends mostly on PHP, the database and the disk. The choice between 1 and 2 has almost no effect on speed.

If the system has an nginx package from apt, remove that package first. The script stops if it finds one. This command keeps your configuration in `/etc/nginx`:

```bash
sudo apt remove nginx nginx-common
```

Do not run this command until you are ready to install. It stops nginx, so Nextcloud is offline until you complete step 5 of Install.

## Install

Do these steps on the Pi:

1. Make a folder for the script:

   ```bash
   sudo mkdir -p /usr/local/src/nginx && cd /usr/local/src/nginx
   ```

2. Download the script:

   ```bash
   sudo curl -fL https://raw.githubusercontent.com/sroopra/nginx-build/master/build-nginx.sh -o build-nginx.sh
   ```

3. Read the script before you run it:

   ```bash
   less build-nginx.sh
   ```

4. Run the script. No one measured the build time on a Pi yet. The script shows the total time at the end. Write it down, because it is your estimate for later runs.

   ```bash
   sudo bash build-nginx.sh
   ```

5. Start nginx, and start it automatically after each reboot:

   ```bash
   sudo systemctl enable --now nginx
   ```

To make sure that nginx runs, run `systemctl is-active nginx`. The output is `active`. Then open your Nextcloud address in a browser.

## Update

Do these steps on the Pi:

1. Go to the folder of the script:

   ```bash
   cd /usr/local/src/nginx
   ```

2. Download the latest script:

   ```bash
   sudo curl -fL https://raw.githubusercontent.com/sroopra/nginx-build/master/build-nginx.sh -o build-nginx.sh
   ```

3. Read the script, then run it. The update takes about as long as your first run.

   ```bash
   sudo bash build-nginx.sh
   ```

Your current nginx continues to serve Nextcloud during the build. After the build, the script does these steps:

1. It makes sure that the new nginx accepts your configuration. If not, it stops and changes nothing.
2. It copies `/etc/nginx` to `/etc/nginx-backup-<date>`.
3. It installs the new nginx. Your configuration files stay as they are. The old program stays as `/usr/sbin/nginx.old`.
4. It restarts nginx with systemd, and makes sure that nginx runs again.

Nextcloud is offline only during step 4. Usually this takes 1 or 2 seconds. If a download or an upload is in progress, nginx waits for it, but for 10 seconds at most.

If you started nginx with `sudo nginx` and not with systemd, the script stops that nginx. Then it starts nginx with systemd, and nginx also starts after each reboot.

## Get an email when an update is available

To compare your nginx and OpenSSL with the latest versions, run `bash /usr/local/src/nginx/build-nginx.sh --check`. This command does not need root, but it needs curl and jq. The first run of the script installs them.

The exit codes of `--check` are:

| Exit code | Meaning |
| --- | --- |
| 0 | nginx and OpenSSL are up to date. |
| 1 | A new version is available. |
| 2 | The comparison failed, for example because the network is down. |

To get an email each morning when an update is available:

1. Run `crontab -e`.
2. Add the line below.
3. Change `you@example.com` to your email address.
4. Save the file and close the editor.

```
0 7 * * * bash /usr/local/src/nginx/build-nginx.sh --check >/dev/null 2>&1 || echo "nginx: update available, or the check failed" | mail -s nginx you@example.com
```

If you build with `NGINX_BRANCH` or `OPENSSL_SERIES`, put the same values before `bash` in this line.

## Will this break my Nextcloud?

If you use the standard Nextcloud configuration, this script does not break Nextcloud. nginx consists of modules (optional parts that the build includes or leaves out). This script includes each module that Nextcloud needs: SSL, HTTP/2, PHP (FastCGI), gzip, rewrites and headers.

This version leaves out modules that older versions of this script included. Nextcloud does not use them, and less code gives attackers less to attack. There are two groups.

Extra modules that older versions added:

| Module | What it does |
| --- | --- |
| auth_request | A login page in front of a site, for example Authelia |
| mp4 | Special video streaming. Nextcloud sends videos through PHP. |
| gunzip, sub, slice, secure_link | Special changes to responses |
| stream | A proxy for TCP and UDP traffic, not for websites |

Default modules of nginx that this version removes:

| Module | What it does |
| --- | --- |
| autoindex | Lists the files of a folder |
| grpc, memcached, scgi, uwsgi | Connections to other kinds of backend servers |
| browser, mirror, userid | Browser detection, request copies and user cookies |
| tunnel | A forward proxy (nginx 1.31 and later) |

To find out if your configuration uses one of these modules, run this command:

```bash
sudo nginx -T 2>/dev/null | grep -nE '(^|[{;])\s*(auth_request|mp4|gunzip|secure_link|slice|sub_filter|autoindex|ancient_browser|modern_browser|grpc_|memcached_|mirror|scgi_|userid|uwsgi_|tunnel_)\w*|^\s*stream\s*\{'
```

If the command shows no output, your configuration uses none of them.

If the command shows a line, keep that module in the build:

1. For a module from the first table, use `EXTRA_CONFIGURE_ARGS`. Example: `sudo EXTRA_CONFIGURE_ARGS="--with-http_auth_request_module" bash build-nginx.sh`
2. For the stream module, use `WITH_STREAM=1`.
3. For a module from the second table, use `KEEP_MODULES`. Example: `sudo KEEP_MODULES="autoindex" bash build-nginx.sh`

If you forget this step, nothing breaks. The script tests your configuration with the new nginx before it installs anything. If the test fails, the script stops and installs nothing. On an update, your current nginx continues to run.

## HTTP/3

HTTP/3 is a newer protocol between the browser and the server. On weak mobile networks, it can be a little faster. Nextcloud works without it.

The script includes HTTP/3 in the build, but HTTP/3 stays off. You do not have to do anything. To leave it out of the build, set `WITH_HTTP3=0`.

To turn HTTP/3 on:

1. Add `listen 443 quic reuseport;` to your `server` block.
2. Add `add_header Alt-Svc 'h3=":443"; ma=86400';` to the same block.
3. Open UDP port 443 in your firewall and your router.
4. Run `sudo nginx -t && sudo systemctl reload nginx`.

## The service file

The script writes a systemd service file to `/etc/systemd/system/nginx.service`. This file limits what nginx can do on the system. For example, nginx cannot write to system folders or home folders. A standard Nextcloud setup does not need these permissions.

Older versions of this script wrote the file to `/lib/systemd/system/nginx.service`. The new file takes priority over the old file. If the script finds a file in `/etc/systemd/system`, it does not change it.

If nginx does not start after an update from an older version of this script, go back to the old service file:

1. Remove the new file:

   ```bash
   sudo rm /etc/systemd/system/nginx.service
   ```

2. Load the old file:

   ```bash
   sudo systemctl daemon-reload
   ```

3. Restart nginx:

   ```bash
   sudo systemctl restart nginx
   ```

These steps work only if `/lib/systemd/system/nginx.service` exists. The next run of the script writes the new file again.

## Variables and flags

To change how the script builds nginx, set environment variables before the command. Example:

```bash
sudo NGINX_BRANCH=stable WITH_STREAM=1 bash build-nginx.sh
```

Versions:

| Variable | Default | Meaning |
| --- | --- | --- |
| `NGINX_BRANCH` | `mainline` | `mainline` gets all fixes first, and the nginx team recommends it. `stable` gets only important fixes. |
| `OPENSSL_SERIES` | `3.5` | `3.5` has long-term support until 2030-04-08. `4.1` has support for about 13 months. `latest` selects the newest. |
| `NGINX_VERSION`, `OPENSSL_VERSION`, `PCRE2_VERSION`, `ZLIB_VERSION` | latest | Set one exact version, for example `NGINX_VERSION=1.31.9`. |

Modules:

| Variable | Default | Meaning |
| --- | --- | --- |
| `WITH_HTTP3`, `WITH_STREAM` | `1`, `0` | Include HTTP/3 or the stream module. |
| `EXTRA_CONFIGURE_ARGS` | empty | Add modules. Example: `--with-http_sub_module` |
| `KEEP_MODULES` | empty | Keep default modules that the script removes. Example: `autoindex grpc` |

Build:

| Variable | Default | Meaning |
| --- | --- | --- |
| `CPU_TUNE` | off | `native` optimizes for this CPU. The gain is small. On an older CPU, nginx can stop with the error SIGILL. Example: you move the SD card from a Pi 5 to a Pi 4. |
| `JOBS` | 1 job for each 400 MB of free memory | The number of parallel compile jobs. The minimum is 1. The maximum is the number of CPU cores. |
| `BUILD_DIR`, `KEEP_BUILD` | `build` in the current folder, `0` | The build folder. The script deletes this folder at the start of each run. Do not use a folder that contains other files. At the end, the script deletes it again, unless `KEEP_BUILD=1` or `--build-only`. |

Flags:

| Flag | Meaning |
| --- | --- |
| `--build-only` | Build nginx, but do not install it. |
| `--check` | Compare the installed versions with the latest versions. |
| `--help` | Show all variables and flags. |

## What the script does for security and speed

The 5 measures are:

1. A signature is cryptographic proof of who made a file. The script downloads with HTTPS only. It makes sure that each file has a signature from the key of its own project.
2. It puts OpenSSL, PCRE2 and zlib into the nginx program file. Thus, OpenSSL updates from apt do not change nginx.
3. It builds with the same hardening flags as Debian. Hardening flags make attacks on the program more difficult.
4. It optimizes PCRE2 and zlib. Without the script's flags, nginx builds them without optimization, and gzip is slower.
5. It limits the number of parallel jobs to the free memory. Thus, a Pi with 1 GB of memory does not run out of memory.

## Speed tips for Nextcloud on a Pi

1. Use the Nextcloud nginx configuration: <https://docs.nextcloud.com/server/latest/admin_manual/installation/nginx.html>.
2. Keep Nextcloud data on an SSD, not on the SD card.
3. Turn on PHP OPcache and APCu. Use Redis for file locking.
4. On a Pi 4, keep `ssl_prefer_server_ciphers off;`. The Pi 4 CPU has no AES hardware, and this lets clients select the faster ChaCha20 cipher.
5. Keep `gzip_comp_level` at 4. Higher levels use more CPU and make files only a little smaller.

## Help and license

To report a problem or ask a question, open a [GitHub issue](https://github.com/sroopra/nginx-build/issues). Fixes and updates are welcome. The code uses the MIT License. See the [`LICENSE`](LICENSE) file.

## Acknowledgments

This repository is a fork of [MatthewVance/nginx-build](https://github.com/MatthewVance/nginx-build). The first version of the script came from the [build_nginx.sh](https://gist.github.com/MattWilcox/402e2e8aa2e1c132ee24) script by [@MattWilcox](https://github.com/MattWilcox). His [blog post](https://mattwilcox.net/web-development/setting-up-a-secure-website-with-https-and-spdy-support-under-nginx-on-a-raspberry-pi) gives more details.
