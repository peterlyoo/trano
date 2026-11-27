#!/usr/bin/env python3
import os
from pathlib import Path
import sys


STABLE_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
ENVIRONMENT_KEYS = (
    "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
    "DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS", "MACOSX_DEPLOYMENT_TARGET",
    "SOURCE_DATE_EPOCH", "TRANO_RENDER_CAPTURE_DIR", "TRANO_IME_CAPTURE_DIR",
    "TRANO_TEXT_CLARITY_PREVIEW", "TRANO_TEST_CLI",
    "SWIFTTERM_EMBEDDED_CHECK", "SWIFTTERM_WASM", "SWIFTTERM_WEB_WASM",
    "SWIFTTERM_WEB_WASM_TESTS", "SWIFTTERM_EMBEDDED_WASM", "SWIFTTERM_DOCC",
    "SWIFTTERM_EXCLUDE_APPLE",
)


def stable_environment(source):
    result = {key: source[key] for key in ENVIRONMENT_KEYS if key in source}
    result["PATH"] = STABLE_PATH
    return result


def swift_arguments(arguments, root):
    if arguments and arguments[0] in ("build", "test"):
        return [arguments[0], "--package-path", str(root), "--scratch-path", str(root / ".build"),
                "--jobs", "2", *arguments[1:]]
    return arguments


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("Usage: python3 scripts/run-swift.py <swift arguments>")
    root = Path(__file__).resolve().parents[1]
    os.execve("/usr/bin/swift", ["/usr/bin/swift", *swift_arguments(sys.argv[1:], root)],
              stable_environment(os.environ))
