#!/usr/bin/env python3
import base64
import os
import pathlib
import plistlib
import re
import sys
import urllib.parse


def release_metadata():
    version = os.environ.get("TRANO_BUILD_VERSION", "1")
    short_version = os.environ.get("TRANO_APP_VERSION", "0.1.0")
    if not re.fullmatch(r"[1-9][0-9]*(\.[0-9]+){0,2}", version):
        raise ValueError("TRANO_BUILD_VERSION must be a positive, increasing numeric version")
    if not re.fullmatch(r"[0-9]+(\.[0-9]+){1,2}", short_version):
        raise ValueError("TRANO_APP_VERSION must contain two or three numeric components")
    metadata = {"CFBundleVersion": version, "CFBundleShortVersionString": short_version}
    feed = os.environ.get("TRANO_UPDATE_FEED_URL", "")
    key = os.environ.get("TRANO_UPDATE_PUBLIC_KEY", "")
    if not feed and not key:
        return metadata
    parsed = urllib.parse.urlsplit(feed)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise ValueError("TRANO_UPDATE_FEED_URL must be an HTTPS URL without credentials or a fragment")
    try:
        decoded = base64.b64decode(key, validate=True)
    except ValueError as error:
        raise ValueError("TRANO_UPDATE_PUBLIC_KEY must be a base64 Ed25519 public key") from error
    if len(decoded) != 32 or not any(decoded):
        raise ValueError("TRANO_UPDATE_PUBLIC_KEY must contain a nonzero 32-byte Ed25519 public key")
    metadata.update({"SUFeedURL": feed, "SUPublicEDKey": key,
                     "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True,
                     "SUEnableAutomaticChecks": True, "SUAutomaticallyUpdate": True,
                     "SUScheduledCheckInterval": 86400})
    return metadata


def main():
    try:
        metadata = release_metadata()
        if len(sys.argv) != 2:
            raise ValueError("Usage: configure-updates.py <Info.plist|--check>")
        if sys.argv[1] != "--check":
            path = pathlib.Path(sys.argv[1])
            with path.open("rb") as source:
                info = plistlib.load(source)
            info.update(metadata)
            with path.open("wb") as target:
                plistlib.dump(info, target, sort_keys=False)
    except (ValueError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
