#!/usr/bin/env python3
import os
import pathlib
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

import orjson

PROJECT = pathlib.Path(__file__).resolve().parents[1]
CLI = pathlib.Path(os.environ.get('TRANO_TEST_CLI', PROJECT / '.build/debug/trano'))


class AccountIsolation(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix='trano-accounts-', dir='/tmp'))
        self.env = dict(os.environ, TRANO_DATA_DIR=str(self.root / 'runtime'))
        self.env.pop('TRANO_SESSION', None)

    def tearDown(self):
        shutil.rmtree(self.root)

    def cli(self, *args):
        return orjson.loads(subprocess.check_output([str(CLI), *args], env=self.env))['result']

    # Implements: FR-ACCOUNT-1, FR-EXT-2
    def test_provider_argv_and_credentials_are_isolated(self):
        binary = self.root / 'bin'
        binary.mkdir()
        fake = '#!/usr/bin/env python3\nimport os, sys, orjson\nprint(orjson.dumps({"args":sys.argv[1:],"env":{k:v for k,v in os.environ.items() if k in ["CLAUDE_CONFIG_DIR","CODEX_HOME","ANTHROPIC_API_KEY","OPENAI_API_KEY","CLAUDE_CODE_OAUTH_TOKEN"]}}).decode())\n'
        for name in ['claude', 'codex']:
            target = binary / name
            target.write_text(fake)
            target.chmod(0o700)
        self.env.update(PATH=str(binary) + os.pathsep + self.env['PATH'], ANTHROPIC_API_KEY='test-only', OPENAI_API_KEY='test-only', CLAUDE_CODE_OAUTH_TOKEN='test-only')
        roots = []
        for provider in ['claude', 'claude', 'codex', 'codex']:
            account = self.cli('account', 'add', '--provider', provider, '--label', provider)
            output = subprocess.check_output([str(CLI), 'account', 'exec', account['id'], '--', '--help', '한글 ; $(literal)'], env=self.env)
            result = orjson.loads(output)
            self.assertEqual(result['args'][-2:], ['--help', '한글 ; $(literal)'])
            key = 'CLAUDE_CONFIG_DIR' if provider == 'claude' else 'CODEX_HOME'
            self.assertEqual(list(result['env']), [key])
            roots.append(result['env'][key])
        self.assertEqual(len(set(roots)), 4)

    # Implements: FR-ACCOUNT-1
    def test_interrupt_reaches_the_provider(self):
        binary = self.root / 'bin'
        binary.mkdir()
        ready, stopped = self.root / 'ready', self.root / 'stopped'
        fake = '#!/usr/bin/env python3\nimport os, pathlib, signal, sys, time\ndef stop(*_):\n pathlib.Path(os.environ["TRANO_TEST_STOPPED"]).write_text("interrupted")\n sys.exit(130)\nsignal.signal(signal.SIGINT, stop)\npathlib.Path(os.environ["TRANO_TEST_READY"]).write_text("ready")\nwhile True: time.sleep(0.05)\n'
        target = binary / 'codex'
        target.write_text(fake)
        target.chmod(0o700)
        self.env.update(PATH=str(binary) + os.pathsep + self.env['PATH'], TRANO_TEST_READY=str(ready), TRANO_TEST_STOPPED=str(stopped))
        account = self.cli('account', 'add', '--provider', 'codex', '--label', 'Interrupt')
        child = subprocess.Popen([str(CLI), 'account', 'exec', account['id']], env=self.env)
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and time.monotonic() < deadline: time.sleep(0.02)
            self.assertTrue(ready.exists())
            child.send_signal(signal.SIGINT)
            self.assertEqual(child.wait(timeout=5), 130)
            self.assertEqual(stopped.read_text(), 'interrupted')
        finally:
            if child.poll() is None: child.terminate(); child.wait(timeout=5)

    # Implements: FR-EXT-2
    def test_installed_codex_parses_generated_mcp_configuration(self):
        account = self.cli('account', 'add', '--provider', 'codex', '--label', 'Config check')
        spec = self.root / 'mcp.json'
        spec.write_bytes(orjson.dumps({'mcpServers': {'trano-test': {'command': '/usr/bin/false', 'args': [], 'env': {'EXAMPLE': '한글'}}}}))
        entry = self.cli('extension', 'import', '--kind', 'mcp', '--name', 'test', '--path', str(spec))
        plan = self.cli('extension', 'preview', account['id'], entry['id'])
        preview = self.root / 'preview.json'
        preview.write_bytes(orjson.dumps(plan))
        self.cli('extension', 'apply', str(preview))
        result = subprocess.run([str(CLI), 'account', 'exec', account['id'], '--', 'mcp', 'list', '--json'], env=self.env, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        entries = orjson.loads(result.stdout)
        self.assertTrue(any(item['name'] == 'trano-test' for item in entries), entries)


if __name__ == '__main__':
    unittest.main()
