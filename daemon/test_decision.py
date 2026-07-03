#!/usr/bin/python3
"""
Integration tests for the daemon's per-poll DECISION, driving the real
`Daemon.run()` loop for a single iteration with all OS-touching calls mocked.

These cover the precedence logic that the per-helper unit tests in
test_lunation.py can't: thermal beats force, force beats the battery guard,
battery suppresses the heartbeat heuristic — and the safety-critical revert
(disablesleep -> 0) on startup and on stop.

Detection is heartbeat-only (a fresh Claude Code heartbeat = active); there is
no CPU/process heuristic.

Run:  python3 daemon/test_decision.py
"""

import os
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from importlib.util import spec_from_loader, module_from_spec
from pathlib import Path
from unittest import mock

_DAEMON = os.path.join(os.path.dirname(__file__), "lunation-daemon")
_loader = SourceFileLoader("lunation_daemon", _DAEMON)
_spec = spec_from_loader("lunation_daemon", _loader)
sa = module_from_spec(_spec)
_loader.exec_module(sa)


# A config with every guardrail "on" so each test can relax just the axis it
# exercises. allow_battery False, thermal cutoff active, heartbeat window 180s.
BASE_CFG = {
    "grace_period_seconds": 90,
    "poll_interval_seconds": 10,
    "allow_battery": False,
    "thermal_cutoff": 50,
    "heartbeat_window_seconds": 180,
}

# A heartbeat age inside the window → "active"; None → no heartbeat → idle.
ACTIVE_AGE = 5.0


class DecisionHarness:
    """Drives Daemon.run() for exactly one poll iteration and records every
    set_disablesleep() call plus the final status payload."""

    def __init__(self, *, cfg=None, on_ac=True, force=(False, None),
                 thermal_limit=None, thermal_level=None, heartbeat_age=None,
                 actual_disablesleep=None):
        self.cfg = dict(cfg or BASE_CFG)
        self._on_ac = on_ac
        self.force = force
        self.thermal_limit = thermal_limit
        self.thermal_level = thermal_level
        self.heartbeat_age = heartbeat_age
        self.actual_disablesleep = actual_disablesleep
        self.disablesleep_calls = []   # ints in call order: 0 or 1
        self.status_writes = []         # every write_status payload, in order

    def run_one(self):
        logdir = tempfile.mkdtemp()
        patches = {
            "LOG_FILE": Path(logdir) / "daemon.log",
            "WAKE_FIFO": Path(logdir) / "wake",
            "STATUS_FILE": Path(logdir) / "status.json",
            "load_config": lambda: dict(self.cfg),
            "on_ac": lambda: self._on_ac,
            "read_force_intent": lambda: self.force,
            "get_thermal_pressure": lambda: self.thermal_limit,
            "read_thermal_hint": lambda *a, **k: self.thermal_level,
            "read_heartbeat_age": lambda *a, **k: self.heartbeat_age,
            "get_actual_disablesleep": lambda: self.actual_disablesleep,
            "setup_config_dir": lambda log: None,
        }

        def fake_set(value):
            self.disablesleep_calls.append(value)
            return True

        def fake_write_status(state, sleep_disabled, force_awake, *a, **k):
            self.status_writes.append({
                "state": state,
                "sleep_disabled": sleep_disabled, "force_awake": force_awake,
            })

        with mock.patch.multiple(sa, **patches), \
                mock.patch.object(sa, "set_disablesleep", fake_set), \
                mock.patch.object(sa, "write_status", fake_write_status):
            d = sa.Daemon()
            # Stop the loop after a single decision: the interruptible sleep at
            # the end of the iteration flips running off.
            def stop(_seconds):
                d.running = False
            d._interruptible_sleep = stop
            d.run()
        return self

    @property
    def decision_status(self):
        """The status written during the poll iteration (the first write).
        The daemon's finally: block writes one more status on shutdown, so the
        decision is status_writes[0], not the last."""
        return self.status_writes[0]

    @property
    def kept_awake(self):
        """Whether the per-poll DECISION held the Mac awake, read from the
        status the daemon published before its shutdown revert."""
        return bool(self.decision_status["sleep_disabled"])


class StartupAndStopRevertTests(unittest.TestCase):
    def test_startup_safety_resets_to_zero_first(self):
        # The very first pmset call on startup must be disablesleep 0, even if
        # the decision then re-enables — a prior crashed run could have left 1.
        h = DecisionHarness(heartbeat_age=ACTIVE_AGE).run_one()  # active → will re-disable
        self.assertEqual(h.disablesleep_calls[0], 0,
                         "startup must safety-reset to 0 before anything else")

    def test_stop_always_reverts_to_zero(self):
        # However the loop exits, the final state handed to pmset is 0.
        h = DecisionHarness(heartbeat_age=ACTIVE_AGE).run_one()
        self.assertEqual(h.disablesleep_calls[-1], 0,
                         "daemon stop must leave sleep RE-ENABLED")


class HeartbeatDetectionTests(unittest.TestCase):
    def test_fresh_heartbeat_keeps_awake(self):
        h = DecisionHarness(heartbeat_age=ACTIVE_AGE).run_one()
        self.assertTrue(h.kept_awake)
        self.assertEqual(h.decision_status["state"], "working")

    def test_no_heartbeat_lets_sleep(self):
        h = DecisionHarness(heartbeat_age=None).run_one()
        self.assertFalse(h.kept_awake)
        self.assertEqual(h.decision_status["state"], "idle")

    def test_stale_heartbeat_lets_sleep(self):
        # Older than the 180s window → not active.
        h = DecisionHarness(heartbeat_age=999.0).run_one()
        self.assertFalse(h.kept_awake)
        self.assertEqual(h.decision_status["state"], "idle")


class ForceAwakeTests(unittest.TestCase):
    def test_force_keeps_awake_when_idle(self):
        h = DecisionHarness(heartbeat_age=None, force=(True, None)).run_one()
        self.assertTrue(h.kept_awake)
        self.assertTrue(h.decision_status["force_awake"])

    def test_force_overrides_battery_guard(self):
        # On battery the heartbeat heuristic is suppressed, but an explicit user
        # force is honored (the user opted in).
        h = DecisionHarness(heartbeat_age=None, on_ac=False, force=(True, None)).run_one()
        self.assertTrue(h.kept_awake)


class BatteryGuardTests(unittest.TestCase):
    def test_battery_suppresses_heartbeat_heuristic(self):
        # Fresh heartbeat but on battery and no force → must let it sleep.
        h = DecisionHarness(heartbeat_age=ACTIVE_AGE, on_ac=False).run_one()
        self.assertFalse(h.kept_awake)
        self.assertEqual(h.decision_status["state"], "idle")

    def test_allow_battery_re_enables_heuristic(self):
        cfg = dict(BASE_CFG, allow_battery=True)
        h = DecisionHarness(cfg=cfg, heartbeat_age=ACTIVE_AGE, on_ac=False).run_one()
        self.assertTrue(h.kept_awake)


class ThermalPrecedenceTests(unittest.TestCase):
    def test_thermal_beats_activity(self):
        # Active, but Intel speed-limit at the cutoff → force sleep.
        h = DecisionHarness(heartbeat_age=ACTIVE_AGE, thermal_limit=50).run_one()
        self.assertFalse(h.kept_awake)
        self.assertTrue(h.decision_status is not None)

    def test_thermal_beats_force(self):
        # The one guardrail that overrides an explicit user force.
        h = DecisionHarness(heartbeat_age=None, force=(True, None), thermal_limit=40).run_one()
        self.assertFalse(h.kept_awake)

    def test_app_hint_serious_trips_on_apple_silicon(self):
        # No pmset speed-limit (Apple Silicon), but app reports "serious".
        h = DecisionHarness(heartbeat_age=ACTIVE_AGE, thermal_limit=None,
                            thermal_level="serious").run_one()
        self.assertFalse(h.kept_awake)

    def test_nominal_hint_does_not_trip(self):
        h = DecisionHarness(heartbeat_age=ACTIVE_AGE, thermal_limit=100,
                            thermal_level="nominal").run_one()
        self.assertTrue(h.kept_awake)


if __name__ == "__main__":
    unittest.main(verbosity=2)
