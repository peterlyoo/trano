---
artifact_id: artifact-2026-11-12-trano-transparency
artifact_type: sdlc-milestone
parent_id: artifact-2026-11-10-agent-terminal-prd
state: implemented
---
# Whole-window background transparency

The existing appearance opacity applies to the terminal and surrounding window chrome. Backgrounds are composited once per region while text and icons retain full opacity.

| Decision | Contract |
|---|---|
| Source of truth | Existing Appearance opacity; profile opacity retained for its pane |
| Surfaces | Top/tab bar, bottom status bar, sidebar, pane headers, padding, separators, terminal and empty workspace |
| Native material | One window-wide behind-window effect including footer; standard macOS material, no exact external numerical radius claim |
| Local appearance | Apply verified local display preferences with private backup and immutable session/layout checks; no source config edits or Lua execution |
| Verification | Synthetic/native component units and signed installation; E2E remains paused |

## Earlier installation verification

| Evidence | Result |
|---|---|
| Unit scope |27 core+50 native=77 passed;0 failures;7 new opacity/background cases; `.local/window-transparency/final-unit.log` |
| Native coverage | Top/footer/sidebar/empty/pane-padding/container-gap alpha at1x/2x; background image RGB and alpha; profile/glass opacity; foreground/window alpha1 |
| Packaging |26 units passed; SBOM/publication635files verified |
| Signed build | `0c3c2d66f16ebe758962f2522436745697284d9e40b6649bf12f147b7e4795dd`; Apple Development; release104.21s |
| Install continuity |21 existing shell PIDs and exact layout retained;123 file hashes matched; `.local/window-transparency/installed-receipt.json` |
| Local application | Existing source display preferences applied with private backups; source hashes unchanged; check mode passed with0 changed files; `.local/window-transparency/appearance-continuity.json` |
| Application continuity |21 existing shell PIDs and exact layout retained after appearance changes |
| Qualification | E2E paused; physical compositor/OS appearance and current performance not measured; standard macOS blur has no exact external numeric radius claim |

## Zero-to-full range and continuous preview follow-up

| Evidence | Result |
|---|---|
| Range | Inclusive0–100% for main and profile settings; current stored opacity retained |
| Preview | Native continuous slider updates parent background pixels without persistence; owner-scoped cancel/unmount restores latest stored value; explicit profiles retained |
| Material | Zero-opacity native material hidden and click-through; foreground and NSWindow alpha remain1 |
| Units |100 selected product and44 packaging/fake-benchmark checks passed; includes shared input/font/notification repair regressions |
| Installed build | `8f58c94a922b24f9b8d8de627d5710669cb6ae8b678853a19403545d012b51e0`; Apple Development;23 live shell PIDs/layout and123 installed hashes retained |
| Evidence | `.local/input-settings-repair/final-unit.log`, `installed-receipt.json` |
| Limits | E2E remains paused; physical compositor qualification not claimed |
