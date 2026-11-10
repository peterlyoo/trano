#!/usr/bin/env python3
import os
import pathlib
import shutil
import subprocess
import tempfile
import time
import unittest

import orjson

PROJECT = pathlib.Path(__file__).resolve().parents[1]
APP = PROJECT / 'build/Trano.app'
CLI = APP / 'Contents/MacOS/trano'
GUI = APP / 'Contents/MacOS/TranoApp'
SERVICE = APP / 'Contents/Helpers/Trano Service.app/Contents/MacOS/TranoApp'


class NativePersistence(unittest.TestCase):
    # Implements: FR-CORE-1, FR-ACTIVITY-1, FR-CORE-2
    def test_collector_and_api_survive_native_client_kill(self):
        root = tempfile.mkdtemp(prefix='at-native-', dir='/tmp')
        home = tempfile.mkdtemp(prefix='at-native-home-', dir='/tmp')
        env = dict(os.environ, TRANO_DATA_DIR=root, HOME=home, ZDOTDIR=home)
        service = gui = None

        def cli(*args):
            result = subprocess.run([str(CLI), *args], env=env, capture_output=True, timeout=10, check=True)
            return orjson.loads(result.stdout)['result']

        try:
            session = cli('create', '--title', 'Persistence test', '--cwd', root)
            cli('attach', session['id'])
            service = subprocess.Popen([str(SERVICE), '--service'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            for _ in range(50):
                if pathlib.Path(root, 'api.sock').exists():
                    break
                time.sleep(0.1)
            self.assertIsNone(service.poll(), service.stderr.read() if service.poll() is not None else b'')
            self.assertEqual(cli('api', 'server.info')['apiVersion'], 1)
            cli('send', session['id'], "printf '\\033]7501;state=working:app=codex\\007'; sleep 3; printf '\\033]7501;state=done:app=codex\\007'; printf '\\nNATIVE_PERSIST_OK\\n'", '--enter')
            gui = subprocess.Popen([str(GUI), '--snapshot', str(pathlib.Path(root, 'unused.png'))], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(0.5)
            gui.kill()
            gui.wait(timeout=5)
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                current = cli('list')[0]
                if current['activity']['state'] == 'done':
                    break
                time.sleep(0.1)
            self.assertEqual(current['activity']['state'], 'done', cli('capture', session['id'])['text'])
            self.assertEqual(current['activity']['source'], 'osc7501')
            self.assertEqual(current['pid'], session['pid'])
            self.assertTrue(current['alive'])
            self.assertIn('NATIVE_PERSIST_OK', cli('capture', session['id'])['text'])
            self.assertEqual(cli('api', 'activity.list')[0]['activity']['state'], 'done')
            self.assertIsNone(service.poll())
            print('Native client SIGKILL: same shell PID; detached completion collected; API remained available.')
        finally:
            if gui is not None and gui.poll() is None:
                gui.kill(); gui.wait(timeout=5)
            if service is not None and service.poll() is None:
                service.terminate(); service.wait(timeout=5)
            if service is not None:
                service.stderr.close()
            for session in cli('list'):
                cli('terminate', session['id'])
            shutil.rmtree(root)
            shutil.rmtree(home)


if __name__ == '__main__':
    unittest.main()
