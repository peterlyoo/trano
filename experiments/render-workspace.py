#!/usr/bin/env python3
import os
import pathlib
import shutil
import subprocess
import tempfile
import time

import orjson

project = pathlib.Path(__file__).resolve().parents[1]
bundle = project / 'build/Trano.app/Contents/MacOS'
root = pathlib.Path(tempfile.mkdtemp(prefix='trano-preview-', dir='/tmp'))
print(root, flush=True)
workspace = root / 'trano'
workspace.mkdir()
runtime = root / 'runtime'
environment = dict(os.environ, TRANO_DATA_DIR=str(runtime), ZDOTDIR=str(root), HOME=str(root))
environment['GOCACHE'] = subprocess.check_output(['go', 'env', 'GOCACHE'], text=True).strip()
shutil.copytree(project / 'remote', workspace / 'remote', ignore=shutil.ignore_patterns('.DS_Store'))
subprocess.run(['go', 'test', './...'], cwd=workspace / 'remote', env=environment,
               stdout=(workspace / 'verification.txt').open('w'), stderr=subprocess.STDOUT, check=True)


def cli(*arguments):
    output = subprocess.check_output([str(bundle / 'trano'), *arguments], env=environment)
    return orjson.loads(output)['result']


def send(pane, text):
    cli('send', pane, text, '--enter')


try:
    first = cli('launch', '--cwd', str(workspace))
    cli('do', 'pane.split.right')
    second = cli('state')['layout']['focusedPaneID']
    for pane in [first['pane']['id'], second]:
        send(pane, "PS1='%F{#85D7C1}trano%f %F{#717179}›%f '; RPS1=; clear")
    time.sleep(0.4)
    send(first['pane']['id'], 'zsh --version')
    send(first['pane']['id'], "printf '\\n한글 · 터미널 · 경로 삽입\\n\\n'")
    send(first['pane']['id'], "for n in {0..7}; do printf '\\033[48;5;%sm  ' $n; done; printf '\\033[0m\\n'")
    send(second, 'cat verification.txt')
    send(second, 'ls remote')
    cli('do', 'client.tab.new')
    cli('do', 'client.tab.previous')
    time.sleep(0.5)
    destination = project / 'design/native-workspace.png'
    destination.parent.mkdir(exist_ok=True)
    subprocess.run([str(bundle / 'TranoApp'), '--snapshot', str(destination)], env=environment, timeout=20, check=True)
    print(destination)
finally:
    for pane in cli('list'):
        cli('terminate', pane['id'])
    shutil.rmtree(root)
