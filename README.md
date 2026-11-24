# nps-mirrorinstallsh

Mirror-aware one-shot installer for [nps / npc](https://github.com/djylb/nps).

The script no longer depends on a single download host. On every run it probes
GitHub, the jsDelivr CDN edges and several public GitHub proxies **in parallel**,
sorts them by the measured response time of the current network, downloads
through the fastest one, and falls back through the rest if a mirror fails.
Release tags are resolved through three independent routes, so a blocked
`api.github.com` does not break version detection.

Mirrors covered: `github`, `jsdelivr`, `fastly`, `gcore`, `testingcf`,
`ghproxy`, `ghproxycom`, `ghfast`, `gitmirror`, `moeyy`.

---

## Server Installation

### Linux

```bash
# Install the nps server through an auto-selected mirror
# (jsDelivr CDN edges -> GitHub proxies -> GitHub direct)
# default config path: /etc/nps/ ; binary path: /usr/bin/
curl -fsSL https://cdn.jsdelivr.net/gh/clockclock1/nps-mirrorinstallsh@main/install.sh | sudo sh -s nps

# Fallback entry points for networks where jsDelivr is blocked
curl -fsSL https://raw.githubusercontent.com/clockclock1/nps-mirrorinstallsh/main/install.sh | sudo sh -s nps
curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/clockclock1/nps-mirrorinstallsh/main/install.sh | sudo sh -s nps

sudo nps install
sudo nps start|stop|restart|uninstall

# Update
sudo nps update
sudo nps update-force
```

> **Tip:** For first-time setup, edit `/etc/nps/conf/nps.conf` and verify it before running `nps start`.
>
> **Mirror control:** probing is automatic. Pin the order with
> `sudo NPS_MIRROR_ORDER="jsdelivr,ghproxy,github" sh -s nps`, skip probing with
> `NPS_MIRROR_PROBE=0`, replace the candidate list with `NPS_MIRRORS="jsdelivr,github"`,
> or force GitHub only with `NPS_NO_MIRROR=1`.

## Client Installation

### Linux

```bash
curl -fsSL https://cdn.jsdelivr.net/gh/clockclock1/nps-mirrorinstallsh@main/install.sh | sudo sh -s npc
sudo /usr/bin/npc install -launch="npc://YOUR_VKEY@203.0.113.10:8024?type=tls"
sudo npc start|stop|restart|uninstall

# Update
sudo npc update
sudo npc update-force
```

> **Tip:** Use the launch command generated on the client page of the NPS Web UI.

---

## Usage

```text
sh install.sh [mode] [version] [install_dir]

mode         npc | nps | all           (default: all)
version      release tag, e.g. v0.35.6 (default: latest)
install_dir  extract only, do not touch /usr/bin or /etc/nps
```

Examples:

```bash
# Install a pinned version
curl -fsSL https://cdn.jsdelivr.net/gh/clockclock1/nps-mirrorinstallsh@main/install.sh | sudo sh -s nps v0.35.6

# Download and extract only, no system changes
sh install.sh all latest /tmp/nps-pkg

# Pin the mirror order (skips probing)
NPS_MIRROR_ORDER="gcore,jsdelivr,github" sudo sh install.sh nps
```

### Environment variables

| Variable | Meaning | Default |
| --- | --- | --- |
| `NPS_MIRROR_ORDER` | fixed mirror order, e.g. `jsdelivr,ghproxy,github`; skips probing | auto |
| `NPS_MIRRORS` | replace the candidate mirror list | built-in 10 mirrors |
| `NPS_MIRROR_PROBE=0` | disable probing, use the built-in order | probing on |
| `NPS_PROBE_TIMEOUT` | per-mirror probe timeout, seconds | `4` |
| `NPS_CONNECT_TIMEOUT` | connect timeout for downloads, seconds | `10` |
| `NPS_DOWNLOAD_TIMEOUT` | total time allowed per download, seconds | `300` |
| `NPS_NO_MIRROR=1` | GitHub direct only | off |
| `NPS_IPV4=1` | force IPv4 for curl/wget | off |
| `NPS_INSECURE=1` | skip TLS verification | off |
| `NPS_INSTALL_MODE` / `NPS_INSTALL_VERSION` / `NPS_INSTALL_DIR` | same as the positional arguments | — |

## How mirror selection works

1. Every mirror gets a small ranged request (`install.sh`, 64 KiB cap) launched in
   parallel with a 4 second deadline.
2. Results are sorted by elapsed time; unreachable mirrors stay in the list as
   last-resort fallbacks instead of being dropped.
3. The release tarball is fetched from the first mirror that completes, and the
   measured latency of that attempt is printed.
4. If `/releases/latest` cannot be resolved, the script falls back to the CDN
   `@latest` alias, which jsDelivr resolves server-side.

The probe result reflects the network the script actually runs on, so a
mainland-China host normally picks `gcore` / `testingcf` / `ghproxy`, while an
overseas host usually picks `github` or `jsdelivr`.

## Verified

Installed and executed on Debian 13 (x86_64) through the mirror path
(`gcore` / `testingcf` were selected automatically), then removed again:

```text
Version: 0.35.6
Core version: 0.34.0
```

## License

Same as upstream nps: see [LICENSE](LICENSE).
