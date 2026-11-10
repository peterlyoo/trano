#!/usr/bin/env python3
import os
import pathlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

import orjson

PROJECT = pathlib.Path(__file__).resolve().parents[1]
CLI = pathlib.Path(os.environ.get('TRANO_TEST_CLI', PROJECT / '.build/debug/trano'))
FAKE = r'''
import os, pathlib, subprocess, sys, time, uuid, orjson
provider = pathlib.Path(sys.argv[0]).name
root = pathlib.Path(os.environ['TRANO_TEST_FIXTURE'])
args = sys.argv[1:]
if args[:2] == ['auth','status']:
 print(orjson.dumps({'loggedIn':True,'authMethod':'claude.ai','configDirectory':os.environ['CLAUDE_CONFIG_DIR']}).decode()); sys.exit(0)
if 'app-server' in args:
 for line in sys.stdin.buffer:
  item = orjson.loads(line)
  if 'id' not in item: continue
  result = {} if item['method']=='initialize' else {'rateLimits':{'primary':{'usedPercent':100,'resetsAt':int(time.time()+3600)}},'ordinaryUsageAllowed':pathlib.Path(os.environ['CODEX_HOME']).name!=(root/'source-account').read_text()}
  print(orjson.dumps({'id':item['id'],'result':result}).decode(),flush=True)
 sys.exit(0)
flag = '--resume' if provider == 'claude' else 'resume'
resuming = flag in args
session = args[args.index(flag)+1] if resuming else str(uuid.uuid4())
config = pathlib.Path(os.environ['CLAUDE_CONFIG_DIR' if provider == 'claude' else 'CODEX_HOME'])
if provider=='claude':
 file=config/'projects'/'fixture'/(session+'.jsonl')
 row={'sessionId':session,'cwd':os.getcwd(),'type':'user','message':{'role':'user','content':'Synthetic switch fixture'}}
else:
 file=config/'sessions'/'2026'/'11'/'11'/('rollout-2026-11-11T00-00-00-'+session+'.jsonl')
 row={'type':'session_meta','payload':{'id':session,'cwd':os.getcwd(),'account_scoped':False}}
if resuming and (root/'reject-resume').exists() and config.name != (root/'source-account').read_text():
 subprocess.run([os.environ['TRANO_CLI_PATH'],'hook',provider],input=orjson.dumps({'session_id':session,'cwd':os.getcwd(),'hook_event_name':'SessionEnd'}),check=True)
 sys.exit(2)
if resuming:
 assert file.exists(), 'Exact conversation was not transferred'
else:
 file.parent.mkdir(parents=True,exist_ok=True)
 file.write_bytes(orjson.dumps(row)+b'\n')
def hook(event,**extra):
 payload={'session_id':session,'cwd':os.getcwd(),'hook_event_name':event,'source':'resume' if resuming else 'startup',**extra}
 subprocess.run([os.environ['TRANO_CLI_PATH'],'hook',provider],input=orjson.dumps(payload),check=True)
hook('SessionStart')
with (root/'launches.jsonl').open('ab',buffering=0) as f:
 f.write(orjson.dumps({'session':session,'account':config.name,'pid':os.getpid(),'resume':resuming,'args':args})+b'\n')
if not resuming:
 hook('UserPromptSubmit'); hook('PreToolUse',tool_use_id='fixture-tool')
 if provider=='claude' and not (root/'late-usage').exists(): hook('StopFailure',error='rate_limit')
 while not (root/'release-tool').exists(): time.sleep(.05)
 hook('PostToolUse',tool_use_id='fixture-tool')
 if (root/'late-usage').exists():
  hook('Stop'); time.sleep(.7)
  subprocess.run([os.environ['TRANO_CLI_PATH'],'usage-hook'],input=orjson.dumps({'session_id':session,'rate_limits':{'five_hour':{'used_percentage':100,'resets_at':int(time.time()+3600)}}}),check=True)
 else: hook('StopFailure',error='rate_limit') if provider=='claude' else hook('Stop')
else: hook('Stop')
while True: time.sleep(.1)
'''


class AccountSwitch(unittest.TestCase):
    # Implements: U18, U19, FR-ACCOUNT-2
    def test_automatic_same_provider_handoff_preserves_conversation_and_waits_for_tools(self):
        for provider in ['claude', 'codex']:
            with self.subTest(provider=provider):
                self.check_handoff(provider)

    def test_late_usage_after_stop_triggers_handoff(self):
        self.check_handoff('claude', late=True)

    def test_failed_target_resume_restores_original_mapping(self):
        self.check_handoff('claude', reject=True)

    def check_handoff(self, provider, late=False, reject=False):
        root = pathlib.Path(tempfile.mkdtemp(prefix='trano-switch-', dir='/tmp'))
        home, binary, runtime = root/'home', root/'bin', root/'runtime'
        home.mkdir(); binary.mkdir()
        for name in ['claude', 'codex']:
            file = binary/name
            file.write_text('#!'+sys.executable+'\n'+FAKE)
            file.chmod(0o700)
        for name in ['.zshenv', '.zprofile', '.zshrc']:
            (home/name).write_text('export PATH='+shlex.quote(str(binary))+':"$PATH"\n')
        env = dict(os.environ, HOME=str(home), ZDOTDIR=str(home), TRANO_DATA_DIR=str(runtime), TRANO_TEST_FIXTURE=str(root))
        env['PYTHONPATH'] = str(pathlib.Path(orjson.__file__).resolve().parents[1])
        for key in ['TRANO_SESSION', 'TRANO_LAUNCH_ID', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME']:
            env.pop(key, None)

        def cli(*args):
            result = subprocess.run([str(CLI), *args], env=env, capture_output=True, timeout=25)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            return orjson.loads(result.stdout)['result']

        def rows():
            file = root/'launches.jsonl'
            return [orjson.loads(line) for line in file.read_bytes().splitlines()] if file.exists() else []

        def until(check):
            deadline = time.monotonic()+18
            while time.monotonic()<deadline:
                value = check()
                if value: return value
                time.sleep(.05)
            self.fail('Timed out; state='+str(cli('state')))

        try:
            source = cli('account', 'add', '--provider', provider, '--label', 'Source')
            target = cli('account', 'add', '--provider', provider, '--label', 'Target')
            (root/'source-account').write_text(source['id'])
            if late: (root/'late-usage').touch()
            if reject: (root/'reject-resume').touch()
            credentials = runtime/'accounts'/target['id']/'.fixture-auth'
            credentials.write_text('synthetic-target-identity\n')
            pane = cli('launch', '--cwd', str(root))['pane']
            cli('send', pane['id'], shlex.join([str(CLI), 'account', 'exec', source['id']]), '--enter')
            until(lambda: any(item.get('activeTools') == ['fixture-tool'] for item in cli('state').get('supervision', [])))
            cli('account', 'switching', 'on')
            time.sleep(.8)
            self.assertEqual(len(rows()), 1, 'A provider was switched with a tool in flight')
            (root/'release-tool').touch()
            if reject:
                until(lambda: len(rows()) == 2 and rows()[-1]['account'] == source['id'] and rows()[-1]['resume'])
                state = cli('state')
                original = state['agentLaunches'][0]
                self.assertEqual(original['accountID'], source['id'])
                self.assertEqual(original['providerSessionID'], rows()[0]['session'])
                self.assertEqual(original['lifecycle'], 'active')
                self.assertNotEqual(original.get('providerPID'), rows()[0]['pid'])
                self.assertEqual(list((runtime/'accounts'/target['id']).glob('projects/**/*.jsonl')), [])
                self.assertEqual(credentials.read_text(), 'synthetic-target-identity\n')
                return
            launches = until(lambda: rows() if len(rows())==2 else None)
            until(lambda: cli('state')['agentLaunches'][0]['accountID'] == target['id'])
            self.assertEqual(launches[0]['session'], launches[1]['session'])
            self.assertEqual(launches[1]['account'], target['id'])
            self.assertTrue(launches[1]['resume'])
            with self.assertRaises(ProcessLookupError): os.kill(launches[0]['pid'], 0)
            self.assertEqual(credentials.read_text(), 'synthetic-target-identity\n')
            time.sleep(.6)
            self.assertEqual(len(rows()), 2)
            print('Verified '+provider+': tool boundary, old process reaped, exact session resume, target credentials preserved, no duplicate launch.')
        finally:
            try:
                for pane in cli('list'): cli('terminate', pane['id'])
            finally: shutil.rmtree(root)


if __name__ == '__main__':
    unittest.main()
