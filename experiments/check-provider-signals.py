#!/usr/bin/env python3
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
CLI = pathlib.Path(os.environ.get('TRANO_TEST_CLI', PROJECT / '.build/debug/trano'))
FAKE = r'''
import os, pathlib, signal, subprocess, sys, time, uuid, orjson
root = pathlib.Path(os.environ['TRANO_TEST_FIXTURE'])
args = sys.argv[1:]
config = pathlib.Path(os.environ['CLAUDE_CONFIG_DIR'])
resuming = '--resume' in args
session = args[args.index('--resume')+1] if resuming else str(uuid.uuid4())
file = config/'projects'/'fixture'/(session+'.jsonl')
if resuming:
 assert file.exists(), 'Original conversation was not preserved'
else:
 file.parent.mkdir(parents=True, exist_ok=True)
 file.write_bytes(orjson.dumps({'sessionId':session,'cwd':os.getcwd(),'type':'user','message':{'role':'user','content':'Synthetic signal fixture'}})+b'\n')
def hook(event):
 subprocess.run([os.environ['TRANO_CLI_PATH'],'hook','claude'],input=orjson.dumps({'session_id':session,'cwd':os.getcwd(),'hook_event_name':event}),check=True)
def row(name, **values):
 with (root/name).open('ab', buffering=0) as output:
  output.write(orjson.dumps(values)+b'\n')
def cancel(*_):
 row('interrupts.jsonl',pid=os.getpid())
 hook('Stop')
signal.signal(signal.SIGINT, cancel)
hook('SessionStart')
row('launches.jsonl',session=session,account=config.name,pid=os.getpid(),wrapper=os.getppid(),pgid=os.getpgrp(),foreground=os.tcgetpgrp(0),resume=resuming,args=args)
if not resuming:
 hook('UserPromptSubmit')
else:
 hook('Stop')
finished = False
while True:
 if not resuming and not finished and (root/'finish-turn').exists():
  hook('Stop'); finished = True
 time.sleep(.05)
'''


class ProviderSignals(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix='trano-provider-signals-', dir='/tmp'))
        home, binary = self.root/'home', self.root/'bin'
        home.mkdir(); binary.mkdir()
        fake = binary/'claude'
        fake.write_text('#!'+sys.executable+'\n'+FAKE)
        fake.chmod(0o700)
        for name in ['.zshenv', '.zprofile', '.zshrc']:
            (home/name).write_text('export PATH='+shlex.quote(str(binary))+':"$PATH"\n')
        self.env = dict(os.environ, HOME=str(home), ZDOTDIR=str(home), TRANO_DATA_DIR=str(self.root/'runtime'),
                        TRANO_TEST_FIXTURE=str(self.root), PATH=str(binary)+os.pathsep+os.environ['PATH'])
        self.env['PYTHONPATH'] = str(pathlib.Path(orjson.__file__).resolve().parents[1])
        for key in ['TRANO_SESSION', 'TRANO_LAUNCH_ID', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME']:
            self.env.pop(key, None)
        self.source = self.cli('account', 'add', '--provider', 'claude', '--label', 'Source')
        self.target = self.cli('account', 'add', '--provider', 'claude', '--label', 'Target')
        self.pane = self.cli('launch', '--cwd', str(self.root))['pane']
        self.cli('send', self.pane['id'], shlex.join([str(CLI), 'account', 'exec', self.source['id']]), '--enter')
        self.until(lambda: self.rows('launches.jsonl'))
        self.until(lambda: any(not value['atTurnBoundary'] for value in self.cli('state')['supervision']))

    def tearDown(self):
        try:
            for pane in self.cli('list'):
                self.cli('terminate', pane['id'])
        finally:
            shutil.rmtree(self.root)

    def cli(self, *args):
        result = subprocess.run([str(CLI), *args], env=self.env, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return orjson.loads(result.stdout)['result']

    def rows(self, name):
        file = self.root/name
        return [orjson.loads(line) for line in file.read_bytes().splitlines()] if file.exists() else []

    def until(self, check, timeout=8):
        deadline = time.monotonic()+timeout
        while time.monotonic()<deadline:
            result = check()
            if result:
                return result
            time.sleep(.03)
        self.fail('Timed out; state='+str(self.cli('state')))

    def cancel(self, terminal=True):
        if terminal:
            self.cli('send', self.pane['id'], '\x03')
        else:
            os.kill(self.rows('launches.jsonl')[0]['wrapper'], signal.SIGINT)
        self.until(lambda: self.rows('interrupts.jsonl'))
        self.until(lambda: any(value['atTurnBoundary'] for value in self.cli('state')['supervision']))
        time.sleep(.6)

    # Implements: U18, U19, FR-ACCOUNT-2
    def test_terminal_turn_cancel_is_delivered_once_then_switches(self):
        self.cancel()
        self.assertEqual(len(self.rows('interrupts.jsonl')), 1, 'Terminal SIGINT must not be forwarded a second time')
        first = self.rows('launches.jsonl')[0]
        self.assertEqual(first['pgid'], first['foreground'])
        self.assertNotEqual(first['pgid'], os.getpgid(first['wrapper']))
        self.assert_switch()

    # Implements: U18, U19, FR-ACCOUNT-2
    def test_wrapper_directed_turn_cancel_does_not_disable_later_switches(self):
        self.cancel(terminal=False)
        self.assertEqual(len(self.rows('interrupts.jsonl')), 1)
        self.assert_switch()

    def assert_switch(self):
        self.cli('account', 'switch', self.pane['id'], self.target['id'])
        rows = self.until(lambda: self.rows('launches.jsonl') if len(self.rows('launches.jsonl')) == 2 else None)
        self.assertEqual(rows[1]['account'], self.target['id'])
        self.assertEqual(rows[1]['session'], rows[0]['session'])
        self.assertTrue(rows[1]['resume'])
        self.assertEqual(rows[1]['args'][-2:], ['--resume', rows[0]['session']])

    # Implements: U18, U19, FR-ACCOUNT-2
    def test_target_account_setup_exception_resumes_preserved_source(self):
        (self.root/'finish-turn').touch()
        self.until(lambda: any(value['atTurnBoundary'] for value in self.cli('state')['supervision']))
        conflict = self.root/'runtime'/'accounts'/self.target['id']/'trano-mcp.json'
        conflict.write_text('{"fixture":"user-modified"}\n')
        self.cli('account', 'switch', self.pane['id'], self.target['id'])
        rows = self.until(lambda: self.rows('launches.jsonl') if len(self.rows('launches.jsonl')) == 2 else None)
        self.assertEqual(rows[1]['account'], self.source['id'])
        self.assertEqual(rows[1]['session'], rows[0]['session'])
        self.assertTrue(rows[1]['resume'])
        self.assertEqual(rows[1]['args'][-2:], ['--resume', rows[0]['session']])
        self.assertEqual(conflict.read_text(), '{"fixture":"user-modified"}\n')
        self.assertEqual(list(conflict.parent.glob('projects/**/*.jsonl')), [])
        launch = self.cli('state')['agentLaunches'][0]
        self.assertEqual(launch['accountID'], self.source['id'])
        self.assertEqual(launch['providerSessionID'], rows[0]['session'])


if __name__ == '__main__':
    unittest.main()
