#!/usr/bin/env python3
import hashlib
import pathlib


def source_identity(root):
    paths = []
    for directory in ("Sources", "remote", "scripts", "integrations", "licenses", "vendor"):
        folder = root / directory
        if folder.exists():
            paths.extend(path for path in folder.rglob("*")
                         if path.is_file() and not path.is_symlink()
                         and not any(part.startswith(".") or part in ("__pycache__", "build") for part in path.relative_to(root).parts)
                         and (directory == "vendor" or "Resources" in path.relative_to(root).parts
                              or path.suffix in (".swift", ".c", ".h", ".go", ".mod", ".sh", ".py", ".plist", ".lua", ".txt")))
    paths.extend(root / name for name in ("Package.swift", "Package.resolved", "LICENSE") if (root / name).exists())
    digest = hashlib.sha256()
    for path in sorted(paths, key=lambda value: value.relative_to(root).as_posix()):
        data = path.read_bytes()
        digest.update(path.relative_to(root).as_posix().encode("utf-8") + b"\0")
        digest.update(len(data).to_bytes(8, "big"))
        digest.update(data)
    return digest.hexdigest()


if __name__ == "__main__":
    print(source_identity(pathlib.Path(__file__).resolve().parents[1]))
