---
artifact_id: artifact-2026-11-10-agent-terminal-m1-srs
parent_id: artifact-2026-11-10-agent-terminal-m1
artifact_type: sdlc-srs
state: planned
version: 1
last_updated: 2026-11-10
traceability_to:
  - artifact-2026-11-10-agent-terminal-m1
---
# M1 Software Requirements Specification

> 현재 구현 상태, 실제 테스트, 남은 요구사항과 다음 명령은 [PROGRESS.md](PROGRESS.md) 및 [RTM.md](RTM.md)에 있으며, 재부팅 후 세션 자동 복원 요구사항은 [RECOVERY.md](RECOVERY.md)에 정의되어 있습니다. 이 문서의 이전 마일스톤 상태와 근거는 과거의 계획 스냅샷일 뿐 전체 제품 완성을 의미하지 않으며, 기존의 모든 U01-U21은 계속 유효한 범위에 포함됩니다.
> **Summary**: Defines M1 functional (`FR-CORE-1` to `8`) and non-functional (`NFR-CORE-1` to `2`) requirements mapped to U01–U21. All requirements are currently `planned` and unimplemented.

## Functional Requirements
- **FR-CORE-1 (U01)**: Persistent shell runs independently of UI/clients. Detach and reconnect preserve shell PID and visible screen state; explicit termination is a distinct action.
- **FR-CORE-2 (U02/U04)**: JSON CLI supports `list`, `create`, `capture`, `send`, `detach`, and `terminate` with stable pane IDs, validated inputs, and exact `cwd` handling for paths containing quotes or spaces.
- **FR-CORE-3 (U02/U06)**: Native AppKit/SwiftUI app embeds a proven terminal renderer supporting full `zsh` input, resize, ANSI escapes, and Unicode; never use an HTML fake console.
- **FR-CORE-4 (U08/U09/U10/U11)**: Native tabs and split panes keep the underlying PTY ID when moving panes; detaching a view never erases metadata of a live backend.
- **FR-CORE-5 (U03/U09/U10)**: Keyboard control includes `Cmd+K` session picker (Rex priority), `Cmd+Shift+P` palette, `Cmd+=`/`-`/`0`, `Cmd+T`, `Cmd+D`, `Cmd+Shift+D`, `Cmd+W` (detach view only, separate from terminate), `Cmd+Shift+Enter`, and pane/tab cycling.
- **FR-CORE-6 (U05/U12/U21)**: Native black default theme with configurable font/background, settings persistence, enforced minimum pane sizes, and high-visibility focus indicators.
- **FR-CORE-7 (U07 partial, M3 full)**: Backend maintains authoritative metadata and explicit `unknown` status; public API never infers job completion from silence and reserves event hooks for M3 structured activity.
- **FR-CORE-8 (U20 partial)**: Standalone build and artifact contain no personal paths, secrets, or private code, recording exact dependency provenance and third-party licenses.

## Non-Functional Requirements
- **NFR-CORE-1**: Record cold and warm startup/action metrics separately; never claim PRD release targets are met from a single run.
- **NFR-CORE-2**: Confine all runtime files to a test/app-specific directory (`0700` directories, `0600` files), isolated from existing `tmux` sockets, with bounded capture lengths and direct `argv` execution (zero shell interpolation of user inputs).
