import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class BuildIdentityTests(unittest.TestCase):
    def test_vendored_renderer_and_shader_bytes_affect_identity_but_build_outputs_do_not(self):
        spec = importlib.util.spec_from_file_location("build_identity", ROOT / "scripts/build-id.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            renderer = root / "vendor/SwiftTerm/Sources/SwiftTerm/Renderer.swift"
            renderer.parent.mkdir(parents=True)
            renderer.write_text("renderer v1\n")
            first = module.source_identity(root)
            renderer.write_text("renderer v2\n")
            second = module.source_identity(root)
            self.assertNotEqual(first, second)
            shader = renderer.with_name("Shaders.metal")
            shader.write_text("shader v1\n")
            third = module.source_identity(root)
            self.assertNotEqual(second, third)
            output = root / "vendor/SwiftTerm/.build/generated.swift"
            output.parent.mkdir()
            output.write_text("temporary build output\n")
            self.assertEqual(third, module.source_identity(root))

    def test_owned_native_sandbox_bridge_source_and_header_change_identity(self):
        spec = importlib.util.spec_from_file_location("build_identity", ROOT / "scripts/build-id.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "Sources/TranoSandboxBridge/TranoSandboxBridge.c"
            header = source.parent / "include/TranoSandboxBridge.h"
            header.parent.mkdir(parents=True)
            source.write_text("int sandbox_bridge(void) { return 0; }\n")
            header.write_text("int sandbox_bridge(void);\n")
            before = module.source_identity(root)
            source.write_text("int sandbox_bridge(void) { return -1; }\n")
            changed = module.source_identity(root)
            self.assertNotEqual(before, changed)
            header.write_text("int sandbox_bridge(int pid);\n")
            self.assertNotEqual(changed, module.source_identity(root))

    def test_packaged_resources_and_notices_affect_build_identity(self):
        spec = importlib.util.spec_from_file_location("build_identity", ROOT / "scripts/build-id.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            resources = root / "Sources/TranoApp/Resources/ProgramIcons"
            resources.mkdir(parents=True)
            icon = resources / "program.png"
            icon.write_bytes(b"first asset")
            first = module.source_identity(root)
            icon.write_bytes(b"updated asset")
            self.assertNotEqual(first, module.source_identity(root))
            notices = root / "licenses"
            notices.mkdir()
            notice = notices / "artwork.txt"
            before_notice = module.source_identity(root)
            notice.write_text("Artwork license\n")
            self.assertNotEqual(before_notice, module.source_identity(root))

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
