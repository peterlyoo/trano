import os
from pathlib import Path
import pty
import select
import signal
import shutil
import subprocess
import tempfile
import time
import unittest


class PersistenceTests(unittest.TestCase):
    """Implements: U01, U02. Isolated real PTY/server experiments, not product qualification."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="trano-check-")
        self.socket = str(Path(self.temp.name) / "mux.sock")
        self.tmux = shutil.which("tmux")
        if not self.tmux:
            self.skipTest("tmux not installed")
        self.clients = []

    def run_tmux(self, *args):
        return subprocess.check_output([self.tmux, "-S", self.socket, *args], text=True).strip()

    def tearDown(self):
        for pid, fd in self.clients:
            try:
                os.kill(pid, signal.SIGTERM)
                os.waitpid(pid, 0)
            except (ProcessLookupError, ChildProcessError):
                pass
            os.close(fd)
        subprocess.run([self.tmux, "-S", self.socket, "kill-server"], capture_output=True)
        self.temp.cleanup()

    def attach(self):
        pid, fd = pty.fork()
        if pid == 0:
            os.environ["TERM"] = "xterm-256color"
            os.execv(self.tmux, [self.tmux, "-S", self.socket, "attach-session", "-t", "proof"])
        self.clients.append((pid, fd))
        return pid, fd

    def read_until(self, fd, marker, timeout=5):
        data = b""
        deadline = time.monotonic() + timeout
        while marker not in data and time.monotonic() < deadline:
            if select.select([fd], [], [], .1)[0]:
                data += os.read(fd, 65536)
        self.assertIn(marker, data)
        return data

    def test_ui_client_kill_preserves_shell_and_output_and_reconnect(self):
        self.run_tmux("-f", "/dev/null", "new-session", "-d", "-s", "proof", "-x", "100", "-y", "30", "/bin/zsh -f")
        self.run_tmux("set-option", "-t", "proof", "status", "off")
        before = self.run_tmux("display-message", "-p", "-t", "proof", "#{pane_pid}")
        pid, fd = self.attach()
        self.run_tmux("send-keys", "-t", "proof", "printf '\\033[32m한글 보존\\033[0m\\n'; sleep 1; printf 'DETACHED_COMPLETE\\n'", "Enter")
        self.read_until(fd, "한글 보존".encode())
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        time.sleep(1.2)
        after = self.run_tmux("display-message", "-p", "-t", "proof", "#{pane_pid}")
        self.assertEqual(before, after)
        screen = self.run_tmux("capture-pane", "-p", "-e", "-t", "proof")
        self.assertIn("DETACHED_COMPLETE", screen)
        self.assertIn("한글 보존", screen)
        _, fd2 = self.attach()
        self.read_until(fd2, "한글 보존".encode())
        os.write(fd2, b"printf 'REATTACHED_OK\\n'\r")
        self.read_until(fd2, b"REATTACHED_OK")
        print(f"PASS shell_pid={after}; SIGKILL client; detached output retained; PTY reattached")


if __name__ == "__main__":
    unittest.main(verbosity=2)
