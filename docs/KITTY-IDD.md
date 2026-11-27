---
artifact_id: artifact-2026-11-12-trano-kitty-idd
artifact_type: sdlc-idd
parent_id: artifact-2026-11-12-trano-kitty-srs
state: implementing
---
# Kitty external interface

Wire behavior follows the [official OSC5522 specification](https://sw.kovidgoyal.net/kitty/clipboard/). The host advertises the standard clipboard only when enumeration, permissioned reads and atomic writes are available.

| Interface | Contract |
|---|---|
| OSC5522 | ESC ] 5522 ; metadata ; base64-payload ST; read/write/wdata/walias, reply status, sanitized id, spec error codes. |
| Read | MIME-list period needs no data-read grant; other reads require permission; data responses max4096 decoded bytes per chunk and terminate DONE. |
| Write | At least64MiB transaction capacity; commit all MIME data and aliases atomically at final wdata; invalid data aborts current write. |
| Primary selection | ENOSYS on macOS when unsupported. |
| Mode5522 | DECRQM and DECSET/DECRST; user paste provides MIME list and one-time pw for subsequent read, with reset/revocation. |
| URL hints | Ctrl+Shift+E default; configured overrides and palette use the same action; only http/https targets open. |
