---
artifact_id: artifact-2026-11-10-agent-terminal-brief
parent_id: null
artifact_type: other
state: planned
version: 1
last_updated: 2026-11-10
traceability_to: []
---
# Agent Terminal Technical Brief

> 현재 구현 상태, 실제 테스트, 남은 요구사항과 다음 명령은 [PROGRESS.md](PROGRESS.md) 및 [RTM.md](RTM.md)에 있으며, 재부팅 후 세션 자동 복원 요구사항은 [RECOVERY.md](RECOVERY.md)에 정의되어 있습니다. 이 문서의 이전 마일스톤 상태와 근거는 과거의 계획 스냅샷일 뿐 전체 제품 완성을 의미하지 않으며, 기존의 모든 U01-U21은 계속 유효한 범위에 포함됩니다.
> **Summary**: Agent Terminal M1 plans a macOS native terminal (`SwiftTerm` v1.99.1 candidate pin) backed by an isolated `tmux` server so UI disconnects never kill live shells. No implementation exists yet (`state: planned`).

## Goal & Chosen Approach
Build a standalone macOS/Linux-scoped terminal ("Agent Terminal", provisional name) retaining full U01–U21 product scope across M1–M4. M1 implements a native AppKit/SwiftUI `.app`, a JSON CLI, and an isolated `tmux` backend.
- **Verified Fact (2026-11-10)**: `/Applications/Xcode.app/Contents/Developer` (Swift 6.4) and `tmux` 3.6a are installed. Existing `python3 experiments/check-persistence.py` passed 1 test in 2.576s: after PTY client `SIGKILL`, shell PID `54793` survived, captured delayed detached output, and replayed Korean UTF-8 text upon reconnect. This proves runtime persistence, not native app/IME qualification or speed benchmarks.
- **Planned Design**: Embed `SwiftTerm` v1.99.1 (provisional qualification) talking to an isolated `tmux` socket. References: https://github.com/tmux/tmux/wiki, https://ghostty.org/docs/about, https://raw.githubusercontent.com/migueldeicaza/SwiftTerm/v1.99.1/README.md.

## Rejected Alternatives
- **Same-process GUI owning shell**: Rejected; quitting the GUI kills running jobs.
- **Custom VT parser / replay buffer**: Rejected; reattachment must restore exact terminal modes.
- **Ghostty embedding (mixed)**: Retained only as a replacement candidate if `SwiftTerm` fails Korean IME or performance; never mix two engines.
- **Node / Electron**: Rejected due to native requirement and footprint (not claims of measured superiority).

## Hard Constraints, Risks & Circuit-Breakers
- **Safety Invariants**: Do not modify existing Rex, default `tmux`, Glass Launcher, user settings, credentials, or unrelated global harness files (except appending state). Build in a standalone folder. No remote installation, publication, or invented final license identity in M1.
- **Known Risks**: OS-level Korean IME automation is unavailable; synthetic Unicode replay is not IME certification.
- **Circuit-Breaker Triggers**: Stop immediately if valid engine dependency resolution fails, replay loses terminal modes, credential isolation breaks, or private source code is required.

## Workstreams & Verification
Codex executes all workstreams sequentially (no subagent authorization): (1) Core runtime & isolated `tmux` wrapper, (2) Versioned JSON CLI (`trano`), (3) Native AppKit/SwiftUI UI & splits/tabs, (4) XCTest verification (`swift test`, `swift build -c release`, `python3 experiments/check-persistence.py`).
