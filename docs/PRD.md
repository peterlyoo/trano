---
artifact_id: artifact-2026-11-10-agent-terminal-prd
parent_id: null
artifact_type: sdlc-prd
state: implementing
traceability_to: []
version: 2
authors: [codex]
last_updated: 2026-11-11
---

# Trano PRD: 백그라운드 유지와 에이전트 관리를 결합한 오픈소스 터미널 기획

> 현재 구현 상태, 실제 테스트, 남은 요구사항과 다음 명령은 [PROGRESS.md](PROGRESS.md) 및 [RTM.md](RTM.md)에 있으며, 재부팅 후 세션 자동 복원 요구사항은 [RECOVERY.md](RECOVERY.md)에 정의되어 있습니다. 이 문서의 이전 마일스톤 상태와 근거는 과거의 계획 스냅샷일 뿐 전체 제품 완성을 의미하지 않으며, 기존의 모든 U01-U21은 계속 유효한 범위에 포함됩니다.

> **한 문단 요약 (L1)**: 본 문서는 macOS 네이티브 UI(`Trano.app`)와 로컬 및 원격 Linux 데몬을 분리하여, 창을 닫거나 앱을 재시작해도 셸과 에이전트 작업을 유지하는 공개 오픈소스 제품 **Trano**의 기획서입니다. 사용자가 macOS 앱과 Linux 원격 서버 우선 방향 및 최종 제품명 **Trano**를 확정했으며, 현재 구현 진행 중(`implementing`) 단계로서 12개 Swift 테스트, 네이티브 앱 `SIGKILL` 지속성 테스트, Go 원격 로컬 `tmux` 테스트를 통과했으나 전체 제품이나 M1 완성을 주장하지 않고 21개 요구사항과 마일스톤(M0~M4) 단계 분할 및 잔여 검증 게이트를 정의합니다.

## Purpose

화면 표시(UI)와 프로세스 수명(Daemon)을 분리하여 안전한 백그라운드 작업 유지, 에이전트 상태 추적, 다중 계정 전환을 지원하는 macOS 네이티브 터미널(`Trano.app`, CLI `trano`) 및 Linux 원격 서버 제품의 요구사항과 검증 기준을 정의합니다.

* **전체 구조 (L2)**: UI 종료 시에도 로컬/원격 데몬과 격리된 `tmux`가 PTY와 세션을 유지하며 동일 API로 재접속합니다.

```text
+--------------------------------------------+
| macOS Native UI (Trano.app / TranoApp)     |
| [SwiftTerm 1.99.1] [Cmd+K] [Activity]      |
+---------------------+----------------------+
                      | Local IPC / SSH Tunnel
                      v
+--------------------------------------------+
| Per-User Runtime (macOS Local / Go 1.24)   |
| [Isolated tmux]      [Status/Events/API]   |
| [TranoCLI (trano)]   [Provider/Config Mgr] |
+---------------------+----------------------+
                      | fork / exec
                      v
+--------------------------------------------+
| Interactive Login zsh / CLI Agents         |
+--------------------------------------------+
```

* **macOS Native UI (`Trano.app`, 모듈/실행 파일 `TranoApp`, URL 스킴 `trano`)**: `SwiftTerm 1.99.1` 기반으로 화면 상태와 입력, 단축키, 명령 팔레트, 알림 표시에만 집중합니다.
* **Per-User Runtime & CLI (`trano`, 모듈 `TranoCLI`)**: 로컬 런타임 데이터 경로 `TRANO_DATA_DIR`(기본값 `~/.local/share/trano`)와 원격 경로 `TRANO_REMOTE_ROOT`(기본값 `~/.local/share/trano-remote`)를 사용하며, 격리된 `tmux` 서버와 사용자별 백그라운드 프로세스가 PTY(가상 터미널), 셸 PID, 작업 상태, API를 소유합니다.
* **SSH Tunnel (`Go 1.24` stdlib)**: 원격 Linux 서버의 사용자 데몬 API에 SSH를 통해 연결하며, 네트워크가 끊겨도 원격 작업은 유지됩니다.

## Problem statement

사용자는 macOS 네이티브 터미널과 원격 Linux 서버 환경에서 백그라운드 작업 유지, 빠른 zsh 및 한글 입력 지원, 에이전트 상태 알림, 다중 계정 전환, 공통 스킬/플러그인/훅/MCP 관리를 하나의 제품으로 통합하여 운영하고자 합니다.

* **확인된 외부 참조 사실 (Verified Public Reference Facts)**:
  * `https://stencil.so/tern`: 데몬 지속성과 스크립팅을 제시하나 개발/대기열(waitlist) 상태이며, 151ms 실행 수치는 벤더 주장으로 본 프로젝트에서 재현되지 않았습니다.
  * `https://www.superlogical.com/rex/docs/installation`: 로컬 서버를 포함한 Mac 클라이언트 및 Linux/FreeBSD 서버 베타 구조를 안내합니다.
  * `https://www.superlogical.com/rex/docs/reference/mac-actions`: `Cmd+K`는 `session.switch`, `Cmd+Shift+P`는 `client.palette.toggle`로 정의합니다.
  * `https://www.superlogical.com/rex/docs/build/program-status`: `OSC7501`은 `working`/`blocked`/`done`/`error`/`idle` 상태를 다루며, `working`/`blocked`는 프로세스 종료나 다음 셸 프롬프트에서 만료되고 `done`/`error`는 유지됩니다.
  * `https://www.superlogical.com/rex/docs/automate/server-api`: 자기 문서화(self-documenting) JSON API를 제공합니다.
  * `https://ghostty.org/docs/about`: 네이티브 Swift/AppKit/SwiftUI 및 공유 Zig 코어 구조이나, 문서상 `libghostty` 단독 API는 아직 안정화(stable)되지 않았음을 경고합니다.
  * `https://raw.githubusercontent.com/migueldeicaza/SwiftTerm/v1.99.1/README.md`: 임베딩 가능한 Swift 렌더러로 채택되어 `SwiftTerm 1.99.1`과 격리된 `tmux` 조합에 사용되며, 전체 목표 성능 벤치마크 및 실제 OS 한글 IME 적합성 검증은 아직 완료되지 않았습니다.
  * `https://iterm2.com/documentation-one-page.html`: 표준 화면 분할 및 탐색 단축키 동작의 기준입니다.
  * `https://github.com/tmux/tmux/wiki`: 공식 설명은 detach 후 background 유지와 reattach를 명시하며, 현재 개발 머신에 `tmux 3.6a`가 설치되어 있습니다.

* **확인된 현재 구현 및 테스트 사실 (Verified Implementation Facts)**:
  * 제품 식별자: 최종 제품명은 **Trano**이며, 네이티브 모듈/실행 파일은 `TranoApp`, UI/앱 번들은 `Trano.app`, CLI 실행 파일은 `trano`(모듈 `TranoCLI`), URL 스킴은 `trano`입니다.
  * 런타임 경로: 로컬 데이터 디렉터리는 `TRANO_DATA_DIR`(기본값 `~/.local/share/trano`), 원격 루트는 `TRANO_REMOTE_ROOT`(기본값 `~/.local/share/trano-remote`)를 사용하며, 공개 문서는 상대 경로만 사용합니다.
  * 통과한 검증: 12개 Swift 테스트가 통과했고, 네이티브 앱 `SIGKILL` 테스트에서 동일 shell PID 유지와 collector/API 지속 동작이 확인되었으며, Go 원격 에이전트의 실제 로컬 `tmux` 테스트가 통과했습니다.
  * 미완료 게이트(전체 제품 및 M1 미완료 사유): 실제 OS 한글 IME 입력/음성 입력/알림 권한 검증, 실제 원격 Linux/SSH 환경 검증, 실제 계정 페일오버(failover) 검증, 서명된 업데이트 및 공개 릴리스 검증은 아직 남아 있습니다.

## Goals

The 2026-11-11 session refinement requires named workspace get-or-create, automatic unused `Session N` names for blank New Session input, and stable pane renderers across tab creation and switching. U03/U09/U21 acceptance also requires a workspace selector adjacent to native window controls, no added terminal inset, and a verified readable default font while preserving custom selections.

The 2026-11-11 U03/U21 layout amendment requires one compact title/header/tab row, a leading current-workspace selector, an optional collapsed Sessions sidebar, and trailing Activity and Command Palette controls. Activity must overlay the existing terminal inside the same window without changing its viewport; native bounds, ordering and available terminal area are acceptance criteria under FR-NAV-6 in [NAVIGATION.md](NAVIGATION.md).

U01부터 U21까지의 모든 요구사항을 제품 범위 내에 유지하며, 구현 및 검증 순서만 M0~M4 단계로 나누어 제공합니다.

| ID | 요구사항 | 수용 테스트 | 단계 |
| :--- | :--- | :--- | :--- |
| U01 | 백그라운드 작업 유지: UI 종료/강제종료/업데이트 시 작업 유지 및 재접속. 서버 종료/OS 재부팅은 구분, 명시적 종료는 별도 명령 | 창 닫기, Cmd+Q, UI 강제종료 및 UI 업데이트 후 재접속 시 동일 shell PID, 증가하는 작업 카운터, PTY, 작업 디렉터리 유지 확인 (네이티브 앱 SIGKILL 시 동일 shell PID 및 collector/API 유지 테스트 통과, 전체 수용 게이트 완료 전까지 작업 종료 시 실패 기준 유지) | M1 |
| U02 | 빠른 zsh, 링크, 컬러: login interactive zsh, 기존 dotfiles 존중, completion, 시그널/터미널 제어, 링크 및 컬러 | Ctrl+C/Z/fg, vim/less, bracketed paste, TERM/terminfo, resize SIGWINCH, OSC8/URL 링크, ANSI16/256/24bit 동작 검증 | M1 |
| U03 | Rex 스타일 세션 전환(Cmd+K) 및 명령 팔레트(Cmd+Shift+P): 검색, 키보드 조작, 명령과 API 동일 액션 레지스트리 | 검색, 방향키, Enter, Escape 조작 후 이전 focus 복구 및 UI 명령과 JSON API 간 동일 액션 레지스트리 호출 확인 | M2 |
| U04 | Glass Launcher API: 세션/탭/패인 제어, cwd/title 검색, 프리뷰(optional), JSON CLI/versioned API/events, 별도 adapter | 설치된 런처 무변경 상태에서 별도 adapter 및 JSON CLI(`trano`)로 생성/목록/검색/선택/포커스 수행, 동시 변경 시에도 stable IDs 유지 확인 | M1 |
| U05 | Ghostty 스타일 폰트/배경 설정: 글꼴, 크기, 한글 fallback, 줄간격, 색상, 투명도/배경 이미지, profile override | 설정 변경 시 reload/persist/reset 즉시 반영 및 profile별 override 적용 확인 | M2 |
| U06 | 한글 완벽 지원 목표(테스트 목표이며 확인된 결과가 아님): 두벌식 조합 중 편집키, 영한 전환, 유니코드 정규화, wide-cell, IME 후보창, 원격 SSH 한글 | macOS 실제 OS IME 테스트를 통해 두벌식 조합 중 backspace/enter/escape, NFC/NFD/자모, wide-cell 선택/복사/검색/리사이즈, 후보창 위치, 한글 경로, 한영 혼합 검증 (실제 OS IME 테스트 전 지원 완료 주장 금지) | M2 |
| U07 | 완료 알림 및 Show Activity/API 상태: running/blocked/done/error/idle/unknown, structured 이벤트 우선, notification helper | 출력 멈춤으로 완료를 추정하지 않으며, 네트워크 끊김과 done 구분, fallback 시 confidence/source 및 입력/승인 대기 blocked reason 표시, dedup 이벤트, 알림 클릭 시 정확한 pane focus, UI 미실행 시 notification helper 및 실제 OS 알림 권한 동작 확인 | M3 |
| U08 | Claude/Codex 로고 및 탭: foreground process/adapter identity 기준, 라이선스 확인, 계정 alias만 노출; 탭 호버에서 agent·subagent 실시간 상태 표시 | 실제 프로세스/어댑터 기준 로고 표시, 공개 라이선스 검증 및 계정 alias만 노출; 탭의 모든 pane에 속한 root/child 상태가 호버 중 갱신되며 탭 선택·키보드 포커스·작업 실행에 영향을 주지 않는지 확인 | M3 |
| U09 | iTerm 스타일 키: 폰트 줌, 탭/분할/창 생성, 닫기/분리 구분, 편집 가능한 키맵 | Cmd+=/-/0, Cmd+T, Cmd+D(수직), Cmd+Shift+D(수평), Cmd+N 동작 및 Cmd+W 수행 시 패인 닫기/분리(detach)와 명시적 프로세스 종료가 구분되는지, 키맵 편집이 동작하는지 확인 | M2 |
| U10 | 화면 조정: 패인 포커스/순환, 최대화, 탭 순환/직접 이동, 전체화면, 마우스/키보드 리사이즈, 충돌 탐지 | Cmd+Option+방향키, Cmd+[/], Cmd+Shift+Enter, Cmd+Shift+[/], Cmd+1..9, Ctrl+Cmd+F, 분할선 드래그 및 키보드 리사이즈 동작과 단축키 충돌 탐지 확인 | M2 |
| U11 | 탭 간 패인 드래그 이동: 이동 후에도 패인 상태 유지, 호버 탭 활성화, 취소 시 무손실 (타 호스트 이동은 제외) | 다른 탭으로 드래그 중 hover tab activate, insertion target 표시, 이동 완료 후 동일 pane ID/PID/output 유지 및 Escape 취소 시 상태 손실 없음 확인 | M2 |
| U12 | 기본 검정 테마 및 시맨틱 상태 표시: 지정 색상 코드 준수 및 텍스트/아이콘 병기 | 배경 #0B0B0C, 크롬 #141416, 경계선 #242428, 텍스트 #ECECEE, 포커스 #85D7C1 적용 및 amber(blocked)/green(done)/red(error) 색상과 텍스트/아이콘 라벨 동시 표시 확인 | M2 |
| U13 | 음성 입력: 네이티브 권한, ko-KR/en-US, PTT/토글, 삽입 전 프리뷰 편집, 자동 실행 금지, 로컬/클라우드 구분 | 실제 OS 음성 권한 환경에서 push-to-talk 및 녹음 토글, 프리뷰 편집 후 삽입, 자동 Enter/명령 실행 없음, 권한 거부(denied) 경로 안내, 로컬 인식 가용성 표시 및 클라우드 opt-in 전용 동작 확인 | M3 |
| U14 | 원격 Linux 설치 및 재접속: SSH 기반 사용자별 서버, root 불필요, 검증 플래그, SSH와 데몬 수명 분리 | host key 검증, user systemd/manual fallback, --check/--dry-run, checksums/signatures 검증 후 설치, 네트워크 끊김 후 재접속 시 동일 원격 PID 유지 확인 (Go 원격 로컬 tmux 테스트 통과와는 별개로 실제 원격 Linux/SSH 환경에서 별도 검증 필수) | M4 |
| U15 | 이미지 복사/붙여넣기: 클립보드 PNG를 비공개 임시 경로로 저장, 이스케이프/붙여넣기, 원격 업로드 및 정리 | quoted path + bracketed paste 삽입, 에이전트별 지원 첨부 경로 전달, 원격 명시적 타겟 업로드 및 정리(cleanup), 미지원 에이전트 안내 확인 (Kitty/iTerm 이미지 렌더링과는 별도 기능으로 분리 검증) | M3 |
| U16 | 자동 업데이트: 서명된 매니페스트/아티팩트, 채널/롤백, UI 무중단 재시작 및 데몬 호환성 유지 | 스테이지 다운로드 및 롤백, UI 재시작 시 데몬 프로토콜 호환성 유지 및 실행 중인 데몬 재시작 지연(deferred) 확인 (공개 릴리스 전 저장소 소유자/서명/배포처/자격증명 설정 필수) | M4 |
| U17 | CPU/메모리 성능: busy polling 및 패인별 UI 타이머 금지, 이벤트 기반 백프레셔, UI+데몬과 자식 에이전트 분리 측정 | 문서화된 기준 하드웨어에서 30회 실행 및 10분 연속 출력 시 bounded RSS, cold ready p95 <=500ms, warm attach <=200ms, 10 idle panes 60초 평균 CPU <=1 core-percent, UI+daemon RSS <=250MiB, 입력 지연 p95 <=16.7ms 측정 (zsh 설정 비용은 분리 측정) | M1 |
| U18 | 다중 계정 관리: 동일 프로바이더(Claude→Claude, Codex→Codex) 내 전환, 격리된 저장소, 안전한 턴 경계 전환 | 순서 지정 레지스트리, 네이티브 로그인, 자격증명 격리 및 refresh lock, 쿼터/쿨다운/전체 소진 시 blocked 처리, 일시적 네트워크 오류와 인증 오류 구분, 완료된 툴 재실행 및 비가역 부분 출력 재시도 금지, 글로벌 ~/.claude 또는 ~/.codex 무변경 및 실제 계정 페일오버 확인 | M3 |
| U19 | 공통 스킬/플러그인/훅/MCP 매니저: 중앙 카탈로그, 프로바이더 어댑터, 원자적 적용/롤백, 보안 경계 | supported/shared/provider-only/unsupported 표시, diff/backup/atomic apply/rollback, 비관리 설정 덮어쓰기 금지, 실행형 훅 신뢰 경계 경고, Keychain/보호 저장소 사용, 비호환 플러그인 동일 취급 금지 및 로컬/원격 범위 명시 확인 | M3 |
| U20 | 오픈소스 공개 준비: 독립 저장소, 외부 비공개 의존성 배제, 라이선스/SBOM/문서화, 클린 CI | ai-system 런타임 및 비공개 CCO 의존성 없음, 원본 코드는 MIT 적용, third-party notices/SBOM/기여/보안 문서, 안전한 공개 fixture, 절대 사용자 경로/트랜스크립트/자격증명 유출 없는 상대 경로 기반 클린 체크아웃 CI 확인 (실제 URL 존재 전 공개 완료 주장 금지) | M4 |
| U21 | 디자인 품질 및 접근성: AppKit 셸 + 검증된 렌더러, 터미널 중심 레이아웃, 접근성 및 예외 상태 화면 | 과도한 블러/마케팅 대시보드 배제, 조용한 사이드바/상단 탭/Activity 드로어/계정 선택기/팔레트/설정 배치, 키보드 전용 흐름, VoiceOver, reduced motion, 1x/2x 스크린샷, 1024x700 및 1440x900 레이아웃, empty/error/offline/permission/limit 상태 확인 | M2 |

## Non-goals

* 실행 중인 프로세스를 다른 호스트(머신)로 라이브 마이그레이션하는 기능은 지원 범위 밖입니다(U11).
* 이기종 프로바이더 간 교차 폴백(예: Claude 한도 소진 시 Codex로 자동 전환)은 요청되지 않았으므로 제외합니다(U18).
* 단순 환경 변수 교체만으로 이미 실행 중인 에이전트 프로세스의 인증 주체를 변경하는 것은 불가능하므로 시도하지 않습니다(U18).
* 자체 이스케이프 시퀀스 파서(escape parser)를 밑바닥부터 직접 구현하지 않습니다.
* 공개 저장소 URL, 서명 키, 실제 OS(한글 IME/음성/알림 권한)/원격 Linux/실제 계정 페일오버 검증 완료 전에는 전체 제품 완성, M1 완성이나 릴리스 완료를 주장하지 않습니다.

## Success metrics

성능 및 품질 목표는 **미래 설계 목표(Proposed Targets)**이며, 아직 측정되지 않은 수치이므로 기정사실(fact)로 취급하지 않습니다. 모든 성능 수치는 문서화된 기준 하드웨어에서 터미널 UI+데몬과 자식 에이전트 프로세스 및 사용자 `zsh` 설정 로딩 비용을 분리하여 측정합니다(U17).

* **실행 및 재접속 속도**: 30회 실행 기준 Cold app ready `p95 <= 500ms`, 기존 데몬 Warm attach `p95 <= 200ms`.
* **자원 효율성**: 유휴 패인 10개 기준 60초 평균 CPU `<= 1 core-percent`, UI+데몬 합산 메모리 `RSS <= 250MiB`.
* **안정성 및 응답성**: 10분간 연속 고밀도 출력 시 메모리(RSS) 상한 유지(bounded RSS) 및 키 입력 지연 `p95 <= 16.7ms`.

## Constraints

* **외부 런처 불변성**: 사용자 시스템에 설치된 Glass Launcher 자체를 수정하지 않고 별도 어댑터와 `trano` CLI로 연동합니다(U04).
* **전역 인증 파일 보호**: 사용자의 전역 `~/.claude` 또는 `~/.codex` 인증 파일을 절대 덮어쓰거나 스왑하지 않습니다(U18).
* **독립 오픈소스 및 상대 경로 조건**: 공개 저장소는 `ai-system` 런타임이나 비공개 CCO 소스를 복사하거나 런타임에 의존해서는 안 되며, 기존 CCO는 선택적 비공개 어댑터로만 연결 가능해야 하고, 공개 문서에는 로컬 절대 경로를 기재하지 않고 상대 경로만 사용해야 합니다(U18, U20).
* **원격 무권한 설치**: 원격 Linux 서버 설치는 `root` 권한 없이 사용자 공간(`TRANO_REMOTE_ROOT`, 기본값 `~/.local/share/trano-remote`)에서 동작해야 합니다(U14).

## Risks

* **렌더러 및 tmux 조합 잔여 검증 리스크**: Ghostty 문서는 `libghostty` 단독 API가 안정화되지 않았다고 경고하며, 현재 채택된 `SwiftTerm 1.99.1`+격리된 `tmux` 서버 조합은 로컬 `SIGKILL` 및 Go 로컬 `tmux` 테스트는 통과했으나 이미지 passthrough, `OSC7501` hook 전달, 목표 성능(U17), 실제 OS 한글 IME(U06), 실제 원격 Linux/SSH 재접속(U14) 기준에서는 아직 최종 검증되지 않았습니다.
* **터미널 상태 복원 부작용**: 단순 바이트 로그만 재생할 경우 화면 모드(alternate screen 등)가 깨지거나 입력, 클립보드, 상태 이벤트가 중복 실행되는 부작용(side effects)이 발생할 수 있습니다.
* **프로바이더 세션 재개 한계**: 실제 Claude 또는 Codex CLI가 안전한 턴 경계에서 다른 계정 자격증명으로 세션을 이어받을 수 있는지(resume) 여부는 실제 계정 페일오버 검증 전까지 불확실합니다(U18).
* **실행형 훅 보안**: 외부 스킬이나 실행형 훅(executable hooks)은 임의 코드 실행이 가능한 신뢰 경계(trust boundary)이므로 사용자 환경 오염 위험이 있습니다(U19).

## Decisions

아래 사항은 검증된 외부 사실과 구분되는 **설계 결정 및 현재 아키텍처(Architecture Decisions)**입니다.

* **제품 식별자 및 경로 표준화**: 제품명은 **Trano**로 확정하며, macOS 네이티브 모듈/실행 파일은 `TranoApp`, 앱 번들은 `Trano.app`, CLI 실행 파일은 `trano`(모듈 `TranoCLI`), URL 스킴은 `trano`를 사용합니다. 런타임 데이터는 `TRANO_DATA_DIR`(기본값 `~/.local/share/trano`), 원격 런타임 루트는 `TRANO_REMOTE_ROOT`(기본값 `~/.local/share/trano-remote`)에 격리합니다.
* **UI와 데몬의 엄격한 분리**: macOS AppKit UI(`Trano.app`)는 뷰 상태와 입력만 소유하고, 사용자별 런타임과 격리된 `tmux`가 PTY, 프로세스, 상태, API를 소유합니다. UI 연결 해제나 `SIGKILL`이 PTY를 닫아서는 안 됩니다(U01).
* **화면 상태 기반 복원**: 데몬 재접속 시 단순 잘린 바이트 로그(truncated byte log)만 전송하지 않고 현재 화면과 터미널 모드를 함께 복원하며, 복원 과정에서 부작용이나 중복 입력/클립보드/상태 이벤트가 재발생하지 않도록 차단합니다.
* **렌더러 및 원격 에이전트 아키텍처**: 자체 파서 작성 대신 macOS 로컬은 `SwiftTerm 1.99.1`과 격리된 `tmux` 서버(`tmux 3.6a`) 조합을 사용하고, Linux 원격 서버는 SSH 상에서 동작하는 `Go 1.24` 표준 라이브러리(stdlib) 에이전트와 격리된 `tmux`를 사용합니다. 단, 이미지 passthrough, `OSC7501` hook 전달, 성능(U17), 실제 OS 한글 IME(U06), 실제 원격 Linux/SSH 재접속(U14) 수용 게이트는 모두 통과해야 완료로 인정합니다.
* **상태 매핑 규칙**: `OSC7501`의 `working` 상태는 제품 API에서 `running`으로 매핑하되 원본 출처(`source`)를 보존합니다(U07).

## Open questions

* **배포 자격증명**: 공개 소스 저장소는 [peterlyoo/trano](https://github.com/peterlyoo/trano)입니다. 코드 서명키(signing credentials), 서명된 바이너리 릴리스 및 업데이트 피드의 자격증명 설정은 아직 필요합니다(U16, U20).
* **오픈소스 라이선스**: 원본 코드는 `MIT`를 적용하며 의존성별 라이선스와 고지는 보존합니다. 앱의 에이전트 표시는 독립 제작한 코드 기반 아이콘을 사용합니다(U08, U20).
* **CLI 계정 전환 재개 검증**: 각 에이전트 CLI가 타 계정 자격증명으로 대화 맥락을 안전하게 재개(resume)할 수 있는지 프로바이더별 실제 계정 페일오버 실증 테스트가 필요합니다(U18).

## Children (Milestones)

전체 제품이나 M1은 아직 완료되지 않았으며, 현재 구현 진행 중(`implementing`)인 항목과 제안됨(`proposed`) 항목을 구분하여 관리합니다. 일정(날짜)은 약속하지 않으며, 21개 요구사항은 모두 최종 범위에 포함됩니다.

* **M0 (`implementing`): 기술 타당성 및 아키텍처 검증** — `SwiftTerm 1.99.1`+격리된 `tmux` 서버(`tmux 3.6a`) 및 `Go 1.24` stdlib 원격 아키텍처 채택. 12개 Swift 테스트, 네이티브 앱 `SIGKILL` 지속성 테스트, Go 원격 로컬 `tmux` 테스트 통과. 이미지 passthrough, `OSC7501` hook 전달, 실제 OS 한글 IME, 성능 벤치마크, 실제 원격 Linux 재접속 검증은 잔여 과제로 유지.
* **M1 (`implementing`, 미완료): 로컬 지속성 터미널 및 코어 API** — `TranoApp`(`Trano.app`) 및 `TranoCLI`(`trano`) 기반 U01, U02, U04, U17 구현 진행 중. 네이티브 앱 `SIGKILL` 후 동일 shell PID 및 collector/API 유지 확인 완료, 전체 U01/U02/U04 수용 테스트 및 U17 성능 벤치마크 측정 완료 전까지 M1 완료로 표시하지 않음.
* **M2 (`proposed`): 일일 사용 UI, 한글 입력, 창 관리 및 테마** — U03, U05, U06, U09, U10, U11, U12, U21 구현 및 실제 macOS OS 한글 IME 검증.
* **M3 (`proposed`): 에이전트 상태, 다중 계정, 공통 설정 및 멀티모달** — U07, U08, U13, U15, U18, U19 구현 및 실제 OS 음성/알림 권한, 실제 계정 페일오버 격리 검증.
* **M4 (`proposed`): 원격 Linux 서버, 자동 업데이트 및 오픈소스 공개 준비** — U14, U16, U20 구현 및 실제 원격 Linux/SSH 호스트 검증, 서명된 업데이트 및 공개 릴리스 자격증명 검증.

## Execution and evidence plan

각 마일스톤 진행 시 추측이나 주장 대신 아래의 재현 가능한 증거를 수집합니다.

1. **지속성 및 상태 복원 증거 (U01, U14)**: 통과한 12개 Swift 테스트, 네이티브 앱 `SIGKILL` 동일 shell PID 및 collector/API 유지 테스트, Go 원격 로컬 `tmux` 테스트에 더해, 업데이트 재시작 및 실제 원격 Linux/SSH 네트워크 차단 후 재접속 시 동일 shell PID와 작업 카운터 유지 로그 및 부작용 없는 화면 모드 복원 테스트 결과.
2. **실제 OS 및 원격 환경 검증 증거 (U06, U07, U13, U14, U21)**: macOS 실제 두벌식 한글 IME 조합/편집 테스트 녹화, 실제 OS 음성 입력 권한 및 알림 권한 동작 확인, 1024x700 및 1440x900 해상도에서의 1x/2x 스크린샷, 실제 원격 Linux 머신(비-root, `TRANO_REMOTE_ROOT`)에서의 `--check`/`--dry-run` 및 SSH 데몬 설치/재접속 로그.
3. **성능 벤치마크 리포트 (U17)**: 기준 하드웨어 사양이 명시된 상태에서 30회 실행 지연 시간(p95), 10개 유휴 패인 60초 CPU/RSS, 10분 연속 출력 RSS 상한, 입력 지연(p95)을 UI+데몬과 자식 프로세스별로 분리 측정한 리포트.
4. **실제 계정 전환 및 공개 안전성 감사 (U16, U18, U20)**: 실제 계정 페일오버(failover) 테스트 로그, 전역 `~/.claude`, `~/.codex` 무변경 스냅샷 증명, 서명된 업데이트 검증, 클린 체크아웃 CI 통과 로그, SBOM 및 절대 사용자 경로/자격증명 미포함(상대 경로 전용) 검사 결과.

## Change history

* **2026-11-10 (v2, codex)**: 최종 제품명 **Trano**(`Trano.app`, `TranoApp`, `trano`, `TranoCLI`, URL 스킴 `trano`) 및 런타임 환경 변수(`TRANO_DATA_DIR`, `TRANO_REMOTE_ROOT`), 상대 경로 전용 문서 규칙 반영. `SwiftTerm 1.99.1`+격리된 `tmux` 및 `Go 1.24` stdlib over SSH 아키텍처와 현재 `implementing` 상태(12개 Swift 테스트, 네이티브 앱 `SIGKILL` 테스트, Go 로컬 `tmux` 테스트 통과 및 잔여 미완료 게이트) 업데이트.
* **2026-11-10 (v1, codex)**: `artifact-2026-11-10-agent-terminal-prd` 초안 작성. U01~U21 전체 요구사항 정의, 확인된 외부 사실과 미래 설계 분리, M0(`SwiftTerm`+전용 `tmux` 서버 후보 포함)~M4 마일스톤(proposed) 수립.
