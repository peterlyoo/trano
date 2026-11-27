#!/usr/bin/env python3
import argparse
import hashlib
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
SWIFTTERM_SOURCE = "https://github.com/migueldeicaza/SwiftTerm"
SWIFTTERM_REVISION = "2f573f73af5e768d90847dce20c97fa9535d7164"
SWIFTTERM_ARCHIVE_SHA256 = "b7bd5d65ea4e2ad0a8776878ae9b873e80c25747e437df494e5d9fceba54affe"
SWIFTTERM_LICENSE_SHA256 = "0dc6bdd99b652c675586854efcacd59de21e2679d64fcaa20424aeb951df6856"
VENDOR_PATH = "vendor/SwiftTerm"
GENERATED_VENDOR_PARTS = {".git", ".local", ".build", "build", "__pycache__", ".DS_Store"}
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


def local_package_paths(root):
    manifest = (root / "Package.swift").read_text()
    manifest = re.sub(r"(?m)^\s*//.*$", "", manifest)
    paths = []
    for arguments in re.findall(r"\.package\s*\(([^)]*)\)", manifest):
        if not re.search(r"\bpath\s*:", arguments):
            continue
        local = re.fullmatch(r'\s*(?:name\s*:\s*"[^"\n]+"\s*,\s*)?path\s*:\s*"([^"\n]+)"\s*,?\s*', arguments)
        if local is None:
            raise ValueError("Local package paths must be reviewed relative string literals")
        paths.append(local.group(1))
    if any(path != VENDOR_PATH for path in paths) or len(paths) != len(set(paths)):
        raise ValueError("Unreviewed local package dependency")
    return paths


def vendored_swiftterm_component(root, pin=None):
    version = PACKAGES["swiftterm"][0]
    vendor = root / VENDOR_PATH
    try:
        if (root / "vendor").is_symlink() or vendor.is_symlink() or not vendor.is_dir():
            raise ValueError("Vendored SwiftTerm must be a source directory")
        for name in ["Package.swift", "TranoVendor.json", "LICENSE"]:
            path = vendor / name
            if path.is_symlink() or not path.is_file():
                raise ValueError("Missing vendored SwiftTerm package, license or provenance")
        metadata = read_document(vendor / "TranoVendor.json")
        expected = {"source": SWIFTTERM_SOURCE, "version": version, "revision": SWIFTTERM_REVISION,
                    "archiveSHA256": SWIFTTERM_ARCHIVE_SHA256}
        if not isinstance(metadata, dict) or any(metadata.get(key) != value for key, value in expected.items()):
            raise ValueError("Vendored SwiftTerm upstream provenance requires review")
        changes = metadata.get("localChanges")
        if not isinstance(changes, list) or not changes or any(not isinstance(item, str) or not item.strip() for item in changes):
            raise ValueError("Vendored SwiftTerm must describe its local changes")
        originals = metadata.get("originalFileSHA256")
        if not isinstance(originals, dict) or originals.get("LICENSE") != SWIFTTERM_LICENSE_SHA256:
            raise ValueError("Vendored SwiftTerm upstream license provenance requires review")
        for path in [vendor / "LICENSE", root / "licenses/SwiftTerm.txt"]:
            if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != SWIFTTERM_LICENSE_SHA256:
                raise ValueError("Vendored SwiftTerm license bytes require review")
        if pin is not None and (pin["state"]["version"] != version or pin["state"]["revision"] != SWIFTTERM_REVISION
                                or pin["location"].removesuffix(".git") != SWIFTTERM_SOURCE):
            raise ValueError("Resolved SwiftTerm pin conflicts with vendored upstream provenance")
        digest = hashlib.sha256()
        for path in sorted(vendor.rglob("*"), key=lambda item: item.relative_to(vendor).as_posix()):
            relative = path.relative_to(vendor)
            if path.is_symlink() or any(part in GENERATED_VENDOR_PARTS for part in relative.parts):
                raise ValueError("Symlink or generated artifact in vendored SwiftTerm source")
            if path.is_file():
                digest.update(relative.as_posix().encode("utf-8") + b"\0")
                digest.update(hashlib.sha256(path.read_bytes()).digest() + b"\0")
        tree_sha256 = digest.hexdigest()
    except (OSError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        raise ValueError("Missing or invalid vendored SwiftTerm license or provenance") from error
    upstream = package_component({"identity": "swiftterm", "state": {"version": version, "revision": SWIFTTERM_REVISION},
                                  "location": SWIFTTERM_SOURCE})
    fork_version = version + "+trano." + tree_sha256[:12]
    purl = "pkg:generic/trano/swiftterm@" + fork_version.replace("+", "%2B")
    archive_url = SWIFTTERM_SOURCE + "/archive/" + SWIFTTERM_REVISION + ".tar.gz"
    return {"type": "library", "bom-ref": purl, "name": "swiftterm", "version": fork_version,
            "scope": "required", "purl": purl, "licenses": license_value("MIT"),
            "hashes": [{"alg": "SHA-256", "content": tree_sha256}],
            "pedigree": {"ancestors": [upstream], "notes": "Locally modified vendored fork: " + "; ".join(changes)},
            "externalReferences": upstream["externalReferences"] + [
                {"type": "distribution", "url": archive_url, "comment": "Unmodified upstream source archive",
                 "hashes": [{"alg": "SHA-256", "content": SWIFTTERM_ARCHIVE_SHA256}]}],
            "properties": [{"name": "trano:role", "value": "runtime"},
                           {"name": "trano:sourceType", "value": "vendored-modified"},
                           {"name": "trano:dirty", "value": "true"},
                           {"name": "trano:localPath", "value": VENDOR_PATH},
                           {"name": "trano:upstreamVersion", "value": version},
                           {"name": "trano:vcsRevision", "value": SWIFTTERM_REVISION},
                           {"name": "trano:upstreamArchiveSHA256", "value": SWIFTTERM_ARCHIVE_SHA256},
                           {"name": "trano:hashSubject", "value": "vendored path/content tree; sorted UTF-8 relative path + NUL + raw file SHA-256 + NUL"}]}


def build_sbom(root, version="0.1.0"):
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", version):
        raise ValueError("App version must have two or three numeric components")
    pins = read_document(root / "Package.resolved")["pins"]
    components = {pin["identity"]: package_component(pin) for pin in pins}
    if len(components) != len(pins):
        raise ValueError("Duplicate resolved package identity")
    if VENDOR_PATH in local_package_paths(root):
        pin = next((pin for pin in pins if pin["identity"] == "swiftterm"), None)
        components["swiftterm"] = vendored_swiftterm_component(root, pin)
    components = [components[name] for name in sorted(components)]
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
