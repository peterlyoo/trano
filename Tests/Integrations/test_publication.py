import importlib.util
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class PublicationTests(unittest.TestCase):
    def scanner(self):
        path = ROOT / "scripts/check-publication.py"
        self.assertTrue(path.exists(), "Publication gate must exist")
        spec = importlib.util.spec_from_file_location("publication", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_rejects_private_runtime_and_credentials_without_printing_values(self):
        scanner = self.scanner()
        for name in [".local/state.json", "build/app.zip", "auth.json", "keys/id_ed25519"]:
            self.assertTrue(scanner.scan_file(name, b"safe text\n"), name)
        self.assertTrue(scanner.scan_file("Sources/Leak.swift", b'let path = "/' + b'Users/private-user/project"\n'))
        self.assertTrue(scanner.scan_file("README.md", b"-----BEGIN " + b"PRIVATE KEY-----\n"))
        self.assertFalse(scanner.scan_file("Sources/Fixture.swift", b'let root = "/tmp/trano-fixture"\n'))

    def test_ignores_local_state_but_never_ignores_tracked_secrets(self):
        scanner = self.scanner()
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "Sources").mkdir()
            (root / "Sources/main.swift").write_text("import Foundation\n")
            (root / ".local").mkdir()
            (root / ".local/private.txt").write_text("private\n")
            self.assertEqual(scanner.working_files(root), ["Sources/main.swift"])
            self.assertTrue(scanner.scan_file(".local/private.txt", b"private\n"))

    def test_staged_scan_reads_index_and_never_prints_matched_secret(self):
        self.scanner()
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "Sources").mkdir()
            source = root / "Sources/Example.swift"
            source.write_text('let token = "' + 'ghp_' + 'A' * 35 + '"\n')
            subprocess.run(["git", "add", "Sources/Example.swift"], cwd=root, check=True)
            source.write_text("import Foundation\n")
            result = subprocess.run(["python3", str(ROOT / "scripts/check-publication.py"), "--root", str(root), "--staged"], text=True, capture_output=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("provider token", result.stderr)
            self.assertNotIn('A' * 35, result.stderr)


if __name__ == "__main__":
    unittest.main()
