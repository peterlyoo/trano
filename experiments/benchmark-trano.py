#!/usr/bin/env python3
"""Isolated native/backend benchmark. No provider credentials or user shell files are used."""
import argparse
import hashlib
import math
import os
import pathlib
import platform
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import uuid

import orjson

PROJECT = pathlib.Path(__file__).resolve().parents[1]


def distribution(values):
    ordered = sorted(values)
    return {"count": len(values), "median": statistics.median(values),
            "p95": ordered[max(0, math.ceil(len(values) * .95) - 1)], "max": max(values)}


def cpu_seconds(value):
    parts = value.split(":")
    if len(parts) == 2:
        return int(parts[0]) * 60 + float(parts[1])
    if len(parts) == 3:
        return int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])
    raise ValueError("Unexpected ps CPU duration")


def children(pid):
    result = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True, timeout=5)
    return {int(item) for item in result.stdout.split() if item.isdecimal()}


def descendants(pids):
    found = set(pids)
    pending = list(pids)
    while pending and len(found) < 256:
        for child in children(pending.pop()):
            if child not in found:
                found.add(child)
                pending.append(child)
    return found


class Fixture:
    def __init__(self, app):
        self.directory = pathlib.Path(tempfile.mkdtemp(prefix="trano-bench-", dir="/tmp"))
        self.root = self.directory / "runtime"
        self.home = self.directory / "home"
        self.home.mkdir(mode=0o700)
        (self.home / ".zshrc").write_text("PROMPT='%# '\nRPROMPT=\n", encoding="utf-8")
        self.root.mkdir(mode=0o700)
        self.app = app
        self.cli_path = app / "Contents/MacOS/trano"
        self.gui_path = app / "Contents/MacOS/TranoApp"
        self.service_path = app / "Contents/Helpers/Trano Service.app/Contents/MacOS/TranoApp"
        self.env = dict(os.environ, HOME=str(self.home), ZDOTDIR=str(self.home), TRANO_DATA_DIR=str(self.root))
        for name in ("REX_BLOCK", "REX_SERVER", "REX_SESSION", "TMUX", "TRANO_LAUNCH_ID", "TRANO_SESSION"):
            self.env.pop(name, None)
        self.service = None
        self.gui = None
        self.sessions = []
        self.tmux = shutil.which("tmux")

    def cli(self, *arguments):
        result = subprocess.run([str(self.cli_path), *arguments], env=self.env, capture_output=True, timeout=35, check=True)
        response = orjson.loads(result.stdout)
        if response.get("error"):
            raise RuntimeError(response["error"])
        return response["result"]

    def api(self, method, **params):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(15)
            connection.connect(str(self.root / "api.sock"))
            connection.sendall(orjson.dumps({"apiVersion": 1, "method": method, "params": params}) + b"\n")
            chunks = bytearray()
            while b"\n" not in chunks:
                part = connection.recv(65536)
                if not part:
                    raise RuntimeError("API closed before a complete response")
                chunks.extend(part)
                if len(chunks) > 1_048_577:
                    raise RuntimeError("API response exceeded 1 MiB")
            response = orjson.loads(chunks.split(b"\n", 1)[0])
            if response.get("error"):
                raise RuntimeError(response["error"])
            return response["result"]

    def start_service(self):
        self.service = subprocess.Popen([str(self.service_path), "--service"], env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if self.service.poll() is not None:
                raise RuntimeError("Native background service exited during startup")
            try:
                self.api("server.info")
                return
            except (OSError, RuntimeError):
                time.sleep(.01)
        raise TimeoutError("API service did not become ready")

    def create(self):
        session = self.api("sessions.create", title="Benchmark", cwd=str(self.home))
        self.sessions.append(session)
        return session

    def prepare_marker(self, session, marker=None):
        marker = marker or "TR" + uuid.uuid4().hex[:6]
        self.api("panes.send", id=session["id"], text="printf '\\033[2J\\033[999;1H%s\\n' '" + marker + "'", enter=True)
        deadline = time.monotonic() + 5
        while marker not in self.api("panes.capture", id=session["id"])["text"]:
            if time.monotonic() >= deadline:
                raise TimeoutError("Shell marker was not printed")
            time.sleep(.01)
        return marker

    def start_gui(self, marker):
        self.readiness_result = None
        output = self.directory / "ready.json"
        output.unlink(missing_ok=True)
        started = time.monotonic()
        self.gui = subprocess.Popen([str(self.gui_path), "--benchmark-readiness", str(output), "--benchmark-token", marker],
                                    env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        while not output.exists():
            if self.gui.poll() is not None:
                raise RuntimeError("Native renderer exited before readiness")
            if time.monotonic() - started > 35:
                raise TimeoutError("Native renderer readiness deadline exceeded")
            time.sleep(.002)
        elapsed = (time.monotonic() - started) * 1000
        result = orjson.loads(output.read_bytes())
        self.readiness_result = result
        if not result.get("ready"):
            raise RuntimeError(result.get("error", "Native renderer was not ready"))
        return elapsed, result

    def stop_gui(self):
        if self.gui is not None:
            self.stop(self.gui)
            self.gui = None

    @staticmethod
    def stop(process):
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

    def product_pids(self):
        server = subprocess.check_output([self.tmux, "-S", str(self.root / "mux.sock"), "display-message", "-p", "#{pid}"], env=self.env, timeout=5)
        roots = {int(server.strip())}
        roots.update(process.pid for process in (self.service, self.gui) if process is not None and process.poll() is None)
        excluded = descendants({item["pid"] for item in self.sessions})
        return descendants(roots) - excluded

    def resources(self, pids):
        output = subprocess.check_output(["ps", "-p", ",".join(map(str, sorted(pids))), "-o", "pid=,rss=,time="], text=True, timeout=5)
        rows = {}
        for line in output.splitlines():
            pid, rss, cpu = line.split()
            rows[int(pid)] = {"rss_mib": int(rss) / 1024, "cpu_seconds": cpu_seconds(cpu)}
        return {"at": time.monotonic(), "processes": rows, "rss_mib": sum(row["rss_mib"] for row in rows.values())}

    def close(self):
        self.stop_gui()
        if self.service is not None:
            self.stop(self.service)
        if self.tmux:
            subprocess.run([self.tmux, "-S", str(self.root / "mux.sock"), "kill-server"], env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
        for attempt in range(20):
            try:
                shutil.rmtree(self.directory)
                break
            except OSError:
                if attempt == 19:
                    raise
                time.sleep(.1)


def sample_resources(fixture, seconds, interval, samples=None):
    pids = fixture.product_pids()
    if samples is None:
        samples = []
    samples.append(fixture.resources(pids))
    deadline = samples[0]["at"] + seconds
    while time.monotonic() < deadline:
        time.sleep(min(interval, max(0, deadline - time.monotonic())))
        samples.append(fixture.resources(pids))
    first, last = samples[0], samples[-1]
    common = first["processes"].keys() & last["processes"].keys()
    cpu = sum(max(0, last["processes"][pid]["cpu_seconds"] - first["processes"][pid]["cpu_seconds"]) for pid in common)
    return {"duration_seconds": last["at"] - first["at"], "sample_count": len(samples),
            "resident_process_cpu_core_percent": cpu / (last["at"] - first["at"]) * 100,
            "rss_mib": distribution([sample["rss_mib"] for sample in samples]),
            "rss_growth_mib": last["rss_mib"] - first["rss_mib"], "observed_product_processes": len(last["processes"]), "samples": samples}


def roundtrip(fixture, session, scrollback=False):
    marker = "TA" + uuid.uuid4().hex[:6]
    encoded = "".join("\\x%02x" % byte for byte in ("\n" + marker + "\n").encode())
    start = time.monotonic()
    fixture.api("panes.send", id=session["id"], text="printf '" + encoded + "'", enter=True)
    def capture():
        if scrollback:
            return subprocess.check_output([fixture.tmux, "-S", str(fixture.root / "mux.sock"), "capture-pane", "-p", "-t", session["id"] + ":0.0", "-S", "-10000"], timeout=5).decode("utf-8", errors="replace")
        return fixture.api("panes.capture", id=session["id"])["text"]
    while True:
        text = capture()
        elapsed = time.monotonic() - start
        if elapsed > 10:
            raise TimeoutError("Input/output roundtrip exceeded 10 seconds")
        if marker in text:
            return elapsed * 1000
        time.sleep(.001)


def write_report(path, report):
    data = orjson.dumps(report, option=orjson.OPT_INDENT_2 | orjson.OPT_SORT_KEYS | orjson.OPT_NON_STR_KEYS) + b"\n"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def create_native_panes(fixture, count):
    start = time.monotonic()
    first = fixture.create()
    fixture.api("sessions.attach", id=first["id"])
    latencies = [(time.monotonic() - start) * 1000]
    pending = [(first["id"], 0)]
    for _ in range(count - 1):
        target, depth = pending.pop(0)
        previous = {item["id"] for item in fixture.sessions}
        start = time.monotonic()
        fixture.api("actions.perform", id="pane.split.right" if depth % 2 == 0 else "pane.split.down", paneID=target, cwd=str(fixture.home))
        added = [item for item in fixture.api("sessions.list") if item["id"] not in previous]
        if len(added) != 1:
            raise RuntimeError("Split did not create exactly one owned session")
        fixture.sessions.append(added[0])
        latencies.append((time.monotonic() - start) * 1000)
        pending.extend([(target, depth + 1), (added[0]["id"], depth + 1)])
    layout = fixture.api("state.get")["layout"]
    selected = next((tab for tab in layout["tabs"] if tab["id"] == layout["selectedTabID"]), None)
    expected = {item["id"] for item in fixture.sessions}
    if len(layout["tabs"]) != 1 or selected is None or len(selected["panes"]) != count or set(selected["panes"]) != expected:
        raise RuntimeError("Expected all benchmark panes in one selected tab")
    return latencies, layout


def viewport_sizes(fixture):
    return subprocess.check_output([fixture.tmux, "-S", str(fixture.root / "mux.sock"), "list-panes", "-a", "-F", "#{session_name}|#{pane_width}|#{pane_height}"], env=fixture.env, text=True, timeout=5).splitlines()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=pathlib.Path, default=PROJECT / "build/Trano.app")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--rounds", type=int, default=30)
    parser.add_argument("--panes", type=int, default=10)
    parser.add_argument("--idle-seconds", type=float, default=60)
    parser.add_argument("--load-seconds", type=float, default=600)
    parser.add_argument("--legacy-baseline", action="store_true", help="Measure backend only; old bundles have no native readiness probe.")
    args = parser.parse_args()
    if not (1 <= args.rounds <= 100 and 1 <= args.panes <= 30 and 1 <= args.idle_seconds <= 600 and 1 <= args.load_seconds <= 1800):
        parser.error("Use 1–100 rounds, 1–30 panes, 1–600 idle seconds, and 1–1800 load seconds.")
    app = args.app.resolve()
    private = pathlib.Path(tempfile.mkdtemp(prefix="trano-bench-app-", dir="/tmp"))
    fixture = None
    report = {"schema_version": 1, "status": "running", "machine": {"os": platform.mac_ver()[0], "architecture": platform.machine(), "logical_cpus": os.cpu_count()},
              "configuration": {"rounds": args.rounds, "panes": args.panes, "idle_seconds": args.idle_seconds, "load_seconds": args.load_seconds, "output_producer_panes": 1},
              "scope": "backend_only" if args.legacy_baseline else "native_headless_renderer_and_backend",
              "limitations": ["Native readiness includes headless drawing, not macOS presentation or physical keyboard latency.",
                              "CPU covers resident owned product processes; short-lived helpers between samples are not included.",
                              "Shells and workload processes are excluded. RSS is the sum of resident process RSS, including shared pages.",
                              "Process launches use warm filesystem caches; no privileged cache purge is performed."]}
    report["machine"]["cpu"] = subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True, timeout=5).strip()
    report["machine"]["memory_gib"] = int(subprocess.check_output(["sysctl", "-n", "hw.memsize"], timeout=5)) / 1024 ** 3
    report["machine"]["load_average_at_start"] = list(os.getloadavg())
    report["limitations"].append("Host background load is not controlled; concurrent work may affect wall-clock latency.")
    try:
        staged = private / "Trano.app"
        subprocess.run(["ditto", str(app), str(staged)], check=True, timeout=90)
        report["binary_sha256"] = hashlib.sha256((staged / "Contents/MacOS/TranoApp").read_bytes()).hexdigest()
        fixture = Fixture(staged)
        fixture.start_service()
        if args.legacy_baseline:
            latencies = []
            for _ in range(args.panes):
                start = time.monotonic(); fixture.create(); latencies.append((time.monotonic() - start) * 1000)
        else:
            latencies, report["layout"] = create_native_panes(fixture, args.panes)
            report["limitations"].append("create_ms includes layout-split transactions after the first session.")
        report["create_ms"] = distribution(latencies)
        session = fixture.sessions[0]
        fixture.api("sessions.attach", id=session["id"])
        marker = fixture.prepare_marker(session)
        if not args.legacy_baseline:
            for item in fixture.sessions[1:]:
                fixture.prepare_marker(item, marker)
            timings = []
            draws = []
            report["native_readiness_details"] = []
            for index in range(args.rounds):
                elapsed, detail = fixture.start_gui(marker)
                if not detail.get("ready") or detail.get("terminalViews") != args.panes:
                    raise RuntimeError("Native readiness did not contain exactly the configured visible pane count")
                report["configuration"]["visible_native_panes"] = detail["terminalViews"]
                report["native_readiness_details"].append(detail)
                timings.append(elapsed); draws.append(detail["drawSeconds"] * 1000)
                report["native_launch_to_ready_ms"] = distribution(timings)
                report["native_initial_draw_ms"] = distribution(draws)
                write_report(args.output, report)
                print("native readiness round", index + 1, "terminalViews", detail["terminalViews"], flush=True)
                if index + 1 < args.rounds:
                    fixture.stop_gui()
            report["native_viewport_sizes"] = viewport_sizes(fixture)
        write_report(args.output, report)
        print("startup measured; sampling idle", flush=True)
        for method, params in [("sessions.list", {}), ("panes.capture", {"id": session["id"]})]:
            values = []
            for _ in range(args.rounds):
                start = time.monotonic(); fixture.api(method, **params); values.append((time.monotonic() - start) * 1000)
            report[method + "_ms"] = distribution(values)
        idle_samples = []
        report["idle"] = {"status": "sampling", "samples": idle_samples}
        report["idle"] = sample_resources(fixture, args.idle_seconds, 1, samples=idle_samples)
        write_report(args.output, report)
        report["idle_api_to_capture_ms"] = distribution([roundtrip(fixture, session) for _ in range(args.rounds)])
        producer = fixture.home / "output.py"
        # Successful roundtrips have a strict ten-second deadline before the full output sample.
        producer.write_text("import os, time\nend=time.monotonic()+" + repr(args.load_seconds + args.rounds * 10 + 30) + "\nblock=('\\033[38;2;133;215;193m한글 terminal output 0123456789\\033[0m\\n'*128).encode()\nwhile time.monotonic()<end:\n os.write(1,block)\n time.sleep(.01)\n", encoding="utf-8")
        fixture.api("panes.send", id=session["id"], text="'" + sys.executable.replace("'", "'\\''") + "' '" + str(producer) + "' &", enter=True)
        print("idle measured; sampling sustained output", flush=True)
        report["load_api_to_scrollback_ms"] = distribution([roundtrip(fixture, session, scrollback=True) for _ in range(args.rounds)])
        output_samples = []
        report["output_load"] = {"status": "sampling", "samples": output_samples}
        write_report(args.output, report)
        report["output_load"] = sample_resources(fixture, args.load_seconds, min(5, args.load_seconds), samples=output_samples)
        report["machine"]["load_average_at_end"] = list(os.getloadavg())
        report["status"] = "measured"
    except BaseException as error:
        report["status"] = "interrupted" if isinstance(error, KeyboardInterrupt) else "failed"
        report["error"] = type(error).__name__ + ": " + str(error)
        report["native_readiness_failure"] = getattr(fixture, "readiness_result", None)
        if fixture is not None and not isinstance(error, KeyboardInterrupt):
            try:
                report["owned_failure_capture_tails"] = {item["id"]: fixture.api("panes.capture", id=item["id"])["text"][-160:] for item in fixture.sessions}
                report["owned_failure_viewport_sizes"] = viewport_sizes(fixture)
            except Exception as diagnostic_error:
                report["diagnostic_error"] = type(diagnostic_error).__name__ + ": " + str(diagnostic_error)
        raise
    finally:
        had_failure = sys.exc_info()[0] is not None
        try:
            if fixture is not None:
                fixture.close()
        except Exception as error:
            report["cleanup_error"] = type(error).__name__ + ": " + str(error)
            report["status"] = "failed"
        try:
            shutil.rmtree(private)
        except Exception as error:
            report["cleanup_error"] = report.get("cleanup_error", "") + " " + type(error).__name__ + ": " + str(error)
            report["status"] = "failed"
        write_report(args.output, report)
        if report.get("cleanup_error") and not had_failure:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
