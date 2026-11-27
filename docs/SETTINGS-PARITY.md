---
artifact_id: artifact-2026-11-12-trano-settings-parity
artifact_type: sdlc-milestone
parent_id: artifact-2026-11-10-agent-terminal-prd
state: implemented
---
# Rex settings parity

Bring the verified Rex Interface, Themes and Terminal options into native Trano settings. Each supported control must persist and change the actual renderer or application behavior.

- Inventory source: official Rex documentation and read-only installed product option schemas; no personal setting values, proprietary code or artwork are published.
- Preserve existing settings, profiles, keyboard overrides, Save/Cancel semantics and Hangul input.
- Profiles performance is measured at the native entry path; font discovery must not block that path.
- The option matrix and per-option acceptance tests are established before feature implementation.

## Quota notification implementation slice

Notifications provides independent Low quota and Quota reset switches, a remaining-quota threshold, global delivery/system/sound controls and adjustable sound volume. Save merges changed preference leaves; Cancel discards edits. Known reset deadlines and fresh provider quota observations feed a durable deduplication ledger; unknown/stale quota data does not become a zero-percent estimate. Notification sender icon packaging is installed; actual OS delivery remains unqualified while E2E is paused.

## Current implementation and unit evidence

**114 Rex settings across Integrations, Notifications, Server, Interface, Themes, Terminal, and Developer connect to native controls and owning consumers.** The sidebar instantiates only selected content, running backend construction and executable discovery lazily in the background. Save validates all groups before writing, persists locally before updating changed Server/Integrations drivers, and keeps the window open to report partial success if external drivers fail. Cancel discards drafts. 32 Terminal settings reach the CG/Metal renderer or runtime/input path, preserving typography modes, synthetic Hangul preedit during fractional scroll/resize, pane profiles, and frozen chord responders. Live notifications and Tailscale are unqualified.

| Evidence | Result |
|---|---|
| Installed build | `c6b3e574ce453eb1b29691009e94a54f698dabe6fcab3fc332cd471a2a2ddb0a`; Apple Development signature verified |
| Continuity | 21 existing shell PIDs and exact workspace/tab/pane layout retained |
| Binary identity | Running GUI/helper paths, helper API build identity and 123 built/installed file hashes verified |
| Unit tests | 226 core XCTest +285 native XCTest +26 Swift Testing =537;0 failures |
| Packaging units | 26 passed;0 failures |
| Artifacts | `.local/settings-release-unit.log`, `.local/settings-packaging-unit.log`, `.local/settings-installed-receipt.json` |
