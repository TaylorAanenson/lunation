#!/usr/bin/python3
"""
Unit tests for lunation-daemon. Stdlib `unittest` only (no pytest) so it runs
on the same system python3 the daemon uses, with no venv.

Run:  python3 daemon/test_lunation.py   (or: python3 -m unittest -v from daemon/)
"""

import json
import os
import stat
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from importlib.util import spec_from_loader, module_from_spec
from pathlib import Path
from types import SimpleNamespace

# The daemon has no .py extension, so load it explicitly.
_DAEMON = os.path.join(os.path.dirname(__file__), "lunation-daemon")
_loader = SourceFileLoader("lunation_daemon", _DAEMON)
_spec = spec_from_loader("lunation_daemon", _loader)
sa = module_from_spec(_spec)
_loader.exec_module(sa)


class LoadConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.cfg = Path(self.tmp) / "config.json"
        self._orig = sa.CONFIG_FILE
        sa.CONFIG_FILE = self.cfg

    def tearDown(self):
        sa.CONFIG_FILE = self._orig

    def write(self, obj):
        self.cfg.write_text(json.dumps(obj))

    def test_defaults_when_missing(self):
        # No file at all → pure defaults.
        cfg = sa.load_config()
        self.assertEqual(cfg["poll_interval_seconds"], 10)
        self.assertEqual(cfg["heartbeat_window_seconds"], 180)

    def test_clamps_busy_loop_poll_zero(self):
        self.write({"poll_interval_seconds": 0})
        self.assertEqual(sa.load_config()["poll_interval_seconds"], 1)

    def test_clamps_negative_grace(self):
        self.write({"grace_period_seconds": -5})
        self.assertEqual(sa.load_config()["grace_period_seconds"], 0)

    def test_clamps_huge_poll(self):
        self.write({"poll_interval_seconds": 99999})
        self.assertEqual(sa.load_config()["poll_interval_seconds"], 3600)

    def test_garbage_types_fall_back_to_default(self):
        self.write({"poll_interval_seconds": "nonsense"})
        self.assertEqual(sa.load_config()["poll_interval_seconds"], 10)

    def test_unknown_keys_ignored(self):
        # Stale keys from an older config (e.g. the removed process patterns)
        # are carried as-is but never crash load; managed keys still resolve.
        self.write({"process_patterns": ["claude"], "cpu_threshold": 15.0})
        cfg = sa.load_config()
        self.assertEqual(cfg["poll_interval_seconds"], 10)
        self.assertEqual(cfg["heartbeat_window_seconds"], 180)

    def test_corrupt_json_uses_defaults(self):
        self.cfg.write_text("{not valid json")
        self.assertEqual(sa.load_config()["heartbeat_window_seconds"], 180)


class ForceIntentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.intent = Path(self.tmp) / "intent.json"
        self._orig = sa.INTENT_FILE
        sa.INTENT_FILE = self.intent

    def tearDown(self):
        sa.INTENT_FILE = self._orig

    def write(self, obj):
        self.intent.write_text(json.dumps(obj))

    def test_missing_file(self):
        self.assertEqual(sa.read_force_intent(), (False, None))

    def test_force_no_expiry(self):
        self.write({"force_awake": True})
        self.assertEqual(sa.read_force_intent(), (True, None))

    def test_force_future_expiry_active(self):
        future = sa.time.time() + 3600
        self.write({"force_awake": True, "expires_at": future})
        force, exp = sa.read_force_intent()
        self.assertTrue(force)
        self.assertAlmostEqual(exp, future, places=3)

    def test_force_past_expiry_inactive(self):
        past = sa.time.time() - 10
        self.write({"force_awake": True, "expires_at": past})
        force, exp = sa.read_force_intent()
        self.assertFalse(force)            # expired → not forcing
        self.assertAlmostEqual(exp, past, places=3)

    def test_force_false(self):
        self.write({"force_awake": False})
        self.assertEqual(sa.read_force_intent(), (False, None))


class StateMachineTests(unittest.TestCase):
    GRACE = 90
    POLL = 10

    def step(self, state, below, above):
        return sa.step_state_machine(state, below, above, self.POLL, self.GRACE)

    def test_idle_to_working(self):
        state, below, msg = self.step("idle", 0, True)
        self.assertEqual(state, "working")
        self.assertEqual(below, 0)
        self.assertIn("working", msg)

    def test_working_stays_working_no_message(self):
        state, below, msg = self.step("working", 0, True)
        self.assertEqual(state, "working")
        self.assertIsNone(msg)

    def test_working_to_grace_on_drop(self):
        state, below, msg = self.step("working", 0, False)
        self.assertEqual(state, "grace")
        self.assertEqual(below, self.POLL)
        self.assertIn("grace", msg)

    def test_grace_accumulates_below_threshold(self):
        state, below, msg = self.step("grace", 10, False)
        self.assertEqual(state, "grace")
        self.assertEqual(below, 20)
        self.assertIsNone(msg)

    def test_grace_to_idle_after_grace_period(self):
        # 80 + 10 = 90 >= grace → idle
        state, below, msg = self.step("grace", 80, False)
        self.assertEqual(state, "idle")
        self.assertEqual(below, 0)
        self.assertIn("idle", msg)

    def test_grace_back_to_working_resets_counter(self):
        state, below, msg = self.step("grace", 50, True)
        self.assertEqual(state, "working")
        self.assertEqual(below, 0)

    def test_idle_stays_idle(self):
        state, below, msg = self.step("idle", 0, False)
        self.assertEqual(state, "idle")
        self.assertEqual(below, 0)
        self.assertIsNone(msg)

    def test_full_lifecycle_timing(self):
        """idle → working → (grace for 90s) → idle, exactly at the boundary."""
        state, below = "idle", 0
        state, below, _ = sa.step_state_machine(state, below, True, 10, 90)
        self.assertEqual(state, "working")
        # Drop below threshold; first step enters grace.
        state, below, _ = sa.step_state_machine(state, below, False, 10, 90)
        self.assertEqual(state, "grace")
        # Stay below for 8 more 10s polls (total 90s) → should hit idle.
        for _ in range(8):
            state, below, _ = sa.step_state_machine(state, below, False, 10, 90)
        self.assertEqual(state, "idle")


class ActualDisablesleepTests(unittest.TestCase):
    def patch_run(self, stdout, raise_exc=False):
        def fake_run(*a, **k):
            if raise_exc:
                raise RuntimeError("boom")
            return SimpleNamespace(stdout=stdout, returncode=0)
        self._orig = sa.subprocess.run
        sa.subprocess.run = fake_run
        self.addCleanup(lambda: setattr(sa.subprocess, "run", self._orig))

    def test_disabled_true(self):
        self.patch_run(" SleepDisabled         1\n hibernatemode  0\n")
        self.assertIs(sa.get_actual_disablesleep(), True)

    def test_disabled_false(self):
        self.patch_run(" SleepDisabled         0\n")
        self.assertIs(sa.get_actual_disablesleep(), False)

    def test_absent_returns_none(self):
        self.patch_run(" hibernatemode  3\n standby  1\n")
        self.assertIsNone(sa.get_actual_disablesleep())

    def test_exception_returns_none(self):
        self.patch_run("", raise_exc=True)
        self.assertIsNone(sa.get_actual_disablesleep())


class ThermalTests(unittest.TestCase):
    def patch_run(self, stdout, raise_exc=False):
        def fake_run(*a, **k):
            if raise_exc:
                raise RuntimeError("boom")
            return SimpleNamespace(stdout=stdout, returncode=0)
        self._orig = sa.subprocess.run
        sa.subprocess.run = fake_run
        self.addCleanup(lambda: setattr(sa.subprocess, "run", self._orig))

    # --- pure decision ---
    def test_cutoff_trips_at_or_below_threshold(self):
        self.assertTrue(sa.thermal_should_cutoff(50, 50))
        self.assertTrue(sa.thermal_should_cutoff(30, 50))

    def test_cutoff_does_not_trip_above_threshold(self):
        self.assertFalse(sa.thermal_should_cutoff(51, 50))
        self.assertFalse(sa.thermal_should_cutoff(100, 50))

    def test_cutoff_disabled_when_zero(self):
        self.assertFalse(sa.thermal_should_cutoff(1, 0))
        self.assertFalse(sa.thermal_should_cutoff(0, 0))

    def test_cutoff_none_speed_never_trips(self):
        self.assertFalse(sa.thermal_should_cutoff(None, 50))

    # --- pmset parsing ---
    def test_parse_speed_limit(self):
        self.patch_run("CPU_Scheduler_Limit \t= 100\nCPU_Speed_Limit \t= 80\n")
        self.assertEqual(sa.get_thermal_pressure(), 80)

    def test_parse_absent_returns_none(self):
        self.patch_run("CPU_Available_CPUs \t= 8\n")
        self.assertIsNone(sa.get_thermal_pressure())

    def test_parse_exception_returns_none(self):
        self.patch_run("", raise_exc=True)
        self.assertIsNone(sa.get_thermal_pressure())

    # --- app thermal hint (read_thermal_hint) ---
    def write_hint(self, payload):
        tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(payload, tmp)
        tmp.close()
        self.addCleanup(lambda: os.unlink(tmp.name))
        self._orig_tf = sa.THERMAL_FILE
        sa.THERMAL_FILE = type(sa.THERMAL_FILE)(tmp.name)
        self.addCleanup(lambda: setattr(sa, "THERMAL_FILE", self._orig_tf))

    def test_hint_fresh_returns_level(self):
        self.write_hint({"level": "serious", "timestamp": 1000.0})
        self.assertEqual(sa.read_thermal_hint(now=1010.0, max_age=30), "serious")

    def test_hint_stale_returns_none(self):
        self.write_hint({"level": "critical", "timestamp": 1000.0})
        self.assertIsNone(sa.read_thermal_hint(now=1100.0, max_age=30))

    def test_hint_missing_file_returns_none(self):
        self._orig_tf = sa.THERMAL_FILE
        sa.THERMAL_FILE = type(sa.THERMAL_FILE)("/nonexistent/lunation/thermal.json")
        self.addCleanup(lambda: setattr(sa, "THERMAL_FILE", self._orig_tf))
        self.assertIsNone(sa.read_thermal_hint(now=1.0))

    def test_hint_trips_only_on_serious_or_critical(self):
        # Mirrors the daemon's trip condition for the hint source.
        for level, trips in [("nominal", False), ("fair", False),
                             ("serious", True), ("critical", True)]:
            self.assertEqual(level in ("serious", "critical"), trips, level)


class HeartbeatTests(unittest.TestCase):
    # --- pure freshness decision ---
    def test_fresh_within_window(self):
        self.assertTrue(sa.heartbeat_is_fresh(10.0, 180))
        self.assertTrue(sa.heartbeat_is_fresh(180.0, 180))  # boundary

    def test_stale_outside_window(self):
        self.assertFalse(sa.heartbeat_is_fresh(181.0, 180))

    def test_window_zero_disables(self):
        self.assertFalse(sa.heartbeat_is_fresh(0.0, 0))

    def test_missing_age_never_fresh(self):
        self.assertFalse(sa.heartbeat_is_fresh(None, 180))

    # --- file-mtime age ---
    def test_age_from_existing_file(self):
        tmp = tempfile.NamedTemporaryFile(suffix=".hb", delete=False)
        tmp.close()
        os.utime(tmp.name, (1000.0, 1000.0))  # set mtime
        self.addCleanup(lambda: os.unlink(tmp.name))
        orig = sa.HEARTBEAT_FILE
        sa.HEARTBEAT_FILE = type(sa.HEARTBEAT_FILE)(tmp.name)
        self.addCleanup(lambda: setattr(sa, "HEARTBEAT_FILE", orig))
        self.assertAlmostEqual(sa.read_heartbeat_age(now=1042.0), 42.0, places=3)

    def test_age_missing_file_returns_none(self):
        orig = sa.HEARTBEAT_FILE
        sa.HEARTBEAT_FILE = type(sa.HEARTBEAT_FILE)("/nonexistent/lunation/heartbeat")
        self.addCleanup(lambda: setattr(sa, "HEARTBEAT_FILE", orig))
        self.assertIsNone(sa.read_heartbeat_age(now=1.0))


class SetupConfigDirTests(unittest.TestCase):
    """The config dir holds files the ROOT daemon trusts (intent.json can force
    the Mac awake). It must never be group- or world-writable, since macOS users
    share the `staff` primary group."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.cfgfile = Path(self.tmp) / "lunation" / "config.json"
        self._orig = sa.CONFIG_FILE
        sa.CONFIG_FILE = self.cfgfile
        self.log = SimpleNamespace(info=lambda *a, **k: None,
                                   warning=lambda *a, **k: None)

    def tearDown(self):
        sa.CONFIG_FILE = self._orig

    def test_config_dir_not_group_or_world_writable(self):
        sa.setup_config_dir(self.log)
        mode = stat.S_IMODE(os.stat(self.cfgfile.parent).st_mode)
        # No write bit for group (0o020) or other (0o002).
        self.assertEqual(mode & 0o022, 0, f"dir is too permissive: {oct(mode)}")
        self.assertEqual(mode, 0o755)


class ForceSleepDecisionTests(unittest.TestCase):
    """should_force_sleep gates the `pmset sleepnow` nudge that finishes a
    lid-close macOS skipped. Primary signal is AppleClamshellCausesSleep; HID
    idle is only a fallback when that bit is unreadable.
    Args: (lid_closed, clamshell_causes_sleep, hid_idle, quiet_seconds, enabled)."""

    Q = sa.LID_INPUT_QUIET_SECONDS

    # --- gating ---
    def test_lid_open_never_forces_sleep(self):
        self.assertFalse(sa.should_force_sleep(False, True, 9999, self.Q, True))

    def test_unknown_lid_never_forces_sleep(self):
        # Desktop Mac / no clamshell sensor → never force.
        self.assertFalse(sa.should_force_sleep(None, True, 9999, self.Q, True))

    def test_disabled_never_forces_sleep(self):
        self.assertFalse(sa.should_force_sleep(True, True, 9999, self.Q, False))

    # --- primary signal: AppleClamshellCausesSleep ---
    def test_policy_true_forces_even_with_recent_input(self):
        # macOS says this lid-close should sleep → nudge, regardless of HID idle.
        self.assertTrue(sa.should_force_sleep(True, True, 0, self.Q, True))

    def test_policy_false_blocks_even_when_input_quiet(self):
        # External display holding it awake → leave it, even if input is quiet.
        self.assertFalse(sa.should_force_sleep(True, False, 9999, self.Q, True))

    # --- fallback when the policy bit is unreadable (None) ---
    def test_fallback_quiet_forces(self):
        self.assertTrue(sa.should_force_sleep(True, None, self.Q + 10, self.Q, True))

    def test_fallback_recent_input_blocks(self):
        self.assertFalse(sa.should_force_sleep(True, None, 5, self.Q, True))

    def test_fallback_unknown_idle_forces(self):
        # Lid shut, neither signal readable → assume walk-away and sleep.
        self.assertTrue(sa.should_force_sleep(True, None, None, self.Q, True))


class SleepWhenLidClosedConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.cfg = Path(self.tmp) / "config.json"
        self._orig = sa.CONFIG_FILE
        sa.CONFIG_FILE = self.cfg

    def tearDown(self):
        sa.CONFIG_FILE = self._orig

    def test_defaults_true(self):
        self.assertTrue(sa.load_config()["sleep_when_lid_closed"])

    def test_respects_false(self):
        self.cfg.write_text(json.dumps({"sleep_when_lid_closed": False}))
        self.assertFalse(sa.load_config()["sleep_when_lid_closed"])

    def test_lid_input_quiet_default(self):
        self.assertEqual(sa.load_config()["lid_input_quiet_seconds"],
                         sa.LID_INPUT_QUIET_SECONDS)

    def test_lid_input_quiet_override(self):
        self.cfg.write_text(json.dumps({"lid_input_quiet_seconds": 60}))
        self.assertEqual(sa.load_config()["lid_input_quiet_seconds"], 60)

    def test_lid_input_quiet_clamps_negative(self):
        self.cfg.write_text(json.dumps({"lid_input_quiet_seconds": -5}))
        self.assertEqual(sa.load_config()["lid_input_quiet_seconds"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
