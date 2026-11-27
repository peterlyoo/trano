from pathlib import Path
import plistlib
import re
import unittest


class NotificationBundleMetadataTests(unittest.TestCase):
    """Unit contracts only: no application or notification is launched."""

    def test_notification_sender_has_the_product_icon_and_display_name(self):
        script = (Path(__file__).resolve().parents[2] / "scripts/build-app.sh").read_text()
        match = re.search(r'''cat > "\$helper/Contents/Info.plist" <<'PLIST'\n(.*?)\nPLIST''', script, re.S)
        self.assertIsNotNone(match)
        metadata = plistlib.loads(match.group(1).encode())
        self.assertEqual(metadata.get("CFBundleIdentifier"), "dev.trano.activity")
        self.assertEqual(metadata.get("CFBundleDisplayName"), "Trano")
        self.assertEqual(metadata.get("CFBundleIconFile"), "Trano.icns")
        self.assertIn('"$helper/Contents/Resources/Trano.icns"', script)

    def test_gui_and_service_declare_the_same_supported_api_version(self):
        script = (Path(__file__).resolve().parents[2] / "scripts/build-app.sh").read_text()
        for target in ("app", "helper"):
            match = re.search(r'''cat > "\$''' + target + r'''/Contents/Info.plist" <<'PLIST'\n(.*?)\nPLIST''', script, re.S)
            self.assertIsNotNone(match)
            metadata = plistlib.loads(match.group(1).encode())
            self.assertEqual(metadata.get("TranoAPIVersion"), 1)


if __name__ == "__main__":
    unittest.main()
