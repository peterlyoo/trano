---
artifact_id: artifact-2026-11-12-trano-settings-srs
artifact_type: sdlc-srs
parent_id: artifact-2026-11-12-trano-settings-parity
state: implemented
---
# Settings option contract

Every control must persist and affect its named behavior; a stored value alone does not establish support. Existing Trano defaults remain until users change them. E2E remains paused by user instruction.

| Requirement | Source ID | Group | Option | Validation |
|---|---|---|---|---|
| FR-SET-1 | setting-coding-agents-integrate-with-available-agents | Integrations | Integrate with available agents | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-2 | setting-agent-behavior-let-agents-name-sessions | Integrations | Let agents name sessions | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-3 | setting-in-app-notifications-notification-position | Notifications | Legacy notification position | Retained for stored-data compatibility only;2026-11-16 macOS-only request removes in-window delivery and position control. |
| FR-SET-4 | setting-program-activity-show-activity-in-tabs | Notifications | Show activity in tabs | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-5 | setting-program-activity-include-idle-processes-in-activity | Notifications | Include idle processes in activity | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-6 | setting-program-activity-show-each-process-in-tabs | Notifications | Show each process in tabs | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-7 | setting-program-activity-show-system-notifications | Notifications | Show system notifications | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-8 | setting-program-activity-badge-dock-icon | Notifications | Badge Dock icon | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-9 | setting-program-activity-play-sounds | Notifications | Play sounds | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-10 | setting-program-activity-sound-volume | Notifications | Sound volume | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-11 | setting-program-activity-working | Notifications | Working | Banner, Dock and sound controls retained. Running tab dots are unavailable, including legacy enabled tab-indicator preferences; no Working Tab checkbox. |
| FR-SET-12 | setting-program-activity-blocked | Notifications | Blocked | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-13 | setting-program-activity-error | Notifications | Error | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-14 | setting-program-activity-done | Notifications | Done | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-15 | setting-system-notifications-terminal-notifications | Notifications | Terminal notifications | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-16 | setting-system-notifications-tailscale-sign-in | Notifications | Tailscale sign-in | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-17 | setting-system-notifications-tailscale-device-approval | Notifications | Tailscale device approval | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-18 | setting-system-notifications-tailscale-failures | Notifications | Tailscale failures | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-19 | setting-rex-server-server-status | Server | Server status | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-20 | setting-rex-server-compatibility | Server | Compatibility | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-21 | setting-remote-address-remote-address | Server | Remote Address | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-22 | setting-tailscale-serve-over-tailscale | Server | Serve over Tailscale | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-23 | setting-tailscale-preferred-hostname | Server | Preferred Hostname | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-24 | setting-tailscale-limit-access-to-your-tailscale-account | Server | Limit access to your Tailscale account | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-25 | setting-tailscale-tags | Server | Tags | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-26 | setting-tailscale-control-server | Server | Control Server | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-27 | setting-tailscale-sign-in-to-tailscale | Server | Sign in to Tailscale | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-28 | setting-client-info-label | Server | Label | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-29 | setting-client-info-remote-control | Server | Remote Control | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-30 | setting-appearance-color-scheme | Interface | Color scheme | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-31 | setting-appearance-interface-style | Interface | Interface style | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-32 | setting-appearance-tint-with-theme | Interface | Tint with theme | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-33 | setting-appearance-use-glass-for-panes | Interface | Use glass for panes | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-34 | setting-toolbar-toolbar-layout | Interface | Toolbar layout | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-35 | setting-toolbar-toolbar-behavior | Interface | Toolbar behavior | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-36 | setting-tab-behavior-tabs-fill-available-space | Interface | Tabs fill available space | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-37 | setting-tab-icons-use-color-for-tab-icons | Interface | Use color for tab icons | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-38 | setting-tab-icons-shell-icon-theme | Interface | Shell icon theme | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-39 | setting-tab-icons-show-tab-icons | Interface | Show tab icons | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-40 | setting-panes-pane-style | Interface | Pane style | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-41 | setting-panes-pane-header-behavior | Interface | Pane header behavior | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-42 | setting-window-sidebar-text-size | Interface | Sidebar text size | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-43 | setting-window-preserve-width-when-resizing-sidebar | Interface | Preserve width when resizing sidebar | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-44 | setting-window-use-a-gesture-to-toggle-the-sidebar | Interface | Use a gesture to toggle the sidebar | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-45 | setting-padding-padding-x | Interface | Padding X | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-46 | setting-padding-padding-y | Interface | Padding Y | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-47 | setting-padding-fill-with-program-colors | Interface | Fill with program colors | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-48 | setting-padding-include-pane-header | Interface | Include pane header | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-49 | setting-active-pane-highlight-active-pane-edges | Interface | Highlight active pane edges | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-50 | setting-active-pane-highlight-color | Interface | Highlight color | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-51 | setting-active-pane-highlight-opacity | Interface | Highlight opacity | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-52 | setting-active-pane-animate-active-pane-highlight | Interface | Animate active pane highlight | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-53 | setting-active-pane-fade-inactive-panes | Interface | Fade inactive panes | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-54 | setting-active-pane-fade-panes-for-inactive-windows | Interface | Fade panes for inactive windows | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-55 | setting-splits-focus-autobalance-splits | Interface | Autobalance splits | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-56 | setting-splits-focus-focus-follows-mouse | Interface | Focus follows mouse | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-57 | setting-gestures-use-trackpad-gestures | Interface | Use trackpad gestures | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-58 | setting-animation-animation-style | Interface | Animation style | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-59 | setting-app-icon-app-icon | Interface | App Icon | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-60 | setting-app-icon-show-app-icon | Interface | Show app icon | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-61 | setting-launch-show-window-on-launch | Interface | Show window on launch | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-62 | setting-light-mode-light-theme | Themes | Light theme | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-63 | setting-light-mode-use-extended-theme-palette | Themes | Use extended theme palette | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-64 | setting-dark-mode-dark-theme | Themes | Dark theme | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-65 | setting-dark-mode-use-extended-theme-palette | Themes | Use extended theme palette | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-66 | setting-typography-terminal-font | Terminal | Terminal font | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-67 | setting-typography-font-size | Terminal | Font size | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-68 | setting-typography-font-style | Terminal | Font style | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-69 | setting-typography-font-weight | Terminal | Font weight | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-70 | setting-typography-line-height | Terminal | Line height | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-71 | setting-advanced-font-settings-character-spacing | Terminal | Character spacing | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-72 | setting-advanced-font-settings-ligatures | Terminal | Ligatures | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-73 | setting-advanced-font-settings-render-bold-and-italic | Terminal | Render bold and italic | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-74 | setting-advanced-font-settings-force-bold-and-italic-styles | Terminal | Force bold and italic styles | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-75 | setting-advanced-font-settings-font-smoothing | Terminal | Font smoothing | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-76 | setting-advanced-font-settings-fallback-fonts | Terminal | Fallback fonts | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-77 | setting-colors-improve-text-contrast | Terminal | Improve text contrast | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-78 | setting-colors-force-theme-palette-for-text | Terminal | Force theme palette for text | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-79 | setting-colors-use-display-p3-color-space | Terminal | Use Display P3 color space | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-80 | setting-cursor-blink-speed | Terminal | Blink speed | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-81 | setting-cursor-blink-interval | Terminal | Blink interval | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-82 | setting-cursor-cursor-style | Terminal | Cursor style | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-83 | setting-cursor-force-style | Terminal | Force style | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-84 | setting-keyboard-show-key-sequence-hints | Terminal | Show key sequence hints | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-85 | setting-keyboard-option-key | Terminal | Option key | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-86 | setting-scrolling-smooth-scrolling | Terminal | Smooth scrolling | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-87 | setting-resizing-smooth-terminal-resizing | Terminal | Smooth terminal resizing | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-88 | setting-selection-copy-on-selection | Terminal | Copy on selection | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-89 | setting-selection-play-animation-on-copy | Terminal | Play animation on copy | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-90 | setting-selection-selection-foreground | Terminal | Selection foreground | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-91 | setting-selection-selection-background | Terminal | Selection background | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-92 | setting-selection-rounded-corners | Terminal | Rounded corners | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-93 | setting-links-links-that-open-apps | Terminal | Links that open apps | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-94 | setting-links-trusted-links | Terminal | Trusted links | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-95 | setting-integrated-path-browser-show-recently-used-paths | Terminal | Show recently used paths | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-96 | setting-titles-prefer-generated-titles | Terminal | Prefer generated titles | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-97 | setting-shell-startup-command | Terminal | Startup command | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-98 | setting-developer-developer-mode | Developer | Developer Mode | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-99 | setting-experimental-download-new-updates-when-available | Developer | Download new updates when available | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-100 | setting-experimental-install-updates-automatically | Developer | Install updates automatically | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-101 | setting-experimental-terminal-anchoring | Developer | Terminal anchoring | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-102 | setting-experimental-cursor-shaders | Developer | Cursor shaders | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-103 | setting-experimental-new-quick-switcher | Developer | New quick switcher | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-104 | setting-experimental-quick-look-links | Developer | Quick Look links | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-105 | setting-app-version-update-channel | Developer | Update Channel | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-106 | setting-rex-installation-location | Developer | Location | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-107 | setting-rex-installation-source-directory | Developer | Source Directory | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-108 | setting-rex-installation-installation-status | Developer | Installation status | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-109 | setting-rex-installation-version | Developer | Version | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-110 | setting-rex-installation-commit | Developer | Commit | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-111 | setting-rex-installation-final-sha-256 | Developer | Final SHA-256 | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-112 | setting-local-api-local-api-url | Developer | Local API URL | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-113 | setting-web-client-origins-allowed-origins | Developer | Allowed origins | Persist/cancel, native control, owning behavior and isolated unit coverage required. |
| FR-SET-114 | setting-web-client-origins-origin-pattern | Developer | Origin pattern | Persist/cancel, native control, owning behavior and isolated unit coverage required. |

Theme Import adds validated Ghostty and iTerm color-file parsing; imported names and invalid data must not overwrite existing palettes.
Group preferences use independent secure sidecars to survive old live primary-state writers. Saving validates all drafts before mutation; Cancel discards them.
Rex numeric shipping defaults not published in the reference remain unknown; Trano chooses bounded native defaults that preserve current behavior.
