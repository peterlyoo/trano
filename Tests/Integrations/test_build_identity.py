import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class BuildIdentityTests(unittest.TestCase):
    def test_build_hash_tracks_runtime_source_but_ignores_private_state(self):
        path = ROOT / "scripts/build-id.py"
        self.assertTrue(path.exists(), "Source build identity generator must exist")
        spec = importlib.util.spec_from_file_location("build_identity", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "Sources").mkdir()
            source = root / "Sources/main.swift"
            source.write_text("first\n")
            first = module.source_identity(root)
            (root / ".local").mkdir()
            (root / ".local/secret").write_text("private content\n")
            self.assertEqual(first, module.source_identity(root))
            source.write_text("second\n")
            self.assertNotEqual(first, module.source_identity(root))
            self.assertEqual(len(first), 64)
            with tempfile.TemporaryDirectory() as other_directory:
                other = pathlib.Path(other_directory)
                (other / "Sources").mkdir()
                (other / "Sources/main.swift").write_text("second\n")
                self.assertEqual(module.source_identity(root), module.source_identity(other))


if __name__ == "__main__":
    unittest.main()
