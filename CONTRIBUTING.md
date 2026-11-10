# Contributing to Trano

> Contributors must verify changes locally using isolated test environments and pass publication boundary checks before submitting a pull request.

## Verification Commands

Run these checks before opening a pull request:

1. Run Swift unit and integration tests:
   ```sh
   swift test
   ```
2. Run Linux helper tests with the race detector:
   ```sh
   (cd remote && go test -race ./...)
   ```
3. Build the application bundle and embedded helpers:
   ```sh
   scripts/build-app.sh
   ```
4. Run update and publication checks:
   ```sh
   python3 experiments/check-updates.py
   python3 Tests/Integrations/test_publication.py
   python3 scripts/check-publication.py
   ```

Fixture scripts in `experiments/check-accounts.py`, `experiments/check-native.py`, `experiments/check-recovery.py`, and `experiments/check-remote-ssh.py` exercise specific subsystems; some require `orjson` and a dedicated SSH fixture.

## Development and Isolation Rules

- Never run concurrent Swift builds in the same `.build` directory.
- Always use isolated `TRANO_DATA_DIR`, `HOME`, `ZDOTDIR`, and account roots in tests. Never kill the default user `tmux` server or use real credentials in fixtures.
- Preserve exact UTF-8 `argv`, stable pane IDs and generations, live jobs, and ownership checks.
- Fake provider tests do not prove authenticated provider behavior. Security fixes must include tests for isolation, session resume, or tool execution.

## Dependencies and Publication Hygiene

New dependency versions must be pinned and at least 14 days old, with transitive updates and licenses audited (`THIRD_PARTY_NOTICES.md`). CI actions must be SHA-pinned.

Check staged files with `python3 scripts/check-publication.py --staged` and list allowed paths with `--list` against `docs/publication-boundary.yaml` (`.local`, `.build`, `build`, and `design` are excluded and rejected if tracked). Never publish authentication data, terminal transcripts, personal machine paths, or unreviewed screenshots. The scanner helps catch leaks but does not prove the absence of all secrets.
