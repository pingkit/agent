# Security

Please report a security problem in PingKit Agent privately, not in a public issue.

- Contact: support@pingkit.app, as published in https://pingkit.app/.well-known/security.txt
- Include the agent version (`pingkit-agent version`, or the status page footer) and how
  it runs (Docker, Raspberry Pi, Home Assistant).

## Verifying what you run

Every image is signed with cosign (keyless). The identity, the issuer and the command are
on https://pingkit.app/agent/ and in each release's notes, with the image digest and an
SPDX SBOM per architecture. The Raspberry Pi tarball's SHA-256 is pinned in the install
script of the same release and checked before anything runs.

## Scope

The agent's container image, the Raspberry Pi install script and its systemd unit, the
Home Assistant app, and the agent's local status page and HTTPS API.
