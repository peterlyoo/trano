#!/usr/bin/env python3
import importlib.util
import os
import pathlib
import shlex
import signal
import subprocess
import unittest
import unicodedata
import uuid

import orjson


spec = importlib.util.spec_from_file_location("followup_fixture", pathlib.Path(__file__).with_name("check-followups.py"))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
fixture.FAKE = fixture.FAKE.replace("session = str(uuid.uuid4())", """session_file = root/'provider-session-id'
session = session_file.read_text() if session_file.exists() else str(uuid.uuid4())
session_file.write_text(session)""")
hook_call = " subprocess.run([os.environ['TRANO_CLI_PATH'],'hook','claude'], input=orjson.dumps(payload), check=True)"
assert fixture.FAKE.count(hook_call) == 1
fixture.FAKE = fixture.FAKE.replace(hook_call, """ result = subprocess.run([os.environ['TRANO_CLI_PATH'],'hook','claude'], input=orjson.dumps(payload), check=True, capture_output=True)
 row('native-hook-output.jsonl', dict(event=event, output=result.stdout.decode()))""")
anchor = "   elif event == 'paste':"
assert fixture.FAKE.count(anchor) == 1
fixture.FAKE = fixture.FAKE.replace(anchor, """   elif event in ['decision-ask','decision-poll','decision-abandon']:
    environment = dict(os.environ)
    if command.get('legacy'):
     environment.pop('TRANO_SESSION',None)
     environment.pop('TRANO_LAUNCH_ID',None)
    if command.get('producerGeneration'):
     environment['TRANO_LAUNCH_ID'] = command['producerGeneration']
    arguments = [os.environ['TRANO_CLI_PATH'],'decision-adapter']
    if event == 'decision-ask':
     arguments += ['ask','--wait-ms','1']
     body = orjson.dumps(command['question'])
    else:
     arguments += [event.removeprefix('decision-'),command['requestID']]
     body = None
    result = subprocess.run(arguments,input=body,env=environment,capture_output=True)
    row('adapter-results.jsonl',dict(sequence=command['sequence'],code=result.returncode,data=orjson.loads(result.stdout)))
""" + anchor)


class NativeDecisions(unittest.TestCase):
    def setUp(self):
        self.session = fixture.FollowUpDelivery("test_headless_helper_delivers_exact_multiline_fifo_once_per_armed_turn")
        self.addCleanup(self.session.doCleanups)
        self.session.setUp()

    def launch(self):
        return self.session.cli("state")["agentLaunches"][0]

    def question(self):
        launch = self.launch()
        return dict(schema_version="1.0", request_id=str(uuid.uuid4()), thread_id=str(uuid.uuid4()),
                    source=dict(agent="claude", session_id=launch["providerSessionID"], workspace=launch["cwd"]),
                    question="저장소를 선택해 주세요", options=[
                        dict(id="disk", label="Disk (Recommended)", description="Keep local data"),
                        dict(id="memory", label="Memory", description="Keep in memory")])

    def command(self, event, **values):
        current = self.session
        current.command_count += 1
        command = dict(event=event, sequence=current.command_count, **values)
        with (current.root / "commands.jsonl").open("ab", buffering=0) as output:
            output.write(orjson.dumps(command) + b"\n")
        current.until(lambda: len(current.rows("acks.jsonl")) >= current.command_count)
        if event.startswith("decision-"):
            return next(row for row in current.rows("adapter-results.jsonl") if row["sequence"] == current.command_count)

    def ask(self, question=None, **values):
        question = question or self.question()
        reply = self.command("decision-ask", question=question, **values)
        self.assertEqual(reply["code"], 0, reply)
        self.assertEqual(reply["data"]["status"], "pending")
        entry = next(row for row in self.session.api("decisions.list") if row["id"] == question["request_id"])
        self.assertEqual(entry["paneID"], self.session.pane["id"])
        self.assertEqual(entry["generation"], self.launch()["id"])
        return entry

    def resolve(self, entry, action="choose", **values):
        return self.session.api("decisions.resolve", id=entry["id"], generation=entry["generation"], action=action, **values)

    # Implements: FR-DECISION-1, FR-DECISION-3
    def test_native_cli_choice_other_cancel_and_resolution_race(self):
        entry = self.ask()
        self.resolve(entry, optionID="disk")
        answer = self.command("decision-poll", requestID=entry["id"])["data"]
        self.assertEqual(answer["response"]["action"], "choose")
        self.assertEqual(answer["response"]["selected_option_id"], "disk")
        race = self.command("decision-abandon", requestID=entry["id"])["data"]
        self.assertEqual(race["response"], answer["response"])
        other = self.ask()
        text = unicodedata.normalize("NFD", "한글") + " 👩🏽‍💻\n다른 방법"
        self.resolve(other, action="revise", instruction=text, locale="ko")
        reply = self.command("decision-poll", requestID=other["id"])["data"]["response"]
        self.assertEqual(reply["action"], "revise")
        self.assertEqual(reply["instruction"].encode(), text.encode())
        cancelled = self.ask()
        self.resolve(cancelled, action="cancel")
        self.assertEqual(self.command("decision-poll", requestID=cancelled["id"])["data"]["response"]["action"], "cancel")
        self.assertNotIn(text, orjson.dumps(self.session.cli("state")["events"]).decode())

    # Implements: FR-DECISION-2, FR-QUEUE-2
    def test_pending_or_unread_decision_blocks_stop_and_followup_until_polled(self):
        self.session.command("UserPromptSubmit")
        context = orjson.loads(self.session.rows("native-hook-output.jsonl")[-1]["output"])["hookSpecificOutput"]["additionalContext"]
        self.assertIn("decision-adapter", context)
        entry = self.ask()
        self.session.api("followups.add", paneID=self.session.pane["id"], text="after decision")
        self.session.command("Stop")
        self.session.assert_no_delivery()
        stop = orjson.loads(self.session.rows("native-hook-output.jsonl")[-1]["output"])
        self.assertEqual(stop["decision"], "block")
        self.assertIn("TRANO_LAUNCH_ID", context)
        self.assertEqual(self.session.cli("state")["sessions"][0]["activity"]["state"], "blocked")
        self.resolve(entry, optionID="disk")
        self.session.command("Stop")
        self.session.assert_no_delivery()
        self.command("decision-poll", requestID=entry["id"])
        self.session.command("Stop")
        self.session.until(lambda: len(self.session.rows("received.jsonl")) == 1)
        self.assertEqual(bytes.fromhex(self.session.rows("received.jsonl")[0]["hex"]), b"\x1b[200~after decision\x1b[201~\r")

    # Implements: FR-DECISION-2
    def test_delayed_native_producer_cannot_bind_to_resumed_generation(self):
        old = self.launch()
        self.session.command("exit")
        self.session.until(lambda: self.launch()["lifecycle"] == "exited")
        self.session.command_count = 0
        for name in ["commands.jsonl", "acks.jsonl", "adapter-results.jsonl"]:
            (self.session.root / name).write_bytes(b"")
        self.session.cli("send", self.session.pane["id"], shlex.join([str(fixture.CLI), "account", "exec", self.session.account["id"]]), "--enter")
        self.session.until(lambda: len(self.session.rows("ready.jsonl")) == 2)
        current = self.launch()
        self.assertEqual(current["providerSessionID"], old["providerSessionID"])
        self.assertNotEqual(current["id"], old["id"])
        result = self.command("decision-ask", question=self.question(), producerGeneration=old["id"])
        self.assertNotEqual(result["code"], 0, result)
        self.assertFalse(result["data"]["ok"])
        self.assertEqual(self.session.api("decisions.list"), [])

    # Implements: FR-DECISION-2
    def test_abnormal_exit_abandons_pending_without_disabling_recovery(self):
        entry = self.ask()
        os.kill(self.launch()["providerPID"], signal.SIGTERM)
        self.session.until(lambda: self.launch().get("processID") is None)
        self.assertEqual(self.launch()["lifecycle"], "active")
        self.assertEqual(self.session.api("decisions.list")[0]["status"], "abandoned")
        self.assertEqual(self.session.cli("state")["sessions"][0]["pid"], self.session.pane["pid"])

    # Implements: FR-DECISION-2
    def test_legacy_agent_client_is_allowed_but_unrelated_process_is_rejected(self):
        self.ask(legacy=True)
        result = subprocess.run([str(fixture.CLI), "decision-adapter", "ask", "--wait-ms", "1"], env=self.session.env,
                                input=orjson.dumps(self.question()), capture_output=True, timeout=15)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(orjson.loads(result.stdout)["ok"])
        self.assertEqual(len(self.session.api("decisions.list")), 1)


if __name__ == "__main__":
    unittest.main()
