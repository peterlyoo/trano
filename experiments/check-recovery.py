#!/usr/bin/env python3
import concurrent.futures
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
import os, pathlib, signal, subprocess, sys, time, uuid, orjson
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
row = {'pane':os.environ['TRANO_SESSION'],'session':session,'generation':os.environ.get('TRANO_LAUNCH_ID'),'cwd':os.getcwd(),'provider':provider,'args':args,'config':os.environ.get('CLAUDE_CONFIG_DIR' if provider == 'claude' else 'CODEX_HOME'),'foreignBlock':os.environ.get('REX_BLOCK')}
with (root/'launches.jsonl').open('ab',buffering=0) as f: f.write(orjson.dumps(row)+b'\n')
payload['hook_event_name']='Stop'
subprocess.run([os.environ['TRANO_CLI_PATH'],'hook',provider],input=orjson.dumps(payload),check=True)
while not (root/('exit-'+os.environ['TRANO_SESSION'])).exists(): time.sleep(.05)
'''


class Recovery(unittest.TestCase):
    # Implements: FR-RECOVERY-1, FR-RECOVERY-2, FR-RECOVERY-3
    def test_recovery_after_process_loss_uses_exact_ids_without_duplicates(self):
        root = pathlib.Path(tempfile.mkdtemp(prefix='trano-reboot-', dir='/tmp'))
        home, binary, runtime = root/'home', root/'bin', root/'runtime'
        home.mkdir(); binary.mkdir()
        for name in ['claude', 'codex']:
            script = binary/name
            script.write_text('#!'+sys.executable+'\n'+FAKE)
            script.chmod(0o700)
            (home/('.'+name)).mkdir()
        project = root/"한글 project 'quote';"
        project.mkdir()
        for file in ['.zshenv', '.zprofile', '.zshrc', '.zlogin']:
            (home/file).write_text('print -r -- '+shlex.quote(file)+' >> "$TRANO_TEST_FIXTURE/startup"\nexport PATH='+shlex.quote(str(binary))+':"$PATH"\n')
        env = dict(os.environ, HOME=str(home), ZDOTDIR=str(home), TRANO_DATA_DIR=str(runtime), TRANO_TEST_FIXTURE=str(root), CLAUDE_CONFIG_DIR=str(home/'.claude'), CODEX_HOME=str(home/'.codex'))
        env['PYTHONPATH'] = str(pathlib.Path(orjson.__file__).resolve().parents[1])
        env['REX_BLOCK'] = 'wrong-parent-fixture'
        env.pop('TRANO_SESSION', None); env.pop('TRANO_LAUNCH_ID', None)

        def cli(*args):
            result = subprocess.run([str(CLI),*args],env=env,capture_output=True,timeout=20)
            self.assertEqual(result.returncode,0,result.stderr.decode())
            return orjson.loads(result.stdout)['result']

        def until(check):
            deadline = time.monotonic()+12
            while time.monotonic()<deadline:
                value = check()
                if value: return value
                time.sleep(.05)
            self.fail('Timed out; panes='+str([cli('capture',pane['id']) for pane in cli('list')]))

        def rows():
            file=root/'launches.jsonl'
            return [orjson.loads(line) for line in file.read_bytes().splitlines()] if file.exists() else []

        try:
            panes=[]
            account=cli('account','add','--provider','codex','--label','Recovery fixture')
            for index,provider in enumerate(['claude','codex','claude']):
                if index==1:
                    layout=cli('do','pane.split.right','--pane',panes[0]['id'])
                    pane=next(row for row in cli('list') if row['id']==layout['focusedPaneID'])
                else:
                    pane=cli('launch','--cwd',str(project))['pane']
                panes.append(pane)
                command=shlex.join([str(CLI),'account','exec',account['id']]) if provider=='codex' else provider
                cli('send',pane['id'],command,'--enter')
            initial=until(lambda: rows() if len(rows())==3 else None)
            self.assertTrue(all(row['generation'] for row in initial))
            self.assertTrue(all(row['foreignBlock'] is None for row in initial))
            self.assertEqual(len({row['session'] for row in initial}),3)
            self.assertEqual(len({row['generation'] for row in initial}),3)
            bindings={item['paneID']:item.get('providerSessionID') for item in cli('state')['agentLaunches']}
            self.assertEqual(bindings,{row['pane']:row['session'] for row in initial})
            (root/('exit-'+panes[2]['id'])).touch()
            until(lambda: next(row for row in cli('state')['agentLaunches'] if row['paneID']==panes[2]['id'])['lifecycle']=='exited')
            moved=root/'changed directory'
            moved.mkdir()
            cli('send',panes[2]['id'],'cd '+shlex.quote(str(moved)),'--enter')
            until(lambda: pathlib.Path(next(row for row in cli('state')['sessions'] if row['id']==panes[2]['id'])['cwd']).resolve()==moved.resolve())
            layout=cli('state')['layout']
            socket=cli('check')['socket']
            subprocess.run(['tmux','-S',socket,'kill-server'],check=True)
            until(lambda: not any(pane['alive'] for pane in cli('list')))
            app=CLI.parent/'TranoApp'
            native=subprocess.Popen([str(app),'--snapshot',str(root/'restored.png')],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
                list(pool.map(lambda _:cli('recovery','run'),range(3)))
            self.assertEqual(native.wait(timeout=15),0)
            restored=until(lambda: rows() if len(rows())==5 else None)
            self.assertEqual(cli('state')['layout'],layout)
            self.assertEqual(pathlib.Path(next(row for row in cli('state')['sessions'] if row['id']==panes[2]['id'])['cwd']).resolve(),moved.resolve())
            for pane in panes[:2]:
                events=[row for row in restored if row['pane']==pane['id']]
                self.assertEqual(len(events),2)
                self.assertEqual(events[0]['session'],events[1]['session'])
                self.assertEqual(events[0]['cwd'],events[1]['cwd'])
                self.assertEqual(events[0]['config'],events[1]['config'])
                self.assertNotEqual(events[0]['generation'],events[1]['generation'])
                self.assertIn('--resume' if events[0]['provider']=='claude' else 'resume',events[1]['args'])
            self.assertEqual(len([row for row in restored if row['pane']==panes[2]['id']]),1)
            cli('recovery','run')
            time.sleep(.2)
            self.assertEqual(len(rows()),5)
            statuses=cli('recovery','list')
            self.assertTrue(all(item['status']=='restored' for item in statuses),statuses)
            self.assertEqual((root/'startup').read_text().splitlines().count('.zshrc'),6)
            print('Verified: exact Claude/Codex IDs and cwd; unchanged pane/tab/split layout; exited agent excluded; concurrent and repeated recovery creates no duplicate agent.')
        finally:
            if runtime.exists():
                try:
                    for pane in cli('list'): cli('terminate',pane['id'])
                except Exception: pass
            shutil.rmtree(root)


if __name__ == '__main__':
    unittest.main()
