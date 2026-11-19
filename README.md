# nginx build script for Nextcloud on a Raspberry Pi

This script builds nginx from source code and installs it. It is for a Nextcloud server on Raspberry Pi OS or another Debian-based system. To install, do the 5 steps in [Install](#install).

## Before you start

You can get nginx in two ways:

1. Official nginx.org packages. Use these if you want the least work. `apt upgrade` installs each security fix automatically. Instructions: <https://nginx.org/en/linux_packages.html>.
2. This script. It gives you the newest OpenSSL and a smaller nginx. You must run the script again for each security fix. nginx published 36 security fixes in 2026.

The speed of Nextcloud on a Pi depends mostly on PHP, the database and the disk. The choice between 1 and 2 has almost no effect on speed.

If an nginx package from apt is installed, remove it first. The script stops if it finds one. This command keeps your configuration in `/etc/nginx`:

```bash
sudo apt remove nginx nginx-common
```

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

4. Run the script. The build takes the most time. The script shows the total time at the end.

   ```bash
   sudo bash build-nginx.sh
   ```

5. Start nginx, and start it automatically after each reboot:

   ```bash
   sudo systemctl enable --now nginx
   ```

The build time on a Pi is not measured yet. Use the time from your first run as the estimate for later runs.

## Update

Do the same steps 1 to 4 again. Your current nginx continues to serve Nextcloud during the build.

After the build, the script does these steps in this order:

1. It makes sure that the new nginx accepts your configuration. If not, it stops and changes nothing.
2. It copies `/etc/nginx` to `/etc/nginx-backup-<date>`.
3. It installs the new nginx. Your configuration files stay as they are.
4. It restarts nginx.

## Get a message when an update is available

Use `--check` to compare your nginx and OpenSSL with the latest versions. This flag does not need root. Exit code 1 means that a new version is available.

To get an email each morning when an update is available, add this line with `crontab -e`:

```
0 7 * * * /usr/local/src/nginx/build-nginx.sh --check >/dev/null || echo "nginx update available" | mail -s nginx you@example.com
```

## Will this break my Nextcloud?

No, if you use the standard Nextcloud configuration. nginx consists of modules (optional parts that the build includes or leaves out). This script includes each module that Nextcloud needs: SSL, HTTP/2, PHP (FastCGI), gzip, rewrites and headers.

Older versions of this script also included 7 modules that Nextcloud does not use. This version leaves them out, because less code gives attackers less to attack. The table shows them:

| Module | What it does |
| --- | --- |
| auth_request | A login page in front of a site, for example Authelia |
| mp4 | Special video streaming. Nextcloud sends videos through PHP. |
| gunzip, sub, slice, secure_link | Special changes to responses |
| stream | A proxy for TCP and UDP traffic, not for websites |

To find out if your configuration uses one of these modules, run this command:

```bash
sudo nginx -T 2>/dev/null | grep -nE 'auth_request|mp4|gunzip|secure_link|slice|sub_filter|stream *\{'
```

If the command shows no output, your configuration uses none of them.

If the command shows a line, add the module to the build. Example for auth_request:

```bash
sudo EXTRA_CONFIGURE_ARGS="--with-http_auth_request_module" bash build-nginx.sh
```

If you forget this step, nothing breaks. The script tests your configuration with the new nginx before it installs anything. If the test fails, the script stops, and your current nginx continues to run.

## HTTP/3

HTTP/3 is a newer protocol between the browser and the server. On weak mobile networks, it can be a little faster. Nextcloud works without it.

The script includes HTTP/3 in the build, but HTTP/3 stays off. You do not have to do anything. To turn it on, add `listen 443 quic reuseport;` and an `Alt-Svc` header to your nginx configuration. To leave it out of the build, set `WITH_HTTP3=0`.

## The service file

The script writes a systemd service file to `/etc/systemd/system/nginx.service`. This file limits what nginx can do on the system. For example, nginx cannot write to system folders or home folders. A standard Nextcloud setup does not need these permissions.

Older versions of this script wrote the file to `/lib/systemd/system/nginx.service`. The new file takes priority over the old file. If the script finds a file in `/etc/systemd/system`, it does not change it.

If nginx does not start after the update, go back to the old service file with these 3 commands:

```bash
sudo rm /etc/systemd/system/nginx.service
```

```bash
sudo systemctl daemon-reload
```

```bash
sudo systemctl restart nginx
```

## Configuration

To change the configuration, set environment variables before the command. Example:

```bash
sudo NGINX_BRANCH=stable WITH_STREAM=1 bash build-nginx.sh
```

Versions:

| Variable | Default | Meaning |
| --- | --- | --- |
| `NGINX_BRANCH` | `mainline` | `mainline` gets all fixes first, and the nginx team recommends it. `stable` gets only important fixes. |
| `OPENSSL_SERIES` | `3.5` | `3.5` has long-term support until 2030-04-08. `4.1` has support for about 13 months. `latest` selects the newest. |
| `NGINX_VERSION`, `OPENSSL_VERSION`, `PCRE2_VERSION`, `ZLIB_VERSION` | latest | Set one exact version, for example `NGINX_VERSION=1.31.9`. |

Build:

| Variable | Default | Meaning |
| --- | --- | --- |
| `WITH_HTTP3`, `WITH_STREAM` | `1`, `0` | Include HTTP/3 or the stream module. |
| `EXTRA_CONFIGURE_ARGS` | empty | Add modules. Example: `--with-http_sub_module` |
| `CPU_TUNE` | off | `native` optimizes for this CPU. The gain is small. On an older CPU, nginx does not start, for example after you move the SD card from a Pi 5 to a Pi 4. |
| `JOBS` | 1 job for each 400 MB of free memory | The number of parallel compile jobs. |
| `BUILD_DIR`, `KEEP_BUILD` | `./build`, `0` | The build folder. The script deletes it at the end, unless `KEEP_BUILD=1`. |

Flags:

| Flag | Meaning |
| --- | --- |
| `--build-only` | Build nginx, but do not install it. |
| `--check` | Compare the installed versions with the latest versions. |
| `--help` | Show all variables and flags. |

## What the script does for security and speed

The script does these 5 things:

1. It downloads with HTTPS only. It makes sure that each project's own signing key signed each file. A signature is cryptographic proof of who made a file.
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

## Issues

To report a problem or ask a question, open a [GitHub issue](https://github.com/sroopra/nginx-build/issues).

## Contributing

Fixes and updates are welcome.

## Acknowledgments

This repository is a fork of [MatthewVance/nginx-build](https://github.com/MatthewVance/nginx-build). The first version of the script came from the [build_nginx.sh](https://gist.github.com/MattWilcox/402e2e8aa2e1c132ee24) script by [@MattWilcox](https://github.com/MattWilcox). His [blog post](https://mattwilcox.net/web-development/setting-up-a-secure-website-with-https-and-spdy-support-under-nginx-on-a-raspberry-pi) gives more details.

## License

The code uses the MIT License. See the [`LICENSE`](LICENSE) file.
