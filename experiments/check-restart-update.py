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


def wait(predicate, timeout=30, step=0.2):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


class RestartToUpdate(unittest.TestCase):
    def test_restart_button_relaunches_installed_build_and_keeps_shell(self):
        with tempfile.TemporaryDirectory(prefix="trano-restart-", dir="/tmp") as directory:
            root = pathlib.Path(directory)
            app, runtime, home = root / "Trano.app", root / "runtime", root / "home"
            home.mkdir()
            environment = dict(os.environ, TRANO_DATA_DIR=str(runtime), HOME=str(home), ZDOTDIR=str(home))
            for key in ["TRANO_SESSION", "TRANO_LAUNCH_ID", "REX_BLOCK", "REX_SESSION", "REX_SERVER"]:
                environment.pop(key, None)
            old_id, new_id = "a" * 64, "b" * 64

            def label(bundle, identity):
                for relative in ["Contents/Info.plist", "Contents/Helpers/Trano Service.app/Contents/Info.plist"]:
                    path = bundle / relative
                    info = plistlib.loads(path.read_bytes())
                    info["TranoBuildID"] = identity
                    path.write_bytes(plistlib.dumps(info))
                subprocess.run(["codesign", "--force", "--sign", "-", str(bundle / "Contents/Helpers/Trano Service.app")], check=True, capture_output=True)
                subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)], check=True, capture_output=True)

            def cli(*arguments, check=True):
                result = subprocess.run([str(app / "Contents/MacOS/trano"), *arguments], env=environment, capture_output=True, timeout=25)
                if not check and result.returncode != 0:
                    return None
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                return orjson.loads(result.stdout)["result"]

            def gui_pids():
                out = subprocess.run(["pgrep", "-f", str(root) + r"/.*Trano.app/Contents/MacOS/TranoApp$"], capture_output=True, text=True).stdout
                return [int(pid) for pid in out.split()]

            subprocess.run(["ditto", str(PROJECT / "build/Trano.app"), str(app)], check=True)
            label(app, old_id)
            gui = subprocess.Popen([str(app / "Contents/MacOS/TranoApp")], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            pane = None
            try:
                self.assertTrue(wait(lambda: cli("api", "server.info", check=False)), "GUI service did not start")
                pane = cli("create", "--title", "Restart survival", "--cwd", str(home))
                stage = root / "Next.app"
                subprocess.run(["ditto", str(app), str(stage)], check=True)
                label(stage, new_id)
                app.rename(root / "Previous.app")
                stage.rename(app)
                clicker = root / "click-window"
                subprocess.run(["swiftc", "-O", "-o", str(clicker), str(PROJECT / "experiments/click-window.swift")], check=True, capture_output=True)
                # System Events resolves processes by bundle id, so with the user's Trano running it can target the wrong app; click by this pid's window instead.
                time.sleep(8)
                clicked = subprocess.run([str(clicker), str(gui.pid), "245", "20"], capture_output=True, text=True, timeout=20)
                self.assertIn("clicked", clicked.stdout, clicked.stderr)
                gui.wait(timeout=20)
                relaunched = wait(lambda: [pid for pid in gui_pids() if pid != gui.pid], timeout=30)
                self.assertTrue(relaunched, "Installed build was not relaunched")
                info = wait(lambda: (lambda value: value if value and value["buildID"] == new_id else None)(cli("api", "server.info", check=False)), timeout=30)
                self.assertTrue(info, "Relaunched GUI did not hand the service over to the new build")
                listed = {row["id"]: row for row in cli("list")}
                self.assertTrue(listed[pane["id"]]["alive"])
                self.assertEqual(listed[pane["id"]]["pid"], pane["pid"])
                cli("send", pane["id"], "printf 'RESTART_%s\\n' SURVIVED", "--enter")
                self.assertTrue(wait(lambda: "RESTART_SURVIVED" in cli("capture", pane["id"])["text"], timeout=10))
                print(f"Restart to Update: GUI {gui.pid} -> {relaunched}, build {new_id[:8]}, shell {pane['pid']} kept")
            finally:
                if pane is not None:
                    cli("terminate", pane["id"], check=False)
                for pid in gui_pids():
                    subprocess.run(["kill", str(pid)], check=False)
                current = cli("api", "server.info", check=False)
                if current:
                    cli("api", "service.shutdown", orjson.dumps({"expectedBuildID": current["buildID"], "expectedPID": current["pid"]}).decode(), check=False)
                if gui.poll() is None:
                    gui.kill()
                subprocess.run(["pkill", "-f", str(root)], check=False)


if __name__ == "__main__":
    unittest.main()
