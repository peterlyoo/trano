import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


class SBOMTests(unittest.TestCase):
    def module(self):
        path = ROOT / "scripts/generate-sbom.py"
        self.assertTrue(path.exists(), "SBOM generator must exist")
        spec = importlib.util.spec_from_file_location("sbom", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_resolved_components_keep_real_revisions_and_license_roles(self):
        module = self.module()
        bom = module.build_sbom(ROOT)
        self.assertEqual(bom["specVersion"], "1.6")
        components = {item["name"]: item for item in bom["components"]}
        pins = module.read_document(ROOT / "Package.resolved")["pins"]
        for pin in pins:
            item = components[pin["identity"]]
            self.assertEqual(item["version"], pin["state"]["version"])
            self.assertIn(pin["state"]["revision"], str(item["externalReferences"]))
            self.assertTrue(item["licenses"])
        for name in ["tmux", "libevent", "utf8proc"]:
            self.assertEqual(len(components[name]["hashes"][0]["content"]), 64)
        self.assertNotIn("dependencies", bom)
        self.assertIn("Unspecified", str(components["dollup"]["licenses"]))

    def test_rejects_unreviewed_or_malformed_pin(self):
        module = self.module()
        with self.assertRaises(ValueError):
            module.package_component({"identity": "unreviewed", "state": {"version": "1.0.0", "revision": "a" * 40}, "location": "https://github.com/example/example"})
        with self.assertRaises(ValueError):
            module.package_component({"identity": "sparkle", "state": {"version": "2.10.1", "revision": "invalid"}, "location": "https://github.com/sparkle-project/Sparkle"})


if __name__ == "__main__":
    unittest.main()
