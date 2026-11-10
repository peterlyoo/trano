#!/usr/bin/env python3
import os
import pathlib
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

import orjson

PROJECT = pathlib.Path(__file__).resolve().parents[1]
CLI = pathlib.Path(os.environ.get('TRANO_TEST_CLI', PROJECT / 'build/Trano.app/Contents/MacOS/trano'))
SSH_CONFIG = os.environ.get('TRANO_TEST_SSH_CONFIG', str(PROJECT / '.local/ssh-fixture/config'))


class RemoteCompletion(unittest.TestCase):
    # Implements: FR-REMOTE-INSTALL-1, FR-REMOTE-RECOVERY-1, FR-REMOTE-RECOVERY-3
    def test_install_update_and_automatic_recovery(self):
        root = pathlib.Path(tempfile.mkdtemp(prefix='trano-ssh-full-', dir='/tmp'))
        environment = dict(os.environ, TRANO_DATA_DIR=str(root))
        service = os.environ.get('TRANO_TEST_API_SERVER')
        command = [service, '--service'] if service else [str(CLI), 'serve']
        server = subprocess.Popen(command, env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        local_id = remote_id = host_id = None

        def api(method, **params):
            process = subprocess.run([str(CLI), 'api', method, orjson.dumps(params).decode()], env=environment, capture_output=True)
            self.assertEqual(process.returncode, 0, (method, process.stdout.decode(), process.stderr.decode()))
            response = orjson.loads(process.stdout)
            self.assertNotIn('error', response, response)
            return response['result']

        def ssh(command, data=None):
            return subprocess.check_output(['ssh', '-F', SSH_CONFIG, 'trano-test', command], input=data)

        def remote(method, **params):
            response = orjson.loads(ssh('exec "$HOME/.local/bin/trano-server" rpc', orjson.dumps({'apiVersion': 1, 'method': method, 'params': params}) + b'\n'))
            self.assertNotIn('error', response, response)
            return response['result']

        def wait_for(check):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if check():
                    return
                time.sleep(0.1)
            self.fail('Timed out waiting for remote state')

        try:
            wait_for(lambda: (root / 'api.sock').exists())
            host = api('remote.hosts.add', name='Owned Linux fixture', address='trano-test', sshConfigPath=SSH_CONFIG)
            host_id = host['id']
            status = api('remote.installation.check', hostID=host_id)
            self.assertIn(status['state'], ['missing', 'conflict', 'ready'])
            force = status['state'] == 'conflict'
            if force and os.environ.get('TRANO_TEST_INSTALL_REPLACE') != '1':
                self.fail('Use the owned SSH fixture and TRANO_TEST_INSTALL_REPLACE=1 for unmanaged helper replacement')
            installed = api('remote.installation.install', hostID=host_id, force=force)
            self.assertEqual(installed['state'], 'ready')
            pane = api('remote.sessions.create', hostID=host_id)
            local_id, remote_id = pane['id'], pane['remote']['sessionID']
            original = next(row for row in remote('sessions.list') if row['id'] == remote_id)
            api('remote.installation.install', hostID=host_id)
            updated = next(row for row in remote('sessions.list') if row['id'] == remote_id)
            self.assertEqual(updated['pid'], original['pid'])
            self.assertTrue(updated['alive'])

            api('recovery.settings', automaticRestore=False)
            ssh('tmux -S "$HOME/.local/share/trano-remote/mux.sock" kill-session -t ' + shlex.quote('=' + remote_id))
            wait_for(lambda: not next(row for row in api('sessions.list') if row['id'] == local_id)['alive'])
            api('remote.sync', hostID=host_id)
            self.assertFalse(next(row for row in remote('sessions.list') if row['id'] == remote_id)['alive'])
            api('recovery.settings', automaticRestore=True)
            layout = api('state.get')['layout']
            api('remote.sync', hostID=host_id)
            wait_for(lambda: next(row for row in api('sessions.list') if row['id'] == local_id)['alive'])
            restored = next(row for row in remote('sessions.list') if row['id'] == remote_id)
            self.assertTrue(restored['alive'])
            self.assertNotEqual(restored['pid'], original['pid'])
            self.assertEqual(api('state.get')['layout'], layout)
            results = api('remote.recovery.list', hostID=host_id)
            self.assertEqual(next(row for row in results if row['sessionID'] == remote_id)['status'], 'restored')
            bridge = next(row for row in api('sessions.list') if row['id'] == local_id)
            api('remote.sync', hostID=host_id)
            self.assertEqual(next(row for row in api('sessions.list') if row['id'] == local_id)['pid'], bridge['pid'])
            self.assertEqual(next(row for row in remote('sessions.list') if row['id'] == remote_id)['pid'], restored['pid'])

            api('remote.sessions.disconnect', id=local_id)
            local_id = None
            ssh('tmux -S "$HOME/.local/share/trano-remote/mux.sock" kill-session -t ' + shlex.quote('=' + remote_id))
            api('remote.sync', hostID=host_id)
            self.assertFalse(next(row for row in remote('sessions.list') if row['id'] == remote_id)['alive'])
            print('Real SSH: packaged helper install/check/update; live jobs survive update; restore setting respected; dead remote and local bridges recover automatically with stable IDs/layout; repeated sync preserves PIDs; explicitly disconnected views stay disconnected.')
        finally:
            if local_id:
                try:
                    api('remote.sessions.disconnect', id=local_id)
                except Exception:
                    pass
            if remote_id:
                try:
                    remote('sessions.terminate', id=remote_id)
                except Exception:
                    pass
            server.terminate()
            server.wait(timeout=5)
            server.stderr.close()
            subprocess.run(['tmux', '-S', str(root / 'mux.sock'), 'kill-server'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shutil.rmtree(root)


if __name__ == '__main__':
    unittest.main()
