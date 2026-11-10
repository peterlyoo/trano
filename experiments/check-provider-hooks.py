#!/usr/bin/env python3
import os
import pathlib
import selectors
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest

import orjson

PROJECT = pathlib.Path(__file__).resolve().parents[1]
CLI = pathlib.Path(os.environ.get('TRANO_TEST_CLI', PROJECT / '.build/debug/trano'))


class ProviderHooks(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix='trano-hooks-', dir='/tmp')).resolve()
        self.home = self.root / 'home'
        self.home.mkdir()
        self.cli_path = self.root / 'trano'
        shutil.copy2(CLI, self.cli_path)
        self.env = dict(os.environ, HOME=str(self.home), TRANO_DATA_DIR=str(self.root / 'runtime'))
        for name in ['TRANO_SESSION', 'TRANO_LAUNCH_ID', 'CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'CODEX_SQLITE_HOME',
                     'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CLAUDE_CODE_OAUTH_TOKEN', 'CLAUDE_SECURESTORAGE_CONFIG_DIR',
                     'ANTHROPIC_BASE_URL', 'CLAUDE_CODE_USE_BEDROCK', 'CLAUDE_CODE_USE_VERTEX', 'CLAUDE_CODE_USE_FOUNDRY',
                     'OPENAI_API_KEY', 'CODEX_API_KEY', 'CODEX_ACCESS_TOKEN', 'OPENAI_BASE_URL']:
            self.env.pop(name, None)

    def tearDown(self):
        shutil.rmtree(self.root)

    def cli(self, *args):
        result = subprocess.run([str(self.cli_path), *args], env=self.env, cwd=self.root, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return orjson.loads(result.stdout)['result']

    # Implements: FR-ACCOUNT-1, FR-EXT-2, FR-RECOVERY-1
    def test_installed_claude_parses_managed_hooks_and_resumes_exact_id_without_auth(self):
        account = self.cli('account', 'add', '--provider', 'claude', '--label', 'Isolated Claude')
        profile = self.root / 'runtime/accounts' / account['id']
        marker = self.root / 'session-start.json'
        spec = self.root / 'observer.json'
        spec.write_bytes(orjson.dumps({'hooks': {'SessionStart': [{'hooks': [{'type': 'command', 'command': 'cat > ' + shlex.quote(str(marker))}]}]}}))
        entry = self.cli('extension', 'import', '--kind', 'hook', '--name', 'fixture-observer', '--path', str(spec))
        preview = self.root / 'preview.json'
        preview.write_bytes(orjson.dumps(self.cli('extension', 'preview', account['id'], entry['id'])))
        self.cli('extension', 'apply', str(preview))
        env = dict(self.env, CLAUDE_CONFIG_DIR=str(profile))
        status = subprocess.run(['claude', 'auth', 'status', '--json'], env=env, cwd=self.root, capture_output=True, timeout=10)
        self.assertEqual(status.returncode, 1)
        self.assertFalse(orjson.loads(status.stdout)['loggedIn'])
        env['ANTHROPIC_BASE_URL'] = 'http://127.0.0.1:1'
        command = ['claude', '--mcp-config', str(profile / 'trano-mcp.json'), '--settings', str(profile / 'trano-settings.json')]
        first = subprocess.run(command + ['--print', 'Synthetic local hook fixture'], env=env, cwd=self.root, capture_output=True, timeout=15)
        self.assertNotEqual(first.returncode, 0)
        self.assertTrue(marker.exists(), first.stderr.decode())
        start = orjson.loads(marker.read_bytes())
        self.assertEqual(start['hook_event_name'], 'SessionStart')
        self.assertEqual(start['source'], 'startup')
        marker.unlink()
        resumed = subprocess.run(command + ['--resume', start['session_id'], '--print', 'Synthetic local resume fixture'], env=env, cwd=self.root, capture_output=True, timeout=15)
        self.assertNotEqual(resumed.returncode, 0)
        self.assertTrue(marker.exists(), resumed.stderr.decode())
        resume = orjson.loads(marker.read_bytes())
        self.assertEqual(resume['source'], 'resume')
        self.assertEqual(resume['session_id'], start['session_id'])
        print('Installed Claude: generated hook configuration executed SessionStart; exact resume ID preserved; empty auth and loopback-only inference endpoint.')

    # Implements: FR-EXT-2, FR-RECOVERY-1
    def test_installed_codex_reports_untrusted_hook_without_silently_approving_it(self):
        profile = self.root / 'codex'
        profile.mkdir()
        marker = self.root / 'codex-marker'
        command = 'cat > ' + shlex.quote(str(marker))
        (profile / 'config.toml').write_text('features = { hooks = true }\nhooks = { SessionStart = [{ hooks = [{ type = "command", command = ' + orjson.dumps(command).decode() + ', timeout = 3 }] }] }\n')
        env = dict(self.env, CODEX_HOME=str(profile))
        process = subprocess.Popen(['codex', 'app-server', '--stdio'], env=env, cwd=self.root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        pending = bytearray()
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)

        def call(method, params, identifier):
            process.stdin.write(orjson.dumps({'id': identifier, 'method': method, 'params': params}) + b'\n')
            process.stdin.flush()
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline:
                while b'\n' in pending:
                    line, _, remainder = pending.partition(b'\n')
                    pending[:] = remainder
                    response = orjson.loads(line)
                    if response.get('id') == identifier:
                        self.assertNotIn('error', response)
                        return response['result']
                if selector.select(.1):
                    data = os.read(process.stdout.fileno(), 16384)
                    if not data:
                        self.fail('Codex closed the fixture connection')
                    pending.extend(data)
                    self.assertLessEqual(len(pending), 1_048_576)
            self.fail('Codex fixture request timed out: ' + method)

        try:
            call('initialize', {'clientInfo': {'name': 'trano_fixture', 'version': '0.1.0'}}, 1)
            process.stdin.write(b'{"method":"initialized"}\n')
            process.stdin.flush()
            result = call('hooks/list', {'cwds': [str(self.root)]}, 2)
            hooks = [hook for entry in result['data'] for hook in entry['hooks'] if hook['eventName'] == 'sessionStart']
            self.assertEqual(len(hooks), 1)
            self.assertTrue(hooks[0]['enabled'])
            self.assertEqual(hooks[0]['trustStatus'], 'untrusted')
            self.assertFalse(marker.exists())
            print('Installed Codex: native hooks/list parsed SessionStart and reported untrusted; no trust bypass, credentials, or model request.')
        finally:
            selector.close()
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)
            process.stdin.close()
            process.stdout.close()


if __name__ == '__main__':
    unittest.main()
