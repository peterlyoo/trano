#!/usr/bin/env python3
import os
import pathlib
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

import orjson


PROJECT = pathlib.Path(__file__).resolve().parents[1]
APP = pathlib.Path(os.environ.get('TRANO_TEST_APP', PROJECT / 'build/Trano.app'))
CLI = APP / 'Contents/MacOS/trano'
GUI = APP / 'Contents/MacOS/TranoApp'

PROBE = r'''
import os, pathlib, re, select, sys, termios, time, tty
import orjson

root = pathlib.Path(sys.argv[1])
config = orjson.loads((root / 'probe-config.json').read_bytes())
result = {'success': False, 'modeReports': []}
descriptor = os.open('/dev/tty', os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
previous = termios.tcgetattr(descriptor)

def write(data):
    while data:
        _, writable, _ = select.select([], [descriptor], [], 1)
        if not writable:
            raise TimeoutError('Owned probe tty was not writable')
        data = data[os.write(descriptor, data):]

def passthrough(data):
    write(b'\x1bPtmux;' + data.replace(b'\x1b', b'\x1b\x1b') + b'\x1b\\')

def response(pattern):
    collected = bytearray()
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        readable, _, _ = select.select([descriptor], [], [], .05)
        if readable:
            collected.extend(os.read(descriptor, 4096))
            if len(collected) > 16384:
                raise AssertionError('Owned probe response exceeded its limit')
            match = re.search(pattern, collected)
            if match:
                return match
    raise TimeoutError('No matching native terminal response through tmux')

try:
    tty.setraw(descriptor)
    (root / 'probe-ready').touch()
    write(('\r\n' + config['readyToken'] + '\r\n').encode())
    deadline = time.monotonic() + 20
    while not (root / 'probe-start').exists():
        if time.monotonic() > deadline:
            raise TimeoutError('Native attachment did not release the probe')
        time.sleep(.02)
    for label, control, expected in [
        ('supported', b'', 2),
        ('enabled', b'\x1b[?5522h', 1),
        ('reset', b'\x1b[?5522l', 2),
    ]:
        result['stage'] = label
        termios.tcflush(descriptor, termios.TCIFLUSH)
        passthrough(control + b'\x1b[?5522$p')
        state = int(response(rb'\x1b\[\?5522;([0-4])\$y').group(1))
        result['modeReports'].append(state)
        if state != expected:
            raise AssertionError(label + ': expected mode ' + str(expected) + ', received ' + str(state))
    result['stage'] = 'unsupported-primary'
    termios.tcflush(descriptor, termios.TCIFLUSH)
    identifier = b'trano_pty-primary'
    passthrough(b'\x1b]5522;type=read:loc=primary:id=' + identifier + b';Lg==\x1b\\')
    packet = response(rb'\x1b\]5522;([^\x1b]*)\x1b\\').group(1)
    metadata = packet.split(b';', 1)[0]
    fields = dict(item.split(b'=', 1) for item in metadata.split(b':') if b'=' in item)
    for key, value in [(b'type', b'read'), (b'status', b'ENOSYS'), (b'id', identifier)]:
        if fields.get(key) != value:
            raise AssertionError('Primary reply did not preserve expected ' + key.decode())
    result['unsupportedPrimary'] = True
    result['primaryRequestIDReturned'] = True
    result['success'] = True
except Exception as error:
    result['error'] = type(error).__name__ + ': ' + str(error)
finally:
    try:
        passthrough(b'\x1b[?5522l')
    finally:
        termios.tcsetattr(descriptor, termios.TCSANOW, previous)
        os.close(descriptor)
    (root / 'probe-result.json').write_bytes(orjson.dumps(result) + b'\n')
'''


class KittyNativePTY(unittest.TestCase):
    # Implements: FR-KITTY-1, FR-KITTY-3
    def test_signed_native_clipboard_protocol_round_trip_through_tmux(self):
        self.assertTrue(CLI.is_file(), 'Build the Trano app bundle before running this fixture.')
        self.assertTrue(GUI.is_file())
        signature = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(APP)],
                                   capture_output=True, timeout=20)
        self.assertEqual(signature.returncode, 0, signature.stderr.decode())
        root = pathlib.Path(tempfile.mkdtemp(prefix='trano-kitty-pty-', dir='/tmp'))
        home, runtime = root / 'home', root / 'runtime'
        home.mkdir()
        for folder in ['.claude', '.codex']:
            (home / folder).mkdir()
        env = {key: value for key, value in os.environ.items()
               if key in {'PATH', 'TMPDIR', 'LANG', 'LC_ALL', 'LC_CTYPE', '__CF_USER_TEXT_ENCODING'}}
        env.update(HOME=str(home), ZDOTDIR=str(home), TRANO_DATA_DIR=str(runtime),
                   CLAUDE_CONFIG_DIR=str(home / '.claude'), CODEX_HOME=str(home / '.codex'),
                   PYTHONPATH=str(pathlib.Path(orjson.__file__).resolve().parents[1]))
        token = 'TRANO_KITTY_READY_' + uuid.uuid4().hex
        (root / 'probe-config.json').write_bytes(orjson.dumps({'readyToken': token}) + b'\n')
        (root / 'probe.py').write_text(PROBE)
        gui = None
        socket = None
        tmux = None
        gui_log = None

        def cli(*args):
            completed = subprocess.run([str(CLI), *args], env=env, capture_output=True, timeout=15)
            self.assertEqual(completed.returncode, 0, completed.stderr.decode())
            payload = orjson.loads(completed.stdout)
            self.assertNotIn('error', payload, payload.get('error'))
            return payload['result']

        def until(path, timeout):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if path.exists():
                    return
                if gui is not None and gui.poll() is not None:
                    self.fail('The owned native probe exited before producing ' + path.name)
                time.sleep(.05)
            self.fail('Timed out waiting for ' + path.name)

        try:
            session = cli('create', '--title', 'Kitty protocol PTY fixture', '--cwd', str(root))
            cli('attach', session['id'])
            check = cli('check')
            socket = check['socket']
            tmux = check['tmux']
            self.assertTrue(pathlib.Path(socket).is_relative_to(runtime), 'Refusing a non-fixture tmux socket.')
            before = cli('state')['layout']
            command = shlex.join([sys.executable, str(root / 'probe.py'), str(root)])
            cli('send', session['id'], command, '--enter')
            until(root / 'probe-ready', 5)
            gui_log = (root / 'native.stderr').open('wb')
            gui = subprocess.Popen([str(GUI), '--benchmark-readiness', str(root / 'ready.json'),
                                    '--benchmark-token', token], env=env,
                                   stdout=subprocess.DEVNULL, stderr=gui_log)
            until(root / 'ready.json', 15)
            readiness = orjson.loads((root / 'ready.json').read_bytes())
            self.assertTrue(readiness.get('ready'), readiness)
            self.assertEqual(readiness.get('terminalViews'), 1)
            (root / 'probe-start').touch()
            until(root / 'probe-result.json', 25)
            result = orjson.loads((root / 'probe-result.json').read_bytes())
            self.assertTrue(result.get('success'), result)
            self.assertEqual(result['modeReports'], [2, 1, 2])
            self.assertTrue(result['unsupportedPrimary'])
            self.assertTrue(result['primaryRequestIDReturned'])
            current = cli('list')
            self.assertEqual(len(current), 1)
            self.assertEqual(current[0]['id'], session['id'])
            self.assertEqual(current[0]['pid'], session['pid'])
            self.assertTrue(current[0]['alive'])
            self.assertEqual(cli('state')['layout'], before)
            self.assertIsNone(gui.poll())
            info = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
            evidence = dict(result, buildID=info.get('TranoBuildID'), signedBundleVerified=True,
                            nativeTerminalAttached=True, transport='raw-pty-tmux-passthrough-native',
                            sameShellPID=True, sameLayout=True, standardClipboardAccessed=False,
                            physicalKeyboardAndClipboardUI='not_qualified')
            destination = os.environ.get('TRANO_KITTY_EVIDENCE')
            if destination:
                pathlib.Path(destination).write_bytes(orjson.dumps(evidence, option=orjson.OPT_INDENT_2) + b'\n')
            print('Native Kitty PTY: support/enable/reset reports 2/1/2; primary ENOSYS and request ID returned; shell PID/layout retained.')
        finally:
            if gui is not None and gui.poll() is None:
                gui.terminate()
                try:
                    gui.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    gui.kill()
                    gui.wait(timeout=5)
            if gui_log is not None:
                gui_log.close()
            try:
                if runtime.exists():
                    for session in cli('list'):
                        cli('terminate', session['id'])
            finally:
                try:
                    if socket is not None and tmux is not None and pathlib.Path(socket).is_relative_to(runtime):
                        subprocess.run([tmux, '-S', socket, 'kill-server'], env=env,
                                       capture_output=True, timeout=5)
                finally:
                    shutil.rmtree(root)


if __name__ == '__main__':
    unittest.main()
