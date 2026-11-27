---
artifact_id: artifact-2026-11-12-trano-settings-idd
artifact_type: sdlc-idd
parent_id: artifact-2026-11-12-trano-settings-srs
state: implemented
---
# Extended preference interface

New domain preferences use private, versioned, atomic JSON sidecars under the runtime root; old primary-state writers cannot erase them. Native Settings and local API actions must share validation and persistence.

- Domains: Interface, Themes, Terminal, Notifications, Server, Integrations, Developer.
- Save: validate every changed value before writes; preserve unrelated concurrent fields; Cancel writes nothing.
- Network serving: explicit user opt-in, authenticated clients, client Remote Control permissions and exact Origin allowlists; no network enablement during tests.
- External tools: Tailscale actions run only from explicit app actions and report absent tools/authorization as unavailable, never fabricate success.
- Qualification: pure fake-based unit and isolated native component tests only until E2E is resumed.
