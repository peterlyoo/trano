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
LEGACY = pathlib.Path(os.environ.get('TRANO_TEST_LEGACY_CLI', '/Applications/Trano.app/Contents/MacOS/trano'))
FAKE = r'''
import os, pathlib, subprocess, sys, time, uuid, orjson
provider = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
flag = '--resume' if provider == 'claude' else 'resume'
session = args[args.index(flag)+1] if flag in args else str(uuid.uuid4())
root = pathlib.Path(os.environ['TRANO_TEST_FIXTURE'])
payload = {'session_id':session,'cwd':os.getcwd(),'hook_event_name':'SessionStart','source':'resume' if flag in args else 'startup'}
if '--trano-probe' not in args:
 subprocess.run([sys.argv[0],'--trano-probe'],check=True)
subprocess.run([os.environ['TRANO_CLI_PATH'],'hook',provider],input=orjson.dumps(payload),check=True)
if '--trano-probe' in args: sys.exit(0)
row = {'pane':os.environ['TRANO_SESSION'],'session':session,'cwd':os.getcwd(),'provider':provider,'args':args,'cli':os.environ['TRANO_CLI_PATH']}
with (root/'launches.jsonl').open('ab',buffering=0) as f: f.write(orjson.dumps(row)+b'\n')
payload['hook_event_name']='Stop'
subprocess.run([os.environ['TRANO_CLI_PATH'],'hook',provider],input=orjson.dumps(payload),check=True)
while True: time.sleep(.2)
'''


@unittest.skipUnless(LEGACY.exists() and shutil.which('tmux'), 'needs a tmux-based legacy trano CLI')
class Migration(unittest.TestCase):
    # Implements: FR-RECOVERY-1, FR-RECOVERY-2
    def test_legacy_tmux_panes_move_to_the_pty_host_and_resume_agents(self):
        root = pathlib.Path(tempfile.mkdtemp(prefix='trmig-', dir='/tmp'))
        home, binary, runtime = root/'home', root/'bin', root/'rt'
        home.mkdir(); binary.mkdir()
        script = binary/'claude'
        script.write_text('#!'+sys.executable+'\n'+FAKE)
        script.chmod(0o700)
        (home/'.claude').mkdir()
        project = root/"한글 project 'quote';"
        project.mkdir()
        for file in ['.zshenv', '.zprofile', '.zshrc', '.zlogin']:
            (home/file).write_text('export PATH='+shlex.quote(str(binary))+':"$PATH"\n')
        env = dict(os.environ, HOME=str(home), ZDOTDIR=str(home), TRANO_DATA_DIR=str(runtime), TRANO_TEST_FIXTURE=str(root),
                   CLAUDE_CONFIG_DIR=str(home/'.claude'))
        env['PYTHONPATH'] = str(pathlib.Path(orjson.__file__).resolve().parents[1])
        for key in ['TRANO_SESSION', 'TRANO_LAUNCH_ID', 'TMUX', 'TMUX_PANE']: env.pop(key, None)

        def run(cli, *args):
            result = subprocess.run([str(cli), *args], env=env, capture_output=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            return orjson.loads(result.stdout)['result']

        def until(check, seconds=15):
            deadline = time.monotonic()+seconds
            while time.monotonic() < deadline:
                value = check()
                if value: return value
                time.sleep(.05)
            self.fail('Timed out')

        def rows():
            file = root/'launches.jsonl'
            return [orjson.loads(line) for line in file.read_bytes().splitlines()] if file.exists() else []

        try:
            agent = run(LEGACY, 'launch', '--cwd', str(project))['pane']
            shell = run(LEGACY, 'launch', '--cwd', str(project))['pane']
            run(LEGACY, 'send', agent['id'], 'claude', '--enter')
            first = until(lambda: rows() if len(rows()) == 1 else None)[0]
            moved = root/'moved dir'
            moved.mkdir()
            run(LEGACY, 'send', shell['id'], 'cd '+shlex.quote(str(moved)), '--enter')
            until(lambda: pathlib.Path(next(s for s in run(LEGACY, 'state')['sessions'] if s['id'] == shell['id'])['cwd']).resolve() == moved.resolve())
            self.assertTrue((runtime/'mux.sock').exists())
            before = {s['id']: s['pid'] for s in run(LEGACY, 'list')}
            layout = run(LEGACY, 'state')['layout']

            result = run(CLI, 'migrate-legacy')
            self.assertEqual(sorted(result['migrated']), sorted([agent['id'], shell['id']]), result)
            self.assertEqual(result['failed'], {})
            for pid in before.values():
                with self.assertRaises(ProcessLookupError): os.kill(pid, 0)
            self.assertFalse((runtime/'mux.sock').exists())
            resumed = until(lambda: rows() if len(rows()) == 2 else None)[1]
            self.assertEqual(resumed['pane'], agent['id'])
            self.assertEqual(resumed['session'], first['session'])
            self.assertIn('--resume', resumed['args'])
            self.assertEqual(pathlib.Path(resumed['cwd']).resolve(), project.resolve())
            self.assertEqual(pathlib.Path(resumed['cli']).resolve(), CLI.resolve())
            after = {s['id']: s for s in run(CLI, 'list')}
            self.assertTrue(all(after[i]['alive'] and after[i]['pid'] != before[i] for i in before))
            self.assertEqual(pathlib.Path(after[shell['id']]['cwd']).resolve(), moved.resolve())
            self.assertEqual(run(CLI, 'state')['layout'], layout)
            self.assertEqual(run(CLI, 'check')['running'], '1')
            again = run(CLI, 'migrate-legacy')
            self.assertEqual(again['migrated'], [])
            time.sleep(.3)
            self.assertEqual(len(rows()), 2, 'A repeated migration must not start another agent')
            print('Verified: legacy tmux panes stopped, same pane IDs restored on the PTY host, Claude resumed with its conversation ID, shell cwd and layout kept, migration idempotent.')
        finally:
            if runtime.exists():
                for cli in [CLI, LEGACY]:
                    try:
                        for pane in run(cli, 'list'): run(cli, 'terminate', pane['id'])
                    except Exception: pass
                subprocess.run(['tmux', '-S', str(runtime/'mux.sock'), 'kill-server'], env=env, capture_output=True)
            shutil.rmtree(root, ignore_errors=True)


if __name__ == '__main__':
    unittest.main()
