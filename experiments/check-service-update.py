#!/usr/bin/env python3
import os
import pathlib
import plistlib
import subprocess
import tempfile
import time
import unittest

import orjson

PROJECT = pathlib.Path(__file__).resolve().parents[1]


class BackgroundServiceUpdate(unittest.TestCase):
    # Implements: FR-UPDATE-2
    def test_headless_helper_replacement_keeps_terminal_process_and_captures_old_identity(self):
        with tempfile.TemporaryDirectory(prefix="trano-handoff-", dir="/tmp") as directory:
            root = pathlib.Path(directory)
            app = root / "Trano.app"
            runtime = root / "runtime"
            home = root / "home"
            home.mkdir()
            environment = dict(os.environ, TRANO_DATA_DIR=str(runtime), HOME=str(home), ZDOTDIR=str(home))
            subprocess.run(["ditto", str(PROJECT / "build/Trano.app"), str(app)], check=True)
            old_id, new_id = "a" * 64, "b" * 64

            def label(bundle, identity):
                for relative in ["Contents/Info.plist", "Contents/Helpers/Trano Service.app/Contents/Info.plist"]:
                    path = bundle / relative
                    info = plistlib.loads(path.read_bytes())
                    info["TranoBuildID"] = identity
                    path.write_bytes(plistlib.dumps(info))
                subprocess.run(["codesign", "--force", "--sign", "-", str(bundle / "Contents/Helpers/Trano Service.app")], check=True, capture_output=True)
                subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True, capture_output=True)

            def cli(*arguments):
                result = subprocess.run([str(app / "Contents/MacOS/trano"), *arguments], env=environment,
                                        capture_output=True, check=True, timeout=25)
                return orjson.loads(result.stdout)["result"]

            def ensure():
                result = subprocess.run([str(app / "Contents/MacOS/TranoApp"), "--ensure-service"],
                                        env=environment, capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                return orjson.loads(result.stdout)

            def info():
                return cli("api", "server.info")

            label(app, old_id)
            old_process = None
            pane = None
            try:
                pane = cli("create", "--title", "Update survival", "--cwd", str(home))
                old_process = subprocess.Popen([str(app / "Contents/Helpers/Trano Service.app/Contents/MacOS/TranoApp"), "--service"],
                                               env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                for _ in range(100):
                    try:
                        old = info()
                        break
                    except subprocess.CalledProcessError:
                        time.sleep(0.05)
                else:
                    self.fail("Initial service did not start")
                self.assertEqual(old["buildID"], old_id)
                self.assertEqual(old["pid"], old_process.pid)
                denied = subprocess.run([str(app / "Contents/MacOS/trano"), "api", "service.shutdown",
                                         orjson.dumps({"expectedBuildID": new_id, "expectedPID": old_process.pid}).decode()],
                                        env=environment, capture_output=True, timeout=10)
                self.assertNotEqual(denied.returncode, 0)
                self.assertEqual(info()["pid"], old_process.pid)
                self.assertFalse(ensure()["replaced"])

                stage = root / "Next.app"
                subprocess.run(["ditto", str(app), str(stage)], check=True)
                label(stage, new_id)
                app.rename(root / "Previous.app")
                stage.rename(app)
                self.assertEqual(info()["buildID"], old_id, "Running identity must not follow replacement Info.plist")
                cli("send", pane["id"], "sleep 1; printf '\\nHANDOFF_SURVIVED\\n'", "--enter")
                handoff = ensure()
                self.assertTrue(handoff["replaced"])
                self.assertEqual(handoff["buildID"], new_id)
                self.assertNotEqual(handoff["pid"], old_process.pid)
                old_process.wait(timeout=10)
                self.assertEqual(old_process.returncode, 0)
                current = info()
                self.assertEqual(current["version"], old["version"])
                self.assertEqual(current["buildNumber"], old["buildNumber"])
                again = ensure()
                self.assertFalse(again["replaced"])
                self.assertEqual(again["pid"], current["pid"])
                self.assertEqual(cli("list")[0]["pid"], pane["pid"])
                for _ in range(100):
                    if "HANDOFF_SURVIVED" in cli("capture", pane["id"])["text"]:
                        break
                    time.sleep(0.05)
                else:
                    self.fail("Shell command did not survive service replacement")
                print("Helper replacement: acknowledged old exit, new build/PID, stable shell PID, no replacement loop.")
            finally:
                try:
                    current = info()
                    cli("api", "service.shutdown", orjson.dumps({"expectedBuildID": current["buildID"], "expectedPID": current["pid"]}).decode())
                except (subprocess.CalledProcessError, KeyError):
                    pass
                if old_process is not None and old_process.poll() is None:
                    old_process.terminate(); old_process.wait(timeout=5)
                if pane is not None:
                    cli("terminate", pane["id"])


if __name__ == "__main__":
    unittest.main()
