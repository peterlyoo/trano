#!/usr/bin/env python3
import pathlib
import base64
import os
import plistlib
import secrets
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class UpdatePackagingTests(unittest.TestCase):
    # Implements: FR-UPDATE-1
    def test_signatures_reject_changed_archives_and_feeds(self):
        signer = ROOT / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
        self.assertTrue(signer.exists(), "Resolve pinned packages before update qualification")
        with tempfile.TemporaryDirectory(prefix="trano-update-signature-") as directory:
            root = pathlib.Path(directory)
            key = root / "ephemeral-test-key"
            key.write_bytes(base64.b64encode(secrets.token_bytes(32)))
            key.chmod(0o600)
            archive = root / "fixture.zip"
            archive.write_bytes(b"update-archive-fixture")
            sign = [str(signer), "--ed-key-file", str(key)]
            signature = subprocess.check_output(sign + ["-p", str(archive)], text=True).strip()
            subprocess.run(sign + ["--verify", str(archive), signature], check=True, capture_output=True)
            archive.write_bytes(b"tampered-update-archive")
            self.assertNotEqual(subprocess.run(sign + ["--verify", str(archive), signature], capture_output=True).returncode, 0)
            feed = root / "appcast.xml"
            feed.write_text('<?xml version="1.0"?><rss version="2.0"><channel><title>Trano</title></channel></rss>')
            subprocess.run(sign + [str(feed)], check=True, capture_output=True)
            subprocess.run(sign + ["--verify", str(feed)], check=True, capture_output=True)
            feed.write_text(feed.read_text().replace("Trano", "Tampered"))
            self.assertNotEqual(subprocess.run(sign + ["--verify", str(feed)], capture_output=True).returncode, 0)

    # Implements: FR-UPDATE-1
    def test_configuration_requires_signed_feed_and_archive(self):
        with tempfile.TemporaryDirectory(prefix="trano-update-config-") as directory:
            plist = pathlib.Path(directory) / "Info.plist"
            plist.write_bytes(plistlib.dumps({"CFBundleName": "Trano"}))
            environment = dict(os.environ, TRANO_UPDATE_FEED_URL="https://example.org/appcast.xml",
                               TRANO_UPDATE_PUBLIC_KEY=base64.b64encode(bytes(range(1, 33))).decode())
            subprocess.run(["python3", str(ROOT / "scripts/configure-updates.py"), str(plist)],
                           env=environment, check=True, capture_output=True)
            info = plistlib.loads(plist.read_bytes())
            self.assertTrue(info["SURequireSignedFeed"])
            self.assertTrue(info["SUVerifyUpdateBeforeExtraction"])
            self.assertTrue(info["SUAutomaticallyUpdate"])
            environment["TRANO_UPDATE_FEED_URL"] = "http://example.org/appcast.xml"
            self.assertNotEqual(subprocess.run(["python3", str(ROOT / "scripts/configure-updates.py"), str(plist)],
                                              env=environment, capture_output=True).returncode, 0)

    # Implements: FR-UPDATE-1, FR-UPDATE-3
    def test_release_rejects_missing_signing_configuration_before_build(self):
        result = subprocess.run([str(ROOT / "scripts/release-update.sh"), "--check"],
                                cwd=ROOT, text=True, capture_output=True,
                                env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TRANO_SIGNING_IDENTITY", result.stderr)
        self.assertNotIn("Building", result.stdout)

    # Implements: FR-UPDATE-3
    def test_bundle_embeds_framework_for_main_app_and_background_helper(self):
        app = ROOT / "build/Trano.app"
        if not app.exists():
            self.skipTest("Build the app before bundle qualification")
        framework = app / "Contents/Frameworks/Sparkle.framework"
        self.assertTrue((framework / "Sparkle").exists())
        for binary in [app / "Contents/MacOS/TranoApp", app / "Contents/Helpers/Trano Service.app/Contents/MacOS/TranoApp"]:
            dependencies = subprocess.check_output(["otool", "-L", str(binary)], text=True)
            self.assertIn("@rpath/Sparkle.framework", dependencies)
            load_commands = subprocess.check_output(["otool", "-l", str(binary)], text=True)
            self.assertIn("@executable_path/../../../../Frameworks", load_commands)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)


if __name__ == "__main__":
    unittest.main()
