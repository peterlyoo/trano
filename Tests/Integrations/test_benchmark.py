import contextlib
import importlib.util
import io
import pathlib
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

import orjson

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('trano_benchmark', ROOT / 'experiments/benchmark-trano.py')
BENCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BENCH)
REAL_FIXTURE = BENCH.Fixture


class FakeFixture:
    def __init__(self, directory, readiness=None, cleanup_error=False):
        self.directory = directory
        self.home = directory / 'home'
        self.root = directory / 'runtime'
        self.home.mkdir(parents=True)
        self.root.mkdir()
        self.env = {}
        self.tmux = 'owned-test-tmux'
        self.sessions = []
        self.backend_sessions = []
        self.tabs = []
        self.depths = {}
        self.split_calls = []
        self.methods = []
        self.output_panes = []
        self.markers = []
        self.readiness = readiness
        self.gui_rounds = 0
        self.cleanup_error = cleanup_error
        self.closed = False
        self.readiness_result = None
        self.interrupted = False
        self.post_interrupt_calls = []

    def start_service(self):
        pass

    def new_session(self):
        session = {'id': 'pane-' + str(len(self.backend_sessions)), 'pid': 300 + len(self.backend_sessions)}
        self.backend_sessions.append(session)
        return session

    def create(self):
        session = self.new_session()
        self.sessions.append(session)
        return session

    def api(self, method, **params):
        self.methods.append(method)
        if self.interrupted:
            self.post_interrupt_calls.append(method)
        if method == 'sessions.attach':
            if not self.tabs:
                self.tabs = [{'id': 'tab', 'panes': [params['id']]}]
                self.depths[params['id']] = 0
        elif method == 'actions.perform':
            target = params['paneID']
            depth = self.depths[target]
            added = self.new_session()
            self.tabs[0]['panes'].append(added['id'])
            self.depths[target] = self.depths[added['id']] = depth + 1
            self.split_calls.append((target, depth, params['id']))
        elif method == 'sessions.list':
            return list(self.backend_sessions)
        elif method == 'state.get':
            return {'layout': {'selectedTabID': 'tab', 'tabs': self.tabs}}
        elif method == 'panes.capture':
            return {'text': 'owned diagnostic output\n' * 20}
        elif method == 'panes.send':
            self.output_panes.append(params['id'])
        else:
            raise AssertionError('Unexpected API method: ' + method)
        return {'ok': True}

    def prepare_marker(self, session, marker=None):
        marker = marker or 'TR123456'
        self.markers.append((session['id'], marker))
        return marker

    def start_gui(self, marker):
        detail = dict(self.readiness[self.gui_rounds]) if self.readiness else {
            'ready': True, 'terminalViews': len(self.tabs[0]['panes']), 'drawSeconds': .001, 'pid': 100}
        self.gui_rounds += 1
        self.readiness_result = detail
        return 12, detail

    def stop_gui(self):
        pass

    def close(self):
        self.closed = True
        if self.cleanup_error:
            raise RuntimeError('cleanup failed')


class BenchmarkTests(unittest.TestCase):
    def run_main(self, legacy=False, readiness=None, sample_error=False, cleanup_error=False, integer_keys=False):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            app = root / 'Input.app'
            binary = app / 'Contents/MacOS/TranoApp'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'owned test binary')
            output = root / 'report.json'
            fixture = FakeFixture(root / 'fixture', readiness, cleanup_error)
            checkpoints = []

            def run(arguments, **kwargs):
                self.assertEqual(arguments[0], 'ditto')
                BENCH.shutil.copytree(arguments[1], arguments[2])
                return subprocess.CompletedProcess(arguments, 0)

            def check_output(arguments, **kwargs):
                if arguments[:2] == ['sysctl', '-n']:
                    return 'Test CPU' if kwargs.get('text') else b'1024'
                self.assertEqual(arguments[:3], [fixture.tmux, '-S', str(fixture.root / 'mux.sock')])
                if fixture.interrupted:
                    fixture.post_interrupt_calls.append('viewport_sizes')
                return '\n'.join(item['id'] + '|27|7' for item in fixture.sessions)

            def samples(actual_fixture, seconds, interval, **kwargs):
                self.assertIs(actual_fixture, fixture)
                checkpoints.append(orjson.loads(output.read_bytes()) if output.exists() else None)
                rows = [{'at': 1, 'rss_mib': 2, 'processes': {123 if integer_keys else '123': {'rss_mib': 2, 'cpu_seconds': 0}}}]
                if 'samples' in kwargs:
                    kwargs['samples'].extend(rows)
                if sample_error and len(checkpoints) == 2:
                    fixture.interrupted = isinstance(sample_error, KeyboardInterrupt)
                    raise sample_error if isinstance(sample_error, BaseException) else RuntimeError('output sampler failed')
                return {'duration_seconds': seconds, 'sample_count': 1, 'rss_mib': {'count': 1, 'median': 2, 'p95': 2, 'max': 2}, 'rss_growth_mib': 0, 'resident_process_cpu_core_percent': 0, 'observed_product_processes': 1, 'samples': rows}

            argv = ['benchmark-trano.py', '--app', str(app), '--output', str(output), '--rounds', '2', '--panes', '10', '--idle-seconds', '1', '--load-seconds', '1']
            if legacy:
                argv.append('--legacy-baseline')
            error = None
            with mock.patch.object(sys, 'argv', argv), mock.patch.object(BENCH, 'Fixture', return_value=fixture), mock.patch.object(BENCH.subprocess, 'run', side_effect=run), mock.patch.object(BENCH.subprocess, 'check_output', side_effect=check_output), mock.patch.object(BENCH, 'sample_resources', side_effect=samples), mock.patch.object(BENCH, 'roundtrip', return_value=1), contextlib.redirect_stdout(io.StringIO()):
                try:
                    BENCH.main()
                except BaseException as caught:
                    error = caught
            report = orjson.loads(output.read_bytes()) if output.exists() else None
            producer = (fixture.home / 'output.py').read_text() if (fixture.home / 'output.py').exists() else None
            return fixture, report, checkpoints, producer, error

    def test_native_setup_renders_one_balanced_tab_of_ten_panes(self):
        fixture, report, _, _, error = self.run_main()
        self.assertIsNone(error)
        self.assertEqual(len(fixture.tabs), 1)
        self.assertEqual(len(fixture.tabs[0]['panes']), 10)
        self.assertEqual(set(fixture.depths.values()), {3, 4})
        self.assertEqual(len(fixture.split_calls), 9)
        self.assertEqual(report['configuration'].get('visible_native_panes'), 10)
        self.assertEqual([item['terminalViews'] for item in report['native_readiness_details']], [10, 10])

    def test_all_visible_panes_receive_the_same_readiness_marker(self):
        fixture, _, _, _, error = self.run_main()
        self.assertIsNone(error)
        self.assertEqual(len(fixture.markers), 10)
        self.assertEqual(len({marker for _, marker in fixture.markers}), 1)
        self.assertEqual({pane for pane, _ in fixture.markers}, {item['id'] for item in fixture.sessions})

    def test_later_round_pane_count_mismatch_fails_and_retains_prior_round(self):
        first = {'ready': True, 'terminalViews': 10, 'drawSeconds': .001, 'pid': 100}
        second = {'ready': True, 'terminalViews': 1, 'drawSeconds': .001, 'pid': 101}
        fixture, report, _, _, error = self.run_main(readiness=[first, second])
        self.assertIsInstance(error, RuntimeError)
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(report['native_readiness_details'], [first])
        self.assertEqual(report['native_readiness_failure'], second)
        self.assertTrue(fixture.closed)
        self.assertTrue(all(len(text) <= 160 for text in report['owned_failure_capture_tails'].values()))

    def test_backend_only_mode_requires_no_layout_splits_or_native_readiness(self):
        fixture, report, _, _, error = self.run_main(legacy=True)
        self.assertIsNone(error)
        self.assertEqual(fixture.split_calls, [])
        self.assertEqual(fixture.gui_rounds, 0)
        self.assertNotIn('state.get', fixture.methods)
        self.assertNotIn('visible_native_panes', report['configuration'])
        self.assertNotIn('native_readiness_details', report)
        self.assertEqual(report['scope'], 'backend_only')

    def test_raw_integer_pid_samples_serialize_as_json_object_keys(self):
        _, report, _, _, error = self.run_main(integer_keys=True)
        self.assertIsNone(error)
        self.assertEqual(report['idle']['samples'][0]['processes']['123']['rss_mib'], 2)

    def test_startup_and_idle_checkpoints_exist_before_later_sampling(self):
        _, report, checkpoints, _, error = self.run_main(sample_error=True)
        self.assertIsInstance(error, RuntimeError)
        self.assertIsNotNone(checkpoints[0])
        self.assertEqual(len(checkpoints[0]['native_readiness_details']), 2)
        self.assertIn('idle', checkpoints[1])
        self.assertEqual(report['output_load']['samples'][0]['rss_mib'], 2)
        self.assertEqual(report['error'], 'RuntimeError: output sampler failed')

    def test_cleanup_failure_does_not_mask_original_sampling_failure(self):
        fixture, report, _, _, error = self.run_main(sample_error=True, cleanup_error=True)
        self.assertIsInstance(error, RuntimeError)
        self.assertEqual(str(error), 'output sampler failed')
        self.assertIn('cleanup failed', report['cleanup_error'])
        self.assertIn('idle', report)
        self.assertTrue(fixture.closed)

    def test_report_names_the_single_output_producer_pane(self):
        fixture, report, _, _, error = self.run_main()
        self.assertIsNone(error)
        self.assertEqual(report['configuration'].get('output_producer_panes'), 1)
        self.assertEqual(fixture.output_panes, [fixture.sessions[0]['id']])

    def test_marker_arriving_after_roundtrip_deadline_is_rejected(self):
        clock = types.SimpleNamespace(now=0)
        clock.monotonic = lambda: clock.now
        clock.sleep = lambda duration: setattr(clock, 'now', clock.now + duration)

        def api(method, **params):
            if method == 'panes.capture':
                clock.now = 12
                return {'text': 'TAaaaaaa'}
            return {'ok': True}

        fixture = types.SimpleNamespace(api=api)
        error = None
        with mock.patch.object(BENCH, 'time', clock), mock.patch.object(BENCH.uuid, 'uuid4', return_value=types.SimpleNamespace(hex='a' * 32)):
            try:
                BENCH.roundtrip(fixture, {'id': 'owned-pane'})
            except Exception as caught:
                error = caught
        self.assertIsInstance(error, TimeoutError)

    def test_generated_producer_outlives_all_timed_roundtrips_and_load(self):
        _, _, _, source, error = self.run_main()
        self.assertIsNone(error)
        clock = types.SimpleNamespace(now=0)
        clock.monotonic = lambda: clock.now
        clock.sleep = lambda amount: setattr(clock, 'now', clock.now + 1)
        fake_os = types.SimpleNamespace(write=lambda fd, block: len(block))
        modules = {'os': fake_os, 'time': clock}
        namespace = {'__builtins__': {'__import__': lambda name, *args, **kwargs: modules[name]}}
        exec(compile(source, 'owned-output.py', 'exec'), namespace)
        self.assertGreaterEqual(namespace['end'], 1 + 2 * 10 + 1)

    def test_owned_fixture_has_minimal_prompt_and_isolated_shell_roots(self):
        fixture = REAL_FIXTURE(pathlib.Path('/unused-owned-test.app'))
        try:
            self.assertEqual(fixture.env['HOME'], str(fixture.home))
            self.assertEqual(fixture.env['ZDOTDIR'], str(fixture.home))
            self.assertEqual(fixture.env['TRANO_DATA_DIR'], str(fixture.root))
            self.assertTrue((fixture.home / '.zshrc').exists(), 'Owned prompt configuration is missing')
            self.assertEqual((fixture.home / '.zshrc').read_text(), "PROMPT='%# '\nRPROMPT=\n")
        finally:
            BENCH.shutil.rmtree(fixture.directory)

    def marker_output(self):
        fixture = object.__new__(REAL_FIXTURE)
        printed = []

        def api(method, **params):
            if method == 'panes.send':
                with tempfile.TemporaryDirectory() as directory:
                    printed.append(subprocess.check_output(['/bin/zsh', '-f', '-c', params['text']], cwd=directory, env={'PATH': '/usr/bin:/bin', 'HOME': directory, 'ZDOTDIR': directory, 'TRANO_DATA_DIR': directory}))
            return {'text': printed[-1].decode()}

        fixture.api = api
        marker = fixture.prepare_marker({'id': 'owned-pane'})
        return marker, printed[0]

    def test_readiness_marker_fits_narrow_terminal_columns(self):
        marker, output = self.marker_output()
        self.assertLessEqual(len(marker), 8)
        self.assertIn(marker.encode(), output)

    def test_readiness_marker_is_printed_at_bottom_before_viewport_shrink(self):
        marker, output = self.marker_output()
        self.assertEqual(output, b'\x1b[2J\x1b[999;1H' + marker.encode() + b'\n')

    def test_interrupt_keeps_completed_measurements_and_records_interrupted_status(self):
        fixture, report, _, _, error = self.run_main(sample_error=KeyboardInterrupt())
        self.assertIsInstance(error, KeyboardInterrupt)
        self.assertEqual(report.get('status'), 'interrupted')
        self.assertIn('idle', report)
        self.assertEqual(len(report['native_readiness_details']), 2)
        self.assertTrue(fixture.closed)

    def test_interrupt_skips_diagnostic_calls_before_owned_cleanup(self):
        fixture, report, _, _, error = self.run_main(sample_error=KeyboardInterrupt())
        self.assertIsInstance(error, KeyboardInterrupt)
        self.assertEqual(fixture.post_interrupt_calls, [])
        self.assertEqual(report['status'], 'interrupted')
        self.assertIn('idle', report)
        self.assertTrue(fixture.closed)

    def test_early_renderer_exit_does_not_reuse_previous_readiness_payload(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = object.__new__(REAL_FIXTURE)
            fixture.directory = pathlib.Path(directory)
            fixture.gui_path = pathlib.Path('/unused-owned-test.app/TranoApp')
            fixture.env = {}
            fixture.readiness_result = {'ready': True, 'terminalViews': 10}
            process = types.SimpleNamespace(poll=lambda: 1)
            with mock.patch.object(BENCH.subprocess, 'Popen', return_value=process):
                with self.assertRaisesRegex(RuntimeError, 'exited before readiness'):
                    fixture.start_gui('TR123456')
            self.assertIsNone(fixture.readiness_result)

    def test_successful_resource_sampling_returns_every_raw_snapshot(self):
        clock = types.SimpleNamespace(now=0)
        clock.monotonic = lambda: clock.now
        clock.sleep = lambda duration: setattr(clock, 'now', clock.now + duration)
        rows = [
            {'at': 0, 'rss_mib': 3, 'processes': {123: {'rss_mib': 3, 'cpu_seconds': 1}}},
            {'at': 1, 'rss_mib': 4, 'processes': {123: {'rss_mib': 4, 'cpu_seconds': 2}}},
        ]
        fixture = types.SimpleNamespace(product_pids=lambda: {123}, resources=mock.Mock(side_effect=rows))
        with mock.patch.object(BENCH, 'time', clock):
            result = BENCH.sample_resources(fixture, 1, 1)
        self.assertEqual(result.get('samples'), rows)
        self.assertEqual(result['resident_process_cpu_core_percent'], 100)

    def test_resource_sampling_retains_raw_snapshots_after_mid_sample_failure(self):
        clock = types.SimpleNamespace(now=0)
        clock.monotonic = lambda: clock.now
        clock.sleep = lambda duration: setattr(clock, 'now', clock.now + duration)
        rows = [
            {'at': 0, 'rss_mib': 3, 'processes': {123: {'rss_mib': 3, 'cpu_seconds': 1}}},
            {'at': 1, 'rss_mib': 4, 'processes': {123: {'rss_mib': 4, 'cpu_seconds': 2}}},
        ]
        fixture = types.SimpleNamespace(product_pids=lambda: {123}, resources=mock.Mock(side_effect=[*rows, RuntimeError('sample failed')]))
        retained = []
        error = None
        with mock.patch.object(BENCH, 'time', clock):
            try:
                BENCH.sample_resources(fixture, 3, 1, samples=retained)
            except Exception as caught:
                error = caught
        self.assertIsInstance(error, RuntimeError)
        self.assertEqual(retained, rows)


if __name__ == '__main__':
    unittest.main()
