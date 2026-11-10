#!/usr/bin/env python3
import os
import base64
import hashlib
import pathlib
import shutil
import shlex
import signal
import subprocess
import tempfile
import time
import unittest

import orjson

PROJECT = pathlib.Path(__file__).resolve().parents[1]
CLI = pathlib.Path(os.environ.get('TRANO_TEST_CLI', PROJECT / '.build/debug/trano'))
SSH_CONFIG = os.environ.get('TRANO_TEST_SSH_CONFIG', str(PROJECT / '.local/ssh-fixture/config'))


class RemoteSSH(unittest.TestCase):
    # Implements: FR-REMOTE-1, FR-REMOTE-2, FR-ACTIVITY-1
    def test_remote_job_and_activity_survive_ssh_bridge_kill(self):
        root = pathlib.Path(tempfile.mkdtemp(prefix='trano-ssh-', dir='/tmp'))
        environment = dict(os.environ, TRANO_DATA_DIR=str(root))
        server = subprocess.Popen([str(CLI), 'serve'], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

        def api(method, **params):
            output = subprocess.check_output([str(CLI), 'api', method, orjson.dumps(params).decode()], env=environment)
            response = orjson.loads(output)
            self.assertNotIn('error', response, response)
            return response['result']

        def remote(method, **params):
            request = orjson.dumps({'apiVersion': 1, 'method': method, 'params': params}) + b'\n'
            result = subprocess.check_output(['ssh', '-F', SSH_CONFIG, 'trano-test', 'exec "$HOME/.local/bin/trano-server" rpc'], input=request)
            response = orjson.loads(result)
            self.assertNotIn('error', response, response)
            return response['result']

        remote_id = local_id = None
        extra_ids = []
        try:
            deadline = time.monotonic() + 5
            while not (root / 'api.sock').exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            host = api('remote.hosts.add', name='Linux test', address='trano-test', sshConfigPath=SSH_CONFIG)
            pane = api('remote.sessions.create', hostID=host['id'])
            local_id, remote_id = pane['id'], pane['remote']['sessionID']
            original = next(row for row in remote('sessions.list') if row['id'] == remote_id)
            remote('panes.send', id=remote_id, text="sleep 1; printf '\\033]7501;state=done:app=codex\\007\\nREMOTE_DETACHED_OK\\n'", enter=True)
            os.kill(pane['pid'], signal.SIGKILL)
            deadline = time.monotonic() + 7
            while time.monotonic() < deadline:
                current = next(row for row in remote('sessions.list') if row['id'] == remote_id)
                if current['activity']['state'] == 'done': break
                time.sleep(0.1)
            self.assertEqual(current['activity']['state'], 'done')
            self.assertEqual(current['pid'], original['pid'])
            self.assertTrue(current['alive'])
            api('remote.sync', hostID=host['id'])
            self.assertEqual(next(row for row in api('sessions.list') if row['id'] == local_id)['activity']['state'], 'done')
            self.assertTrue(any(event['sessionID'] == local_id and event['activity']['state'] == 'done' for event in api('events.list')['events']))
            attached = api('remote.sessions.attach', hostID=host['id'], id=remote_id)
            self.assertEqual(attached['id'], local_id)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                text = api('panes.capture', id=local_id)['text']
                if 'REMOTE_DETACHED_OK' in text: break
                time.sleep(0.1)
            self.assertIn('REMOTE_DETACHED_OK', text)
            self.assertEqual(next(row for row in remote('sessions.list') if row['id'] == remote_id)['pid'], original['pid'])
            png = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a14kAAAAASUVORK5CYII=')
            source = root / 'test.png'
            source.write_bytes(png)
            uploaded = api('attachments.upload', id=local_id, path=str(source))['path']
            digest = subprocess.check_output(['ssh', '-F', SSH_CONFIG, 'trano-test', 'sha256sum -- ' + shlex.quote(uploaded)], text=True).split()[0]
            self.assertEqual(digest, hashlib.sha256(png).hexdigest())
            listing = api('remote.paths.list', hostID=host['id'], path=str(pathlib.PurePosixPath(uploaded).parent))
            self.assertTrue(any(entry['path'] == uploaded and not entry['directory'] for entry in listing['entries']))
            for action in ['client.tab.new', 'pane.split.right']:
                before = {row['id'] for row in api('sessions.list')}
                api('actions.perform', id=action, paneID=local_id)
                created = [row for row in api('sessions.list') if row['id'] not in before]
                self.assertEqual(len(created), 1)
                self.assertEqual(created[0]['remote']['hostID'], host['id'])
                extra_ids.append(created[0]['id'])
            layout = api('state.get')['layout']
            subprocess.run(['tmux', '-S', str(root / 'mux.sock'), 'kill-server'], check=True)
            api('recovery.run')
            self.assertEqual(api('state.get')['layout'], layout)
            self.assertEqual(next(row for row in remote('sessions.list') if row['id'] == remote_id)['pid'], original['pid'])
            api('remote.sessions.disconnect', id=local_id)
            local_id = None
            self.assertTrue(next(row for row in remote('sessions.list') if row['id'] == remote_id)['alive'])
            print('Real Linux SSH: durable PID and detached completion event; exact image upload; remote paths; new tabs/splits stay remote; local process-loss recovery preserves remote PID and layout.')
        finally:
            for pane_id in extra_ids:
                try: api('sessions.terminate', id=pane_id)
                except Exception: pass
            if local_id:
                try: api('remote.sessions.disconnect', id=local_id)
                except Exception: pass
            if remote_id:
                remote('sessions.terminate', id=remote_id)
            server.terminate()
            server.wait(timeout=5)
            server.stderr.close()
            shutil.rmtree(root)


if __name__ == '__main__':
    unittest.main()
