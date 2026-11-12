# PingKit Agent for Docker and Raspberry Pi

**Your network, watched from something you already own: free on the device, and your iPhone
gets the alert.**

<!-- The badges render once github.com/pingkit/agent, the Docker Hub mirror pingkit/agent and
     github.com/pingkit/ha-apps exist (Paul creates them at launch; packaging.md "Paul owns"). -->
[![Image size](https://img.shields.io/docker/image-size/pingkit/agent/1?label=image)](https://hub.docker.com/r/pingkit/agent)
[![Docker pulls](https://img.shields.io/docker/pulls/pingkit/agent)](https://hub.docker.com/r/pingkit/agent)
[![Release](https://img.shields.io/github/v/release/pingkit/agent)](https://github.com/pingkit/agent/releases)
[![Add the repository to your Home Assistant](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fpingkit%2Fha-apps)

<!-- OWED, screenshot: an iPhone Lock Screen with the agent's Internet Down alert arriving,
     beside the agent's status page. A real capture only, never a mock-up. File it as
     docs/img/push-arriving.png and replace this comment with:
     ![An Internet Down alert from the agent arriving on an iPhone](docs/img/push-arriving.png) -->

PingKit Agent runs on a device of your own that stays on: a Linux computer or NAS with Docker,
a 64-bit Raspberry Pi 4 or 5, or Home Assistant. It watches your own network and tells you when
the internet goes down and comes back, when a new device joins, and, if you turn it on, when a
device goes offline. Its own pages, its alerts to your own services and its Home Assistant
entities are free. PingKit on your iPhone adds the push relay and the dashboard with PingKit
Guardian.

The agent is closed source. This repository holds what you need to run it and to check it: the
compose files, the Raspberry Pi install script, the Home Assistant app, the documentation and
the issue tracker.

## Run it with Docker (Linux)

Open PingKit on your iPhone, go to **Agents > Add an Agent**, and keep the 8-character code. It
works once, for 10 minutes. No iPhone? Leave the code empty: the agent still watches, shows its
pages and sends to your own services.

```yaml
# compose.yaml
services:
  pingkit-agent:
    image: ghcr.io/pingkit/agent:1
    restart: unless-stopped
    stop_grace_period: 20s
    network_mode: host
    read_only: true
    cap_drop: [ALL]
    user: "65532:65532"
    security_opt: [no-new-privileges:true]
    tmpfs: [/tmp:rw,noexec,nosuid,nodev,size=16m]
    mem_limit: 256m
    pids_limit: 64
    volumes: [pingkit-agent-data:/data]
    environment:
      PINGKIT_CLAIM_CODE: ""   # the code from your iPhone, used once
      # PINGKIT_NOTIFY_URLS: "ntfy://192.168.1.5/home-net"   # alerts to your own services
volumes:
  pingkit-agent-data:
```

`docker compose up -d`, then open `http://<the host's address>:7474/`.

**Why host networking.** `network_mode: host` is the one privilege the agent needs. It is how
the agent reads the neighbour (ARP) table and hears the Bonjour (mDNS) and UPnP (SSDP)
announcements your devices make; a bridge network hides all three. It also keeps the status
page honest: the page answers only private addresses, and behind a bridge every request would
seem to come from Docker's gateway. Everything else is taken away: no added capabilities, a
read-only file system, a non-root user, no privilege escalation, and no raw socket ever.

Docker Desktop on Windows and macOS cannot see your devices, because its host network stops
short of them. Use a Linux host. The full file with every option, and the files for Synology,
QNAP, TrueNAS SCALE, OpenMediaVault, CasaOS, Portainer and Unraid, are in
[`compose/`](compose/).

## Raspberry Pi

64-bit Raspberry Pi OS on a Raspberry Pi 4 or 5. The script refuses a 32-bit system.

```sh
curl -fsSL https://pingkit.app/agent/install.sh | sudo sh -s -- --claim-code <CODE>
```

The script checks the download's SHA-256 against the value pinned inside it before anything
runs, installs a systemd service that runs as its own unprivileged user, and prints the status
page address. `--update` and `--uninstall` do what they say. Rather read it first? Download
[`pi/install.sh`](pi/install.sh), read it, and run it with the same arguments; every release
also attaches the script, the tarball and its `.sha256`.

## Home Assistant

Press the **Add the repository** badge above, or in **Settings > Apps > Install app**, open
**Repositories** in the menu at the top right and add `https://github.com/pingkit/ha-apps`.
Install **PingKit Agent**, paste your code into **Claim code** and start it. (Before Home
Assistant 2026.2, apps were called add-ons.)

## What it does

- **Internet Down and Internet Restored.** One check a minute; Internet Down after three in a
  row fail, so about three minutes after the line drops, dated to the first failed check, and
  Internet Restored after two good checks in a row. A shorter drop leaves no entry.
- **Where the fault looks to be.** While something is wrong the agent checks your router, the
  first hop past it and DNS, and says which looks broken, with honest time bounds. Loss and
  latency are kept as a history.
- **New devices.** The agent spends its first day learning what is already yours, then tells
  you about a device it has not seen before.
- **Phones on private Wi-Fi addresses.** A phone whose private address changes looks new to
  most monitors. PingKit asks whether it is the device that just went quiet, and shows the
  evidence, instead of announcing a stranger.
- **Device Offline and Device Online**, if you turn them on: a device is reported offline after
  three missed sweeps, up to 45 minutes at the default 15-minute sweep.
- **A daily speed test** from the device that stays on, once it is paired, at a random minute
  each day (`PINGKIT_SPEED_TEST=manual` or `off` for a line with a data cap).
- **Its own pages**, read-only and in 27 languages: overview, devices, timeline, outages with a
  30-day chart, and diagnostics. The pages that name your devices sit behind a six-digit PIN.
- **Alerts to your own services**: a signed webhook (Home Assistant's webhook trigger, n8n,
  Node-RED), ntfy, Telegram, Discord, Pushover, and `apprise-api` for everything else, with
  per-target event filters and quiet hours.
- **Home Assistant entities over MQTT**: an internet connectivity sensor, device counts, the
  last outage, and a device tracker or connectivity sensor per device. In Home Assistant the
  broker's credentials come from the Supervisor, so you type nothing.
- **More than one network**: VLAN interfaces the host already has, and routed private subnets.
- **With PingKit on your iPhone**: the push for every alert kind, a Live Activity during an
  outage, a Home Screen widget, Control Center and Siri, the Apple Watch, the dashboard, an
  Internet Outage Report to send your provider, and Wake-on-LAN, ping and scan now from
  anywhere through the relay.

It watches; it does not block devices or change anything on your network.

## What leaves your network

The complete list. `scripts/check-agent-egress.py` holds the agent's source to it on every
build, so a new destination cannot arrive unseen.

| Destination | What, and when |
|---|---|
| PingKit's server, `monitor.pingkit.app` | Pairing (the claim code, and whether it runs in Docker, on a Raspberry Pi, in Home Assistant or elsewhere, and its CPU type). A check-in every five minutes: the agent's version, how long it has run, whether its internet check passed, and how many devices are online, a count and never a name. Alert events, which pass through to Apple's push service for your iPhone and are not stored: PingKit keeps the kind of event, how many and when. With the relay, one connection that carries commands from your iPhone, signed by your iPhone, and their sealed answers. |
| PingKit's speed endpoint, `speed.pingkit.app` | The daily speed test's traffic, unless you turn it off. |
| `pingkit.app/agent/latest.json` | The newest version's number and its signature, to tell you an update exists. |
| The internet check: `1.1.1.1`, `8.8.8.8`, `9.9.9.9` | A ping or a connection attempt; a DNS question for the name of PingKit's server, asked of your router and of `1.1.1.1`; once an hour, a short-lived probe toward `1.1.1.1` that finds the first hop past your router. More often while something is wrong. |
| Your own services | Only the notification targets and the MQTT broker you configure, and in Home Assistant its own Supervisor. |
| Your own network | Discovery queries, pings and connection attempts to devices on your own network. |

Nothing else. Apple's push service is reached through PingKit's server only. Your device list
stays on the agent: your iPhone reads it directly, on your network or through a VPN that routes
to it, over an encrypted connection the two set up when you pair. An alert may name the device
it is about on its way to your iPhone, but device names never rest on PingKit's servers. There
is no account.

## Free, and what Guardian adds

Running the agent is free, with or without an iPhone. The paid part is the relay and the
dashboard on your iPhone, and it funds the one person who builds PingKit.

| | Free | PingKit Guardian | Guardian Plus |
|---|---|---|---|
| The agent, its pages, alerts to your own services (webhook, ntfy, Telegram, Discord, Pushover, apprise-api), Home Assistant entities over MQTT | yes | yes | yes |
| Pair an iPhone, see the agent's state | yes | yes | yes |
| The agent's timeline on your iPhone | the last 24 hours | yes | yes |
| History shown, on the iPhone and on the agent's pages (the agent keeps a year on disk either way) | 30 days on the agent's pages | 90 days | 365 days |
| Push to your iPhone for every alert kind, the Live Activity, the widget, Control Center, Siri | | yes | yes |
| The dashboard: devices, outages, loss and latency, speed tests, Wake-on-LAN and other actions from the iPhone | | yes | yes |
| The Internet Outage Report for your provider | | yes | yes |
| Agents | 1 | 1 | up to 5 |
| Phones per agent | 1 | 1 | up to 5 |

Prices in US dollars, each plan with a 1-week free trial:

| | On iPhone | On Mac |
|---|---|---|
| PingKit Guardian | $2.99 a month or $24.99 a year | $2.99 a month or $24.99 a year |
| Guardian Plus | $9.99 a month or $79.99 a year | $4.99 a month or $39.99 a year |

A subscription bought on either device counts on both, and the higher tier wins.
<!-- OWED: the Guardian lifetime purchase ($69.99, plan decision 15) joins this table only once
     the product exists in App Store Connect and in the build. -->

## How it compares

Honest and dated; check each project's own pages before you decide.

| | PingKit Agent | Fing Agent | NetAlertX | WatchYourLAN |
|---|---|---|---|---|
| Cost to run | Free | A paid Fing plan: Premium $8.99 a month or $79.99 a year | Free | Free |
| Account | None | A Fing account | None | None |
| Source | Closed agent; local API, MQTT and webhooks | Closed | Open (GPL-3.0) | Open (MIT) |
| Alerts to ntfy, Telegram, Discord, Pushover or a webhook | Yes, free | No | Yes | Yes |
| A native iPhone app with push | Yes, with Guardian | Yes, in the Fing app | No | No |
| Home Assistant | Home Assistant app, entities over MQTT | Official integration (local polling) | Entities over MQTT | No |
| Internet outage log | Yes, with where the fault looks to be | Yes | Yes (a plugin) | No |
| Phones on private Wi-Fi addresses | Asks, with the evidence, whether it is a device it knows | Not matched | Flagged, not matched | Not matched |
| Web interface | Read-only pages; settings live on the iPhone | A status page for activation | Full | A host list and its history |

Fing Agent as published on fing.com/agent and fing.com/pricing, checked on 2026-11-09.
NetAlertX and WatchYourLAN as their own READMEs and documentation describe them, checked on
2026-11-07. NetAlertX does far more on a LAN than PingKit (plugins, router imports, a topology
map); if you want open source and a full web interface, it is the one to look at. Fing Agent
can block devices and set access schedules; PingKit Agent cannot.

## Checking what you run

From 1.0.0, every image is signed with cosign (keyless, through a GitHub sign-in) and carries
an SPDX software bill of materials per architecture. Each release's notes give the digest, the
signer and the command. To run exactly one signed build, pull it by digest and verify it:

```sh
docker pull ghcr.io/pingkit/agent:1.0.0@sha256:<digest from the release notes>
cosign verify ghcr.io/pingkit/agent@sha256:<digest> \
  --certificate-identity <the signer's email, printed in the release notes> \
  --certificate-oidc-issuer https://github.com/login/oauth
```

`:1` moves to each new 1.x release. The Raspberry Pi tarball's SHA-256 is pinned in the same
release's install script and checked before anything runs.

## If PingKit ends

Our continuity pledge, written on 2026-11-10: the agent keeps working on your network without
PingKit's server, its pages, its alerts to your own services and its Home Assistant entities
included. If PingKit ever ends, a final build removes the dependency on PingKit's server, so
the agent you run keeps running.

## Settings and your data

Settings come from an optional `config.yaml` in the data folder (the agent never writes it),
then `PINGKIT_*` variables, then the Home Assistant options, then changes made while it runs.
`pingkit-agent config check` reports problems by line and lists each setting with its source.
A notification URL that holds a token is better in a file (`PINGKIT_NOTIFY_URLS_FILE`), and the
agent never prints one.

The data folder holds the store, `backup/` (seven nightly snapshots) and `identity/` (this
agent's keys and pairing, in files only its own user can read, kept apart so a damaged store
never unpairs it). Keep it on a local disk: on NFS or SMB the agent falls back to a slower
journal and says so.

## Questions, ideas and problems

- **Questions and ideas**: [GitHub Discussions](https://github.com/pingkit/agent/discussions).
  <!-- OWED: Paul enables Discussions at launch; this link is a placeholder until then. No public roadmap at launch (Paul, 2026-11-10). -->
- **Setup guides**: [Docker and NAS](https://pingkit.app/agent/docker/),
  [Raspberry Pi](https://pingkit.app/agent/raspberry-pi/), and the [agent overview](https://pingkit.app/agent/).
- **Something broken**: open an issue with the **Copy diagnostics** text from the status page's
  Diagnostics page.
- **A security problem**: privately, to the address in [SECURITY.md](SECURITY.md), never in an
  issue.

## Release notes

Every version's notes, with the image digests and the verification command, are on the
[releases page](https://github.com/pingkit/agent/releases).

## Licence

The files in this repository are under the [MIT licence](LICENSE). The agent binary and the
container image are not covered by it: you may run them, free of charge, on devices you own or
manage; you may not modify, reverse engineer or redistribute them, except by pointing others at
the official image or install script. They come with no warranty of any kind.
