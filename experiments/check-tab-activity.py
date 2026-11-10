#!/usr/bin/env python3
"""Implements: FR-HOVER-1, FR-HOVER-3, FR-HOVER-4 with real PTYs and fake providers."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

import orjson


PROJECT = Path(__file__).resolve().parents[1]
CLI = Path(os.environ.get("TRANO_TEST_CLI", PROJECT / ".build/debug/trano"))
PROVIDER = r'''
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid
import orjson

provider = Path(sys.argv[0]).name
pane = os.environ['TRANO_SESSION']
fixture = Path(os.environ['TRANO_TEST_FIXTURE'])
session = str(uuid.uuid4())
base = {'session_id': session, 'cwd': os.getcwd()}
def hook(event, generation=None):
    env = dict(os.environ)
    if generation is not None:
        env['TRANO_LAUNCH_ID'] = generation
    subprocess.run([env['TRANO_CLI_PATH'], 'hook', provider], input=orjson.dumps(base | event), env=env, check=True)
hook({'hook_event_name': 'SessionStart', 'source': 'startup'})
hook({'hook_event_name': 'UserPromptSubmit'})
(fixture / (pane + '.ready')).write_bytes(orjson.dumps({'session': session, 'generation': os.environ['TRANO_LAUNCH_ID']}))
request = fixture / (pane + '.request')
while True:
    if request.exists():
        item = orjson.loads(request.read_bytes())
        request.unlink()
        if item.get('exit'):
            break
        for event in item.get('hooks', []):
            hook(event, item.get('generation'))
        for osc in item.get('osc', []):
            sys.stdout.write('\x1b]7501;' + osc + '\x07')
            sys.stdout.flush()
        (fixture / (pane + '.ack')).write_text(str(item['sequence']))
    time.sleep(.02)
'''


class TabActivityIntegration(unittest.TestCase):
    def test_provider_children_and_osc_update_independently_of_root_and_other_panes(self):
        root = Path(tempfile.mkdtemp(prefix="trano-hover-", dir="/tmp"))
        home, binary, runtime = root / "home", root / "bin", root / "runtime"
        home.mkdir()
        binary.mkdir()
        for provider in ("claude", "codex"):
            executable = binary / provider
            executable.write_text("#!" + sys.executable + "\n" + PROVIDER)
            executable.chmod(0o700)
            (home / ("." + provider)).mkdir()
        for name in (".zshenv", ".zprofile", ".zshrc", ".zlogin"):
            (home / name).write_text("export PATH=" + shlex.quote(str(binary)) + ':"$PATH"\n')
        env = dict(os.environ, HOME=str(home), ZDOTDIR=str(home), TRANO_DATA_DIR=str(runtime),
                   TRANO_TEST_FIXTURE=str(root), CLAUDE_CONFIG_DIR=str(home / ".claude"),
                   CODEX_HOME=str(home / ".codex"), PYTHONPATH=str(Path(orjson.__file__).resolve().parents[1]))
        for key in ("TRANO_SESSION", "TRANO_LAUNCH_ID"):
            env.pop(key, None)

        def cli(*args):
            result = subprocess.run([str(CLI), *args], env=env, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            return orjson.loads(result.stdout)["result"]

        def until(predicate):
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline:
                value = predicate()
                if value:
                    return value
                time.sleep(.05)
            captures = [(row["id"], cli("capture", row["id"])) for row in cli("list")]
            self.fail("Timed out waiting for structured activity: " + str(captures))

        def session(pane):
            return next(row for row in cli("list") if row["id"] == pane)

        sequence = 0

        def emit(pane, **payload):
            nonlocal sequence
            sequence += 1
            draft = root / (pane + ".tmp")
            draft.write_bytes(orjson.dumps(payload | {"sequence": sequence}))
            draft.replace(root / (pane + ".request"))
            until(lambda: (root / (pane + ".ack")).exists() and (root / (pane + ".ack")).read_text() == str(sequence))

        def child(pane, task):
            return next((row for row in session(pane).get("agentTasks", []) if row["id"] == task), None)

        try:
            first = cli("launch", "--cwd", str(home))["pane"]["id"]
            layout = cli("do", "pane.split.right", "--pane", first)
            second = layout["focusedPaneID"]
            for pane, provider in ((first, "claude"), (second, "codex")):
                cli("send", pane, provider, "--enter")
                until(lambda: (root / (pane + ".ready")).exists())
                emit(pane, hooks=[{"hook_event_name": "SubagentStart", "agent_id": "worker", "agent_type": "Explore"}])
                until(lambda: child(pane, "worker") is not None)
                self.assertEqual(child(pane, "worker")["activity"]["state"], "running")
                self.assertEqual(session(pane)["activity"]["state"], "running")

            emit(first, hooks=[{"hook_event_name": "PermissionRequest", "agent_id": "worker", "agent_type": "Explore"}])
            until(lambda: child(first, "worker")["activity"]["state"] == "blocked")
            self.assertEqual(child(second, "worker")["activity"]["state"], "running")
            emit(first, hooks=[{"hook_event_name": "SubagentStop", "agent_id": "worker", "agent_type": "Explore"}])
            until(lambda: child(first, "worker")["activity"]["state"] == "done")
            self.assertEqual(session(first)["activity"]["state"], "running")
            before = orjson.loads((root / (first + ".ready")).read_bytes())
            emit(first, generation="stale-generation", hooks=[{"hook_event_name": "SubagentStart", "agent_id": "stale", "agent_type": "Explore"}])
            self.assertIsNone(child(first, "stale"))

            emit(second, osc=["app=codex:id=worker/nested:name=Reviewer:state=working"])
            until(lambda: child(second, "worker/nested") is not None)
            self.assertEqual(child(second, "worker/nested")["parentID"], "worker")
            emit(second, osc=["app=codex:id=worker/nested:state=blocked"])
            until(lambda: child(second, "worker/nested")["activity"]["state"] == "blocked")
            emit(second, osc=["app=codex:id=worker/nested:state=clear"])
            until(lambda: child(second, "worker/nested") is None)
            self.assertEqual(session(second)["activity"]["state"], "running")

            state = cli("state")
            launch = next(row for row in state["agentLaunches"] if row["paneID"] == first)
            self.assertEqual(launch["providerSessionID"], before["session"])
            self.assertEqual(launch["id"], before["generation"])
            self.assertEqual(len(state["layout"]["tabs"]), 1)
            print("Verified real tmux transport: isolated child lifecycle, nested OSC transitions, stale generation rejection, unchanged root conversation and split layout.")
        finally:
            if runtime.exists():
                try:
                    for pane in cli("list"):
                        cli("terminate", pane["id"])
                    subprocess.run(["tmux", "-S", str(runtime / "mux.sock"), "kill-server"], capture_output=True)
                except Exception:
                    pass
            shutil.rmtree(root)


if __name__ == "__main__":
    unittest.main()
