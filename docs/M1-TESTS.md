---
artifact_id: artifact-2026-11-10-agent-terminal-m1-tests
parent_id: artifact-2026-11-10-agent-terminal-m1-sdd
artifact_type: sdlc-test-spec
state: planned
version: 1
last_updated: 2026-11-10
traceability_to:
  - artifact-2026-11-10-agent-terminal-m1-sdd
---
# TDD Strategy

> 현재 구현 상태, 실제 테스트, 남은 요구사항과 다음 명령은 [PROGRESS.md](PROGRESS.md) 및 [RTM.md](RTM.md)에 있으며, 재부팅 후 세션 자동 복원 요구사항은 [RECOVERY.md](RECOVERY.md)에 정의되어 있습니다. 이 문서의 이전 마일스톤 상태와 근거는 과거의 계획 스냅샷일 뿐 전체 제품 완성을 의미하지 않으며, 기존의 모든 U01-U21은 계속 유효한 범위에 포함됩니다.
> **Summary**: Defines the red-green XCTest plan (`Tests/TerminalCoreTests/RuntimeTests.swift`, planned new file) and verification boundaries for M1. Only `experiments/check-persistence.py` has been run; all Swift tests are `planned`.

## Principle & Ralph Integration
Write real XCTest assertions in `Tests/TerminalCoreTests/RuntimeTests.swift` (planned new file) before implementation and verify an initial red run; tests must exercise real behavior rather than cloning implementation logic. All untracked files must maintain clean EOF newlines and no trailing whitespace. Ralph task-loop generation is not active yet; Codex runs steps sequentially.

## Test Layers & Acceptance Criteria
- **Unit & Isolated Integration (macOS)**: Exercises `TerminalCore` against an isolated `tmux` 3.6a socket directory (`0700`/`0600`). Linux support is not inferred from macOS runs.
- **Acceptance Criteria**:
  1. Create session in a path with spaces/quotes, send command containing quotes and newline, detach, sleep, capture output sentinel, reconnect, and verify unchanged shell PID.
  2. Terminate kills only the exact target pane ID; invalid `cwd` or unknown IDs fail with structured errors; capture output respects byte/line bounds.
  3. Native build (`swift build -c release`) proves compilation only; layout snapshots (`1024x700` and `1440x900`) verify visual bounds and focus ring only.

## Per-Requirement Test Plan
- `FR-CORE-1`, `FR-CORE-2`, `FR-CORE-7`, `NFR-CORE-2`: Verified by `RuntimeTests.swift` lifecycle, quote/space `cwd`, explicit `unknown` status, permission checks, and output cap assertions.
- `FR-CORE-3`, `FR-CORE-4`, `FR-CORE-5`, `FR-CORE-6`: Verified by UI layout/state tests (`Cmd+W` detach vs terminate, split ID retention) plus manual screenshot/focus inspection at `1024x700` and `1440x900`.
- `FR-CORE-8`, `NFR-CORE-1`: Verified by `scripts/build-app.sh` (planned new file) artifact scan for personal paths/secrets and separate cold/warm timing logs.

## Evidence
- **Verified (2026-11-10)**: `python3 experiments/check-persistence.py` passed (1 test, 2.576s, PID `54793` survived client `SIGKILL`, Korean UTF-8 replayed).
- **Not Run / Open Gates**: `swift test`, `swift build -c release`, live OS Korean IME input, separate agent account isolation test, and remote host tests remain unexecuted. `docs/RTM.md` (planned new file) stays open until fresh runs succeed.
