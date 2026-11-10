#!/usr/bin/env python3
import argparse
import pathlib
import plistlib
import re
import subprocess
import sys

PACKAGES = {
    "swiftterm": ("1.99.1", "MIT", "LICENSE", "runtime", "required"),
    "sparkle": ("2.10.1", "MIT and bundled BSD/zlib notices", "LICENSE", "runtime", "required"),
    "swift-argument-parser": ("1.8.2", "Apache-2.0 WITH Swift-exception", "LICENSE.txt", "resolved-tool", "excluded"),
    "swift-docc-plugin": ("1.5.0", "Apache-2.0 WITH Swift-exception", "LICENSE.txt", "resolved-documentation", "excluded"),
    "swift-docc-symbolkit": ("1.0.0", "Apache-2.0 WITH Swift-exception", "LICENSE.txt", "resolved-documentation", "excluded"),
    "swift-png": ("4.5.2", "Apache-2.0", "LICENSE", "resolved-non-Apple-graphics", "excluded"),
    "h": ("1.0.1", "Apache-2.0", "LICENSE", "resolved-non-Apple-graphics", "excluded"),
    "dollup": ("1.3.0", "Unspecified in formatter wrapper", "", "resolved-formatter-not-distributed", "excluded"),
}
TOOLS = [
    ("tmux", "3.6a", "https://github.com/tmux/tmux", "3.6a", "ISC and individual source-file notices", "COPYING", "external-runtime-and-ci", "b6d8d9c76585db8ef5fa00d4931902fa4b8cbe8166f528f44fc403961a3f3759"),
    ("libevent", "2.1.13-stable", "https://github.com/libevent/libevent", "release-2.1.13-stable", "BSD-3-Clause", "LICENSE", "ci-build", "f7e9383b8c0baa81b687e5b5eecc01beefaf1b19b64151d95ed61647fe7a315c"),
    ("utf8proc", "2.12.0", "https://github.com/JuliaStrings/utf8proc", "v2.12.0", "MIT and Unicode data license", "LICENSE.md", "ci-build", "a393fbef160835fb315bc3e91ba8d86f7a73a7cec9e6198b6c60b848b498bfeb"),
]


def read_document(path):
    data = subprocess.check_output(["/usr/bin/plutil", "-convert", "xml1", "-o", "-", str(path)])
    return plistlib.loads(data)


def license_value(name):
    if name in ("MIT", "Apache-2.0", "BSD-3-Clause"):
        return [{"license": {"id": name}}]
    if " WITH " in name:
        return [{"expression": name}]
    return [{"license": {"name": name}}]


def package_component(pin):
    name = pin["identity"]
    if name not in PACKAGES:
        raise ValueError("Unreviewed dependency license: " + name)
    version, license_name, license_path, role, scope = PACKAGES[name]
    state = pin["state"]
    revision = state["revision"]
    location = pin["location"].removesuffix(".git")
    if state["version"] != version or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Dependency version or revision requires review: " + name)
    if not re.fullmatch(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", location):
        raise ValueError("Unexpected dependency source: " + name)
    purl = "pkg:github/" + location.split("github.com/", 1)[1] + "@" + version
    references = [{"type": "vcs", "url": location + "/tree/" + revision}]
    if license_path:
        references.append({"type": "license", "url": location + "/blob/" + revision + "/" + license_path})
    else:
        references.append({"type": "documentation", "url": "https://github.com/rarestype/dollup/tree/1.3.0"})
    return {"type": "library", "bom-ref": purl, "name": name, "version": version,
            "scope": scope, "purl": purl, "licenses": license_value(license_name),
            "externalReferences": references,
            "properties": [{"name": "trano:role", "value": role}, {"name": "trano:vcsRevision", "value": revision}]}


def build_sbom(root, version="0.1.0"):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", version):
        raise ValueError("App version must have two or three numeric components")
    pins = read_document(root / "Package.resolved")["pins"]
    components = [package_component(pin) for pin in sorted(pins, key=lambda pin: pin["identity"])]
    bootstrap = (root / "scripts/bootstrap-ci-tools.sh").read_text()
    provenance = (root / "docs/dependency-provenance.yaml").read_text()
    for name, number, source, tag, license_name, license_path, role, checksum in TOOLS:
        if not re.fullmatch(r"[0-9a-f]{64}", checksum) or checksum not in bootstrap or checksum not in provenance:
            raise ValueError("Unverified tool archive digest: " + name)
        purl = "pkg:github/" + source.split("github.com/", 1)[1] + "@" + tag
        components.append({"type": "application" if name == "tmux" else "library", "bom-ref": purl,
                           "name": name, "version": number, "purl": purl,
                           "scope": "required" if name == "tmux" else "optional",
                           "licenses": license_value(license_name),
                           "hashes": [{"alg": "SHA-256", "content": checksum}],
                           "externalReferences": [{"type": "vcs", "url": source + "/tree/" + tag},
                                                  {"type": "license", "url": source + "/blob/" + tag + "/" + license_path}],
                           "properties": [{"name": "trano:role", "value": role},
                                          {"name": "trano:bundled", "value": "false"},
                                          {"name": "trano:hashSubject", "value": "pinned upstream source release archive"}]})
    components.append({"type": "platform", "bom-ref": "pkg:golang/go@1.24.10", "name": "Go", "version": "1.24.10",
                       "licenses": license_value("BSD-3-Clause"),
                       "externalReferences": [{"type": "license", "url": "https://github.com/golang/go/blob/go1.24.10/LICENSE"}],
                       "properties": [{"name": "trano:role", "value": "remote-helper-runtime-and-build-toolchain"}]})
    return {"$schema": "http://cyclonedx.org/schema/bom-1.6.schema.json", "bomFormat": "CycloneDX", "specVersion": "1.6", "version": 1,
            "metadata": {"lifecycles": [{"phase": "build"}], "component": {"type": "application", "bom-ref": "trano", "name": "Trano", "version": version, "licenses": license_value("MIT")}},
            "components": components}


def encode_document(value):
    result = subprocess.run(["/usr/bin/plutil", "-convert", "json", "-r", "-o", "-", "-"],
                            input=plistlib.dumps(value, sort_keys=True), capture_output=True, check=True)
    return result.stdout.rstrip(b"\n") + b"\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--version", default="0.1.0")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    destination = args.output or root / "docs/sbom.json"
    try:
        data = encode_document(build_sbom(root, args.version))
        if args.check:
            if not destination.exists() or destination.read_bytes() != data:
                raise ValueError("SBOM is missing or stale; regenerate it from the current resolved pins")
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print("CycloneDX 1.6 SBOM verified." if args.check else "CycloneDX 1.6 SBOM generated.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
