#!/usr/bin/env python3
import fcntl
import os
import pathlib
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

import orjson

PROJECT = pathlib.Path(__file__).resolve().parents[1]
CLI = pathlib.Path(os.environ.get("TRANO_TEST_CLI", PROJECT / ".build/debug/trano")).resolve()
FAKE = r'''
import os, pathlib, select, signal, subprocess, sys, termios, time, tty, uuid, orjson
root = pathlib.Path(os.environ['TRANO_TEST_FIXTURE'])
session = str(uuid.uuid4())
def row(name, value):
 with (root/name).open('ab', buffering=0) as output:
  output.write(orjson.dumps(value)+b'\n')
def hook(event, **extra):
 payload = dict(session_id=session, cwd=os.getcwd(), hook_event_name=event, **extra)
 subprocess.run([os.environ['TRANO_CLI_PATH'],'hook','claude'], input=orjson.dumps(payload), check=True)
def child_hook(event, stale=False):
 environment = dict(os.environ)
 if stale: environment['TRANO_LAUNCH_ID'] = str(uuid.uuid4())
 payload = orjson.dumps(dict(session_id=session,cwd=os.getcwd(),hook_event_name=event))
 subprocess.run([sys.executable, '-c', 'import os,subprocess,sys;subprocess.run([os.environ["TRANO_CLI_PATH"],"hook","claude"],input=bytes.fromhex(sys.argv[1]),check=True)', payload.hex()], env=environment, check=True)
saved = termios.tcgetattr(0)
tty.setraw(0)
try:
 child_hook('SessionStart')
 hook('SessionStart')
 os.write(1,b'\x1b[?2004h')
 row('ready.jsonl',dict(pid=os.getpid(),wrapper=os.getppid(),session=session,pgid=os.getpgrp(),foreground=os.tcgetpgrp(0)))
 commands = 0
 incoming = b''
 while True:
  file = root/'commands.jsonl'
  rows = file.read_bytes().splitlines() if file.exists() else []
  for raw in rows[commands:]:
   command = orjson.loads(raw)
   event = command['event']
   if event == 'exit':
    hook('Stop')
    row('acks.jsonl',command)
    sys.exit(0)
   elif event == 'paste': os.write(1,b'\x1b[?2004l\x1b[?2004h')
   elif event == 'no-paste': os.write(1,b'\x1b[?2004l')
   elif event == 'child': child_hook('Stop')
   elif event == 'stale': child_hook('Stop',stale=True)
   else: hook(event)
   commands += 1
   row('acks.jsonl',command)
  if select.select([0],[],[],.02)[0]:
   chunk=os.read(0,65536)
   if not chunk: break
   incoming += chunk
   end = b'\x1b[201~\r'
   while end in incoming:
    index = incoming.index(end)+len(end)
    frame,incoming=incoming[:index],incoming[index:]
    row('received.jsonl',dict(hex=frame.hex()))
finally:
 termios.tcsetattr(0,termios.TCSANOW,saved)
 os.write(1,b'\x1b[?2004l')
'''


class FollowUpDelivery(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="trano-followups-", dir="/tmp"))
        home, binary = self.root / "home", self.root / "bin"
        home.mkdir()
        binary.mkdir()
        fake = binary / "claude"
        fake.write_text("#!" + sys.executable + "\n" + FAKE)
        fake.chmod(0o700)
        for name in [".zshenv", ".zprofile", ".zshrc"]:
            (home / name).write_text("export PATH=" + shlex.quote(str(binary)) + ':"$PATH"\n')
        self.env = dict(os.environ, HOME=str(home), ZDOTDIR=str(home), TRANO_DATA_DIR=str(self.root / "runtime"),
                        TRANO_TEST_FIXTURE=str(self.root), PATH=str(binary) + os.pathsep + os.environ["PATH"],
                        PYTHONPATH=str(pathlib.Path(orjson.__file__).resolve().parents[1]))
        for key in ["TRANO_SESSION", "TRANO_LAUNCH_ID", "CLAUDE_CONFIG_DIR", "CODEX_HOME"]:
            self.env.pop(key, None)
        self.service = None
        self.pane = None
        self.command_count = 0
        self.addCleanup(self.cleanup)
        self.start_service()
        self.account = self.cli("account", "add", "--provider", "claude", "--label", "Fixture")
        self.pane = self.cli("launch", "--cwd", str(self.root))["pane"]
        self.cli("send", self.pane["id"], shlex.join([str(CLI), "account", "exec", self.account["id"]]), "--enter")
        ready = self.until(lambda: self.rows("ready.jsonl"))[0]
        self.assertEqual(ready["pgid"], ready["foreground"])
        self.until(lambda: any(item.get("enabled") for item in self.cli("state").get("followUpPasteStates", [])))

    def cleanup(self):
        try:
            if self.pane is not None:
                self.cli("terminate", self.pane["id"])
        finally:
            self.stop_service()
            shutil.rmtree(self.root)

    def start_service(self):
        self.service = subprocess.Popen([str(CLI), "serve"], env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.until(lambda: (self.root / "runtime" / "api.sock").exists())
        self.until(lambda: self.api("server.info"))

    def stop_service(self):
        if self.service is not None and self.service.poll() is None:
            self.service.terminate()
            self.service.wait(timeout=8)
        self.service = None

    def cli(self, *arguments):
        result = subprocess.run([str(CLI), *arguments], env=self.env, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr.decode() + result.stdout.decode())
        return orjson.loads(result.stdout)["result"]

    def api(self, method, **parameters):
        return self.cli("api", method, orjson.dumps(parameters).decode())

    def rows(self, name):
        file = self.root / name
        return [orjson.loads(line) for line in file.read_bytes().splitlines()] if file.exists() else []

    def until(self, check, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = check()
            if result:
                return result
            time.sleep(0.03)
        self.fail("Timed out waiting for fixture state")

    def command(self, event):
        self.command_count += 1
        with (self.root / "commands.jsonl").open("ab", buffering=0) as output:
            output.write(orjson.dumps(dict(event=event, sequence=self.command_count)) + b"\n")
        self.until(lambda: len(self.rows("acks.jsonl")) >= self.command_count)

    def queued(self):
        return self.api("followups.list", paneID=self.pane["id"])

    def assert_no_delivery(self):
        time.sleep(0.85)
        self.assertEqual(self.rows("received.jsonl"), [])

    # Implements: FR-QUEUE-1, FR-QUEUE-2, FR-QUEUE-3
    def test_headless_helper_delivers_exact_multiline_fifo_once_per_armed_turn(self):
        first = self.api("followups.add", paneID=self.pane["id"], text="first")
        second = self.api("followups.add", paneID=self.pane["id"], text="edit me")
        deleted = self.api("followups.add", paneID=self.pane["id"], text="delete me")
        text = "  한글 👩🏽‍💻\n'quotes'; $(false)\tline two\ntrailing;"
        self.api("followups.update", id=second["id"], text=text)
        self.api("followups.remove", id=deleted["id"])
        self.stop_service()
        self.start_service()
        self.assertEqual([item["id"] for item in self.queued()], [first["id"], second["id"]])
        self.command("Stop")
        self.assert_no_delivery()
        self.command("UserPromptSubmit")
        self.command("PostToolUseFailure")
        self.command("PreModelRequest")
        self.command("Stop")
        self.until(lambda: len(self.rows("received.jsonl")) == 1)
        self.until(lambda: len(self.queued()) == 1)
        self.assertEqual(bytes.fromhex(self.rows("received.jsonl")[0]["hex"]), b"\x1b[200~first\x1b[201~\r")
        self.command("Stop")
        time.sleep(0.85)
        self.assertEqual(len(self.rows("received.jsonl")), 1)
        self.command("UserPromptSubmit")
        self.command("Stop")
        self.until(lambda: len(self.rows("received.jsonl")) == 2)
        self.assertEqual(bytes.fromhex(self.rows("received.jsonl")[1]["hex"]), b"\x1b[200~" + text.encode() + b"\x1b[201~\r")
        self.until(lambda: not self.queued())
        state = self.cli("state")
        self.assertEqual(state["sessions"][0]["pid"], self.pane["pid"])
        self.assertNotIn(text, orjson.dumps(state.get("events", [])).decode())

    # Implements: FR-QUEUE-1, FR-QUEUE-3
    @unittest.skipUnless(os.environ.get("TRANO_PREVIOUS_CLI"), "Previous-schema binary not supplied")
    def test_previous_schema_writer_cannot_erase_queued_input(self):
        item = self.api("followups.add", paneID=self.pane["id"], text="preserve across older writer")
        result = subprocess.run([os.environ["TRANO_PREVIOUS_CLI"], "status", self.pane["id"], "idle"],
                                env=self.env, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr.decode() + result.stdout.decode())
        self.assertEqual([row["id"] for row in self.queued()], [item["id"]])
        self.assert_no_delivery()
        self.command("UserPromptSubmit")
        self.command("Stop")
        self.until(lambda: len(self.rows("received.jsonl")) == 1)
        self.assertEqual(bytes.fromhex(self.rows("received.jsonl")[0]["hex"]), b"\x1b[200~preserve across older writer\x1b[201~\r")

    # Implements: FR-QUEUE-2
    def test_explicit_child_stale_blocked_and_failed_completion_never_deliver(self):
        item = self.api("followups.add", paneID=self.pane["id"], text="never from these signals")
        self.command("UserPromptSubmit")
        self.api("activity.report", id=self.pane["id"], state="done", agent="claude")
        self.command("child")
        self.command("stale")
        self.assert_no_delivery()
        self.command("UserPromptSubmit")
        self.command("PermissionRequest")
        self.command("Stop")
        self.assert_no_delivery()
        self.command("StopFailure")
        self.command("Stop")
        self.assert_no_delivery()
        self.assertEqual(self.queued()[0]["id"], item["id"])
        launch = self.cli("state")["agentLaunches"][0]
        self.assertEqual(launch["providerSessionID"], self.rows("ready.jsonl")[0]["session"])

    # Implements: FR-QUEUE-2, FR-QUEUE-3
    def test_provider_exit_never_delivers_queued_input_to_fallback_shell(self):
        marker = self.root / "must-not-exist"
        item = self.api("followups.add", paneID=self.pane["id"], text="touch " + shlex.quote(str(marker)))
        self.command("UserPromptSubmit")
        self.command("exit")
        self.until(lambda: self.queued()[0]["status"] == "needsReview")
        self.assert_no_delivery()
        self.assertFalse(marker.exists())
        self.assertEqual(self.queued()[0]["id"], item["id"])
        self.assertEqual(self.cli("list")[0]["pid"], self.pane["pid"])

    # Implements: FR-QUEUE-2, FR-QUEUE-3
    def test_absent_paste_mode_waits_without_typing_and_resumes_only_after_verification(self):
        self.command("no-paste")
        self.until(lambda: not self.cli("state")["followUpPasteStates"][0]["enabled"])
        item = self.api("followups.add", paneID=self.pane["id"], text="safe after mode change")
        self.command("UserPromptSubmit")
        self.command("Stop")
        self.assert_no_delivery()
        self.command("paste")
        self.until(lambda: self.cli("state")["followUpPasteStates"][0]["enabled"])
        self.until(lambda: len(self.rows("received.jsonl")) == 1)
        self.assertEqual(bytes.fromhex(self.rows("received.jsonl")[0]["hex"]), b"\x1b[200~safe after mode change\x1b[201~\r")
        self.until(lambda: not self.queued())

    # Implements: FR-QUEUE-2, FR-QUEUE-3
    def test_old_output_monitor_is_upgraded_without_restarting_or_resizing_the_pane(self):
        self.stop_service()
        tmux = self.cli("check")["tmux"]
        base = [tmux, "-S", str(self.root / "runtime" / "mux.sock")]

        def mux(*arguments):
            return subprocess.run(base + list(arguments), env=self.env, check=True, capture_output=True).stdout

        before = mux("display-message", "-p", "-t", self.pane["id"], "#{pane_pid},#{pane_width},#{pane_height}")
        mux("pipe-pane", "-O", "-t", self.pane["id"], "exec /bin/cat >/dev/null")
        with (self.root / "runtime" / "state.lock").open("r+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            continuity = self.root / "runtime" / "continuity.json"
            state_file = continuity if continuity.exists() else self.root / "runtime" / "state.json"
            state = orjson.loads(state_file.read_bytes())
            state["followUpPasteStates"] = []
            stage = state_file.with_suffix(".fixture")
            stage.write_bytes(orjson.dumps(state))
            stage.chmod(0o600)
            stage.replace(state_file)
        self.start_service()
        self.api("followups.add", paneID=self.pane["id"], text="after monitor upgrade")
        self.until(lambda: self.cli("state").get("followUpPasteStates"))
        self.command("UserPromptSubmit")
        self.command("Stop")
        self.assert_no_delivery()
        self.command("paste")
        self.until(lambda: len(self.rows("received.jsonl")) == 1)
        self.assertEqual(bytes.fromhex(self.rows("received.jsonl")[0]["hex"]), b"\x1b[200~after monitor upgrade\x1b[201~\r")
        self.assertEqual(mux("display-message", "-p", "-t", self.pane["id"], "#{pane_pid},#{pane_width},#{pane_height}"), before)
        self.assertEqual(self.cli("state")["agentLaunches"][0]["providerPID"], self.rows("ready.jsonl")[0]["pid"])

    # Implements: FR-QUEUE-2, FR-QUEUE-3
    def test_restarted_agent_requires_explicit_rebinding_and_a_new_completion(self):
        item = self.api("followups.add", paneID=self.pane["id"], text="requires review after restart")
        old_generation = item["generation"]
        self.command("exit")
        self.until(lambda: self.queued()[0]["status"] == "needsReview")
        self.command_count = 0
        (self.root / "commands.jsonl").write_bytes(b"")
        (self.root / "acks.jsonl").write_bytes(b"")
        self.cli("send", self.pane["id"], shlex.join([str(CLI), "account", "exec", self.account["id"]]), "--enter")
        self.until(lambda: len(self.rows("ready.jsonl")) == 2)
        self.command("UserPromptSubmit")
        self.command("Stop")
        self.assert_no_delivery()
        held = self.queued()[0]
        self.assertEqual(held["generation"], old_generation)
        rebound = self.api("followups.update", id=held["id"], text=held["text"])
        self.assertNotEqual(rebound["generation"], old_generation)
        time.sleep(0.85)
        self.assertEqual(self.rows("received.jsonl"), [])
        self.command("UserPromptSubmit")
        self.command("Stop")
        self.until(lambda: len(self.rows("received.jsonl")) == 1)
        self.until(lambda: not self.queued())


if __name__ == "__main__":
    unittest.main()
