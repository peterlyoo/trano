# Security Policy

> Report security vulnerabilities privately without exposing exploit details, credentials, or sensitive terminal transcripts in public issues.

## Supported Versions

Trano has no supported stable release yet. Security maintenance applies to the latest development source.

## Reporting a Vulnerability

- If GitHub private vulnerability reporting is enabled on the repository, submit reports there.
- Otherwise, open a minimal issue requesting a private reporting channel. Do not include exploit payloads, credentials, personal paths, or sensitive transcripts in public issues.

## Security Boundaries

- **Local Storage and API**: Local state lives in `~/.local/share/trano` (`TRANO_DATA_DIR`) and remote state in `~/.local/share/trano-remote` (`TRANO_REMOTE_ROOT`). Runtime directories and UNIX sockets enforce owner-only permissions. Account credentials remain in isolated owned directories and are never returned by the API.
- **Terminal Content**: Saved transcripts and scrollback on local disk can contain sensitive data. Never upload transcripts or authentication directories when reporting bugs. Trano includes no automatic telemetry or crash report uploads.
- **Terminal & SSH Protections**: Paste preview, OSC 52 clipboard restrictions, SSH key authentication, and trusted `known_hosts` checks preserve user boundaries. Remote helpers install into user-owned `~/.local/bin` without root daemons or TCP listeners.
