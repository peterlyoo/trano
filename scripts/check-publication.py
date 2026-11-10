#!/usr/bin/env python3
import argparse
import os
import pathlib
import re
import subprocess
import sys

EXCLUDED = {".git", ".local", ".build", "build", "__pycache__", ".DS_Store", "design"}
FORBIDDEN_NAMES = {"auth.json", "credentials.json", ".credentials.json", ".env", "id_rsa", "id_ed25519", "snapshot.db", "state.json"}
RULES = {
    "personal absolute path": re.compile(rb"/(?:Users|home)/[A-Za-z0-9._-]+/"),
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    "provider token": re.compile(rb"\b(?:sk-ant-|sk-proj-|ghp_|github_pat_)[A-Za-z0-9_-]{20,}"),
    "cloud access key": re.compile(rb"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "private infrastructure": re.compile(rb"sendbird-cloud\.teleport\.sh|[A-Za-z0-9.-]+\.sendbird\.com|https?://[A-Za-z0-9.-]+\.internal\b"),
    "session transcript record": re.compile(rb'^\s*\{"(?:parentUuid|sessionId|type":"(?:session_meta|user|assistant))', re.MULTILINE),
}
PUBLIC_ROOTS = {"Sources", "Tests", "scripts", "remote", "integrations", "experiments", "docs", ".github", "licenses"}
PUBLIC_FILES = {"Package.swift", "Package.resolved", ".gitignore", "AGENTS.md", "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "CONTRIBUTING.md", "SECURITY.md"}


def working_files(root):
    result = []
    for directory, names, files in os.walk(root, followlinks=False):
        names[:] = sorted(name for name in names if name not in EXCLUDED)
        for name in list(names):
            path = pathlib.Path(directory) / name
            if path.is_symlink():
                result.append(path.relative_to(root).as_posix())
                names.remove(name)
        for name in sorted(files):
            path = pathlib.Path(directory) / name
            if name not in EXCLUDED:
                result.append(path.relative_to(root).as_posix())
    return sorted(result)


def scan_file(name, data):
    parts = pathlib.PurePosixPath(name).parts
    findings = []
    if any(part in EXCLUDED for part in parts) or pathlib.PurePosixPath(name).name in FORBIDDEN_NAMES:
        findings.append("private or generated artifact")
    if parts and parts[0] not in PUBLIC_ROOTS and name not in PUBLIC_FILES:
        findings.append("outside publication boundary")
    if b"\0" in data:
        findings.append("unreviewed binary asset")
    for label, expression in RULES.items():
        if expression.search(data):
            findings.append(label)
    if data and not data.endswith(b"\n"):
        findings.append("missing final newline")
    return findings


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1])
    parser.add_argument("--staged", action="store_true")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    git = (root / ".git").exists()
    if args.staged and not git:
        parser.error("--staged requires a Git repository")
    tracked = []
    if git:
        tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
        tracked = [name for name in tracked if name]
    if args.staged:
        files = subprocess.check_output(["git", "diff", "--cached", "--name-only", "--diff-filter=ACMRT", "-z"], cwd=root).decode().split("\0")
        files = [name for name in files if name]
    else:
        files = sorted(set(working_files(root) + tracked))
    failures = []
    for name in files:
        path = root / name
        if path.is_symlink():
            failures.append((name, "symlink requires explicit review"))
            continue
        try:
            data = subprocess.check_output(["git", "show", ":" + name], cwd=root) if args.staged else path.read_bytes()
        except (OSError, subprocess.CalledProcessError):
            failures.append((name, "candidate could not be read"))
            continue
        failures.extend((name, finding) for finding in scan_file(name, data))
    if failures:
        for name, finding in failures:
            print(f"{name}: {finding}", file=sys.stderr)
        print(f"Publication check failed: {len(failures)} findings in {len(files)} files.", file=sys.stderr)
        return 1
    if args.list:
        print("\n".join(files))
    else:
        print(f"Publication boundary and content checks passed: {len(files)} files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
