import hashlib
import importlib.util
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
VERSION = "1.99.1"
REVISION = "2f573f73af5e768d90847dce20c97fa9535d7164"
ARCHIVE = "b7bd5d65ea4e2ad0a8776878ae9b873e80c25747e437df494e5d9fceba54affe"
LICENSE = "0dc6bdd99b652c675586854efcacd59de21e2679d64fcaa20424aeb951df6856"
SOURCE = "https://github.com/migueldeicaza/SwiftTerm"


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class VendoredFixture(unittest.TestCase):
    def setUp(self):
        self.sbom = load_script("generate-sbom")
        self.publication = load_script("check-publication")
        self.temporary = tempfile.TemporaryDirectory(dir=os.environ.get("TRANO_VENDOR_TEST_TMPDIR"))
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        for name in ["Package.resolved", "scripts/bootstrap-ci-tools.sh", "docs/dependency-provenance.yaml", "licenses/SwiftTerm.txt"]:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        (self.root / "Package.swift").write_text('let dependencies = [.package(path: "vendor/SwiftTerm")]\n')
        resolved = self.sbom.read_document(self.root / "Package.resolved")
        resolved["pins"] = [pin for pin in resolved["pins"] if pin["identity"] != "swiftterm"]
        resolved["pins"].append({
            "identity": "swiftterm", "kind": "remoteSourceControl", "location": SOURCE,
            "state": {"revision": REVISION, "version": VERSION},
        })
        (self.root / "Package.resolved").write_bytes(self.sbom.encode_document(resolved))
        self.vendor = self.root / "vendor/SwiftTerm"
        (self.vendor / "Sources").mkdir(parents=True)
        (self.vendor / "Package.swift").write_text('// swift-tools-version: 6.0\n')
        (self.vendor / "Sources/Terminal.swift").write_text('let foreground = "white"\n')
        shutil.copy2(ROOT / "licenses/SwiftTerm.txt", self.vendor / "LICENSE")
        self.provenance = {
            "source": SOURCE, "version": VERSION, "revision": REVISION,
            "archiveSHA256": ARCHIVE, "originalFileSHA256": {"LICENSE": LICENSE},
            "localChanges": ["Embedding package and native renderer changes"],
        }
        self.write_provenance()

    def write_provenance(self):
        (self.vendor / "TranoVendor.json").write_bytes(self.sbom.encode_document(self.provenance))

    def swiftterm(self):
        matches = [item for item in self.sbom.build_sbom(self.root)["components"] if item["name"] == "swiftterm"]
        self.assertEqual(len(matches), 1)
        return matches[0]

    def publication_result(self, staged=False):
        args = [sys.executable, str(ROOT / "scripts/check-publication.py"), "--root", str(self.root)]
        return subprocess.run(args + (["--staged"] if staged else []), capture_output=True, text=True)

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)


class VendoredSBOMTests(VendoredFixture):
    def test_local_dependency_without_resolved_pin_records_modified_fork_and_ancestor(self):
        resolved = self.sbom.read_document(self.root / "Package.resolved")
        resolved["pins"] = [pin for pin in resolved["pins"] if pin["identity"] != "swiftterm"]
        (self.root / "Package.resolved").write_bytes(self.sbom.encode_document(resolved))
        component = self.swiftterm()
        properties = {prop["name"]: prop["value"] for prop in component["properties"]}
        self.assertRegex(component["version"], r"^1\.99\.1\+trano\.[0-9a-f]{12}$")
        self.assertEqual(properties["trano:upstreamVersion"], VERSION)
        self.assertEqual(properties["trano:vcsRevision"], REVISION)
        self.assertEqual(properties["trano:upstreamArchiveSHA256"], ARCHIVE)
        self.assertEqual(properties["trano:sourceType"], "vendored-modified")
        self.assertEqual(properties["trano:dirty"], "true")
        self.assertEqual(properties["trano:localPath"], "vendor/SwiftTerm")
        self.assertIn("path/content", properties["trano:hashSubject"])
        self.assertNotEqual(component["hashes"][0]["content"], ARCHIVE)
        ancestor = component["pedigree"]["ancestors"][0]
        self.assertEqual(ancestor["version"], VERSION)
        self.assertEqual(ancestor["purl"], "pkg:github/migueldeicaza/SwiftTerm@1.99.1")
        archive_reference = next(ref for ref in component["externalReferences"] if ref["type"] == "distribution")
        self.assertEqual(archive_reference["hashes"], [{"alg": "SHA-256", "content": ARCHIVE}])

    def test_matching_stale_resolved_pin_is_replaced_once(self):
        component = self.swiftterm()
        self.assertTrue(component["version"].startswith(VERSION + "+trano."))
        self.assertEqual(component["licenses"], [{"license": {"id": "MIT"}}])

    def test_provenance_is_fixed_to_reviewed_upstream_inputs(self):
        for key, replacement in [("source", "https://github.com/example/fork"), ("version", "1.99.2"),
                                 ("revision", "a" * 40), ("archiveSHA256", "a" * 64), ("localChanges", [])]:
            with self.subTest(key=key):
                original = self.provenance[key]
                self.provenance[key] = replacement
                self.write_provenance()
                with self.assertRaises(ValueError):
                    self.sbom.build_sbom(self.root)
                self.provenance[key] = original
                self.write_provenance()

    def test_conflicting_stale_resolved_revision_is_rejected(self):
        resolved = self.sbom.read_document(self.root / "Package.resolved")
        next(pin for pin in resolved["pins"] if pin["identity"] == "swiftterm")["state"]["revision"] = "a" * 40
        (self.root / "Package.resolved").write_bytes(self.sbom.encode_document(resolved))
        with self.assertRaises(ValueError):
            self.sbom.build_sbom(self.root)

    def test_upstream_and_distributed_license_bytes_are_preserved(self):
        for path in [self.vendor / "LICENSE", self.root / "licenses/SwiftTerm.txt"]:
            with self.subTest(path=path.name):
                original = path.read_bytes()
                path.write_bytes(original + b"changed\n")
                with self.assertRaises(ValueError):
                    self.sbom.build_sbom(self.root)
                path.write_bytes(original)
        self.provenance["originalFileSHA256"]["LICENSE"] = "a" * 64
        self.write_provenance()
        with self.assertRaises(ValueError):
            self.sbom.build_sbom(self.root)

    def test_missing_provenance_license_or_package_fails_closed(self):
        for name in ["TranoVendor.json", "LICENSE", "Package.swift"]:
            with self.subTest(name=name):
                path = self.vendor / name
                original = path.read_bytes()
                path.unlink()
                with self.assertRaises(ValueError):
                    self.sbom.build_sbom(self.root)
                path.write_bytes(original)

    def test_digest_is_deterministic_and_covers_shader_paths_and_provenance(self):
        first = self.swiftterm()
        self.assertEqual(first, self.swiftterm())
        shader = self.vendor / "Sources/Text.metal"
        shader.write_text("// shader\n")
        shader_component = self.swiftterm()
        self.assertNotEqual(first["hashes"], shader_component["hashes"])
        shader.rename(self.vendor / "Sources/Other.metal")
        renamed = self.swiftterm()
        self.assertNotEqual(shader_component["hashes"], renamed["hashes"])
        self.provenance["localChanges"].append("Shader changes")
        self.write_provenance()
        self.assertNotEqual(renamed["hashes"], self.swiftterm()["hashes"])
        self.assertEqual(hashlib.sha256((self.vendor / "LICENSE").read_bytes()).hexdigest(), LICENSE)

    def test_symlink_and_generated_vendor_content_are_rejected(self):
        link = self.vendor / "Sources/Linked.swift"
        link.symlink_to("Terminal.swift")
        with self.assertRaises(ValueError):
            self.sbom.build_sbom(self.root)
        link.unlink()
        cache = self.vendor / ".build/cache"
        cache.parent.mkdir()
        cache.write_text("generated\n")
        with self.assertRaises(ValueError):
            self.sbom.build_sbom(self.root)

    def test_unknown_local_dependency_and_changed_reviewed_pins_are_rejected(self):
        for argument in ['"vendor/Other"', 'someComputedPath']:
            with self.subTest(argument=argument):
                (self.root / "Package.swift").write_text('let dependencies = [.package(path: ' + argument + ')]\n')
                with self.assertRaises(ValueError):
                    self.sbom.build_sbom(self.root)
        self.assertEqual({name: values[0] for name, values in self.sbom.PACKAGES.items()}, {
            "swiftterm": "1.99.1", "sparkle": "2.10.1", "swift-argument-parser": "1.8.2",
            "swift-docc-plugin": "1.5.0", "swift-docc-symbolkit": "1.0.0", "swift-png": "4.5.2",
            "h": "1.0.1", "dollup": "1.3.0",
        })

    def test_named_literal_dependency_is_supported_and_comment_is_ignored(self):
        (self.root / "Package.swift").write_text('// .package(path: "vendor/Other")\nlet dependencies = [.package(name: "SwiftTerm", path: "vendor/SwiftTerm",)]\n')
        self.assertTrue(self.swiftterm()["version"].startswith(VERSION + "+trano."))


class VendoredPublicationTests(VendoredFixture):
    def test_reviewed_vendor_tree_with_license_and_provenance_is_publishable(self):
        result = self.publication_result()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_vendor_content_still_gets_every_privacy_and_binary_rule(self):
        cases = [
            (b"token = sk-" + b"ant-" + b"x" * 30 + b"\n", "provider token"),
            (b"-----BEGIN " + b"PRIVATE KEY-----\n", "private key"),
            (b"/Users/" + b"somebody/project/\n", "personal absolute path"),
            (b'{"sessionId": "private"}\n', "session transcript record"),
            (b"a\0b\n", "unreviewed binary asset"),
        ]
        for content, label in cases:
            with self.subTest(label=label):
                self.assertIn(label, self.publication.scan_file("vendor/SwiftTerm/Sources/Test.swift", content))
        self.assertIn("private or generated artifact", self.publication.scan_file("vendor/SwiftTerm/.env", b"safe\n"))
        self.assertIn("outside publication boundary", self.publication.scan_file("vendor/Other/Source.swift", b"safe\n"))

    def test_missing_or_changed_license_and_missing_provenance_block_publication(self):
        for name in ["vendor/SwiftTerm/LICENSE", "vendor/SwiftTerm/TranoVendor.json", "licenses/SwiftTerm.txt"]:
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_bytes()
                path.unlink()
                result = self.publication_result()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("vendor license or provenance", result.stderr)
                path.write_bytes(original)
        (self.vendor / "LICENSE").write_text("license replaced\n")
        self.assertIn("vendor license or provenance", self.publication_result().stderr)

    def test_staged_license_and_secret_bytes_are_checked_instead_of_safe_worktree(self):
        self.git("init", "-q")
        secret = b"sk-" + b"ant-" + b"x" * 30
        source = self.vendor / "Sources/Terminal.swift"
        source.write_bytes(secret + b"\n")
        (self.vendor / "LICENSE").write_text("license replaced\n")
        self.git("add", ".")
        source.write_text("safe\n")
        shutil.copy2(self.root / "licenses/SwiftTerm.txt", self.vendor / "LICENSE")
        result = self.publication_result(staged=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("provider token", result.stderr)
        self.assertIn("vendor license or provenance", result.stderr)
        self.assertNotIn(secret.decode(), result.stdout + result.stderr)

    def test_staged_vendor_symlink_is_rejected_after_worktree_replacement(self):
        self.git("init", "-q")
        source = self.vendor / "Sources/Linked.swift"
        source.symlink_to("Terminal.swift")
        self.git("add", ".")
        source.unlink()
        source.write_text("safe\n")
        result = self.publication_result(staged=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink requires explicit review", result.stderr)


if __name__ == "__main__":
    unittest.main()
