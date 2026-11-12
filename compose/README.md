# PingKit Agent compose files

PingKit Agent watches your own network from a device that stays on: a NAS, a home
server or a Raspberry Pi. Every file here runs the same image with the same posture (plan
section 5.6) and differs only in the notes for its host. Pick one, set
`PINGKIT_CLAIM_CODE` to the code your iPhone shows under Agents > Add an Agent, start it.

| File | For | How it goes in |
|---|---|---|
| `compose.yaml` | Any Linux host with Docker | `docker compose up -d` |
| `compose.synology.yaml` | Synology DSM 7.2+, Container Manager | Project > Create > paste |
| `compose.qnap.yaml` | QNAP QTS 5 / QuTS hero, Container Station 3 | Applications > Create > paste |
| `compose.nas.yaml` | TrueNAS SCALE 24.10+, OpenMediaVault, CasaOS, Portainer | each one's "install from YAML" |
| `unraid-template.xml` | Unraid, Community Applications | after 0.1.0, from the CA store |

## The posture, and the one privilege

- `network_mode: host`: the one privilege. It lets the agent read the neighbour (ARP)
  table and hear mDNS and SSDP from your devices; a bridge network hides them.
- `read_only: true`, `cap_drop: [ALL]`, no `cap_add`, `user: "65532:65532"`,
  `no-new-privileges`, a 16 MB `noexec` `/tmp`, `mem_limit: 256m`, `pids_limit: 64`,
  `restart: unless-stopped`, state in the named volume `pingkit-agent-data` at `/data`.
- `scripts/check-agent-packaging.py` in `make gates` fails if any file here loses one of
  these or gains `cap_add`, `privileged`, `sysctls` or a port mapping outside a comment.

## Optional: ping

Without it the agent uses ARP and TCP checks. Ping is one host setting, which grants
nothing else:

```
sudo sysctl -w net.ipv4.ping_group_range="65532 65532"
```

(made permanent in `/etc/sysctl.d/60-pingkit-agent.conf`; Docker refuses `net.*`
sysctls under host networking, so it cannot go in the compose file). Adding the
`NET_RAW` capability does not turn ping on: the agent opens ICMP datagram sockets only,
never a raw socket, and the kernel admits those by `ping_group_range` alone (measured in
`docs/headless-agent/measurements.md`). Where the host setting cannot be changed, the
agent runs without ping.

## Not supported

Docker Desktop on Windows and macOS: its host network stops at layer 4, so the agent
cannot see your devices there.

A bridge network with published ports (`ports:` added to any file here, or Docker
Desktop): the status page answers only requests from private addresses, and it judges
the address of the connection it receives. Behind Docker's port mapping every
connection arrives from the bridge's gateway, a private address, so a request that came
through a port-forward on your router would be answered too. Host networking, as every
file here ships, is the supported mode; with it the agent sees each request's real
source.

## Alert rules with no iPhone

Without an iPhone, put the alert rules in `config.yaml` in the data volume
(`/data/config.yaml`): how far each kind goes (`notify`, `record` or `off`), quiet hours,
skip repeats and a device's sleep window. `docker kill -s HUP pingkit-agent` reads them again,
and `docker exec pingkit-agent /usr/local/bin/pingkit-agent config check` says what does not read. Every key,
and how the iPhone's settings stay above them: `docs/headless-agent/install.md`, "Alert rules
with no iPhone".

```yaml
rules:
  levels:
    device_offline: record
  quiet_hours: "22:00-07:00"
```

## Updating

`docker compose pull && docker compose up -d`, or your NAS's "pull and redeploy". `:1`
moves to each new 1.x release; to run exactly one signed build, pin the digest from the
release notes (`ghcr.io/pingkit/agent:1.0.0@sha256:...`).
