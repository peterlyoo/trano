import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SwiftEnvironmentTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("run_swift", ROOT / "scripts/run-swift.py")
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    def test_agent_environment_changes_do_not_change_build_inputs(self):
        base = {"HOME": "/fixture", "LANG": "ko_KR.UTF-8", "TMPDIR": "/tmp/fixture"}
        first = self.module.stable_environment(dict(base, CODEX_TOOL_CALL_ID="first", PATH="/tmp/first"))
        second = self.module.stable_environment(dict(base, CODEX_TOOL_CALL_ID="second", PATH="/tmp/second"))
        self.assertEqual(first, second)
        self.assertEqual(first["LANG"], "ko_KR.UTF-8")
        self.assertEqual(first["HOME"], "/fixture")

    def test_credentials_and_unrelated_provider_state_are_not_forwarded(self):
        result = self.module.stable_environment({"HOME": "/fixture", "EASYDECISION_TOKEN": "fixture-only",
            "ANTHROPIC_API_KEY": "fixture-only", "OPENAI_API_KEY": "fixture-only", "TRANO_PANE_ID": "live-pane"})
        for key in ("EASYDECISION_TOKEN", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "TRANO_PANE_ID"):
            self.assertNotIn(key, result)

    def test_explicit_toolchain_and_native_capture_inputs_are_kept(self):
        values = {"DEVELOPER_DIR": "/fixture/Xcode", "SDKROOT": "/fixture/SDK",
                  "TRANO_RENDER_CAPTURE_DIR": "/tmp/capture", "SWIFTTERM_EMBEDDED_CHECK": "1"}
        result = self.module.stable_environment(values)
        for key, value in values.items():
            self.assertEqual(result[key], value)

    def test_build_and_test_keep_the_same_absolute_workspace_and_job_limit(self):
        for action in ("build", "test"):
            args = self.module.swift_arguments([action, "-c", "release"], Path("/fixture/trano"))
            self.assertEqual(args, [action, "--package-path", "/fixture/trano", "--scratch-path",
                "/fixture/trano/.build", "--jobs", "2", "-c", "release"])
        self.assertEqual(self.module.swift_arguments(["scripts/generate-icon.swift", "output.icns"], ROOT),
                         ["scripts/generate-icon.swift", "output.icns"])


if __name__ == "__main__":
    unittest.main()
