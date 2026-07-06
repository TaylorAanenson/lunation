# lunation

Keep your Mac awake **with the lid closed** for exactly as long as a long, unattended task
is working — then let it sleep again automatically. **Built for Claude Code:** shut the lid
and walk away during a long agent run without the Mac sleeping mid-task — or staying awake
after it finishes.

lunation is two pieces: a root **LaunchDaemon** that detects when Claude Code is working and
toggles sleep on its own, and a **menu-bar app** that shows status and lets you force the Mac
awake on demand. You don't wrap or launch anything through lunation — just run `claude`
however you normally do and close the lid.

**Requirements:** macOS 26+ · Apple Silicon. Distributed notarized, outside the App Store.

## Why this exists / how it's different
- `caffeinate -i <cmd>` keeps the Mac awake for a command's duration **but not with the
  lid closed** — closing the lid sleeps the Mac regardless.
- The only thing that defeats lid-close sleep is `sudo pmset -a disablesleep 1`, which is
  a global, all-or-nothing switch you have to remember to turn back off.
- Apps like Amphetamine keep you awake but you toggle them manually.

lunation ties the lid-close override to **Claude Code actually working**: the daemon flips
the switch on while the agent is active and off once it winds down, so you never leave sleep
disabled by accident — including the "task finished at 12:20am but the laptop stayed hot in
my bag till morning" failure.

## Ambient daemon — the core of lunation

The `daemon/` directory contains a `launchd` LaunchDaemon that detects when the **Claude Code
CLI** is working and toggles sleep automatically. Just run `claude` however you like and close
the lid. The **Claude desktop app** (Cowork, Chat) runs mostly server-side and isn't
auto-detected — use the menu-bar **Force awake** for those.

### How it works
- Detection is **heartbeat-only**. Claude Code's CLI hooks touch `/etc/lunation/heartbeat`
  as the agent works. The menu-bar app turns these hooks on automatically the first time you
  install the helper (toggle them off in Settings if you don't want them). There is **no
  CPU/process heuristic** — an earlier version summed `%cpu` of anything matching `claude`,
  but the Claude desktop app pegs CPU just sitting idle and falsely held the Mac awake, so
  that was removed.
- Polls every 10 s (configurable). If the heartbeat was touched within the heartbeat window
  (default 180 s), it counts as active: `disablesleep=1` — lid-close sleep is suppressed.
  The window bridges long model-thinking pauses where no work happens.
- When no fresh heartbeat arrives for 90 s (configurable grace period): `disablesleep=0` —
  normal sleep restored. The grace period gives a smooth wind-down after the agent stops.
- With the hooks **off**, the daemon does nothing automatically — only the menu-bar **Force
  awake** keeps the Mac up.
- Never disables sleep on battery (configurable opt-in).
- On every startup the daemon safety-resets `disablesleep=0` in case a prior run crashed
  with it left on.

### Install
```sh
cd daemon
sudo ./install.sh          # copies daemon, plist, creates /etc/lunation/config.json
```

### Verify it's working
```sh
./install.sh status        # shows daemon state, sleep state, last 10 log lines
tail -f /var/log/lunation-daemon.log
pmset -g | grep SleepDisabled   # shows "1" while Claude Code is active
```

### Configure
Edit `/etc/lunation/config.json` (changes take effect on the next poll — no restart needed):
```json
{
  "grace_period_seconds": 90,
  "poll_interval_seconds": 10,
  "allow_battery": false,
  "thermal_cutoff": 50,
  "heartbeat_window_seconds": 180,
  "sleep_when_lid_closed": true,
  "lid_input_quiet_seconds": 300
}
```
- **`heartbeat_window_seconds`** — the sole activity signal: if Claude Code's heartbeat hooks
  (enabled in the menu-bar app) have fired within this many seconds, count it as active. This
  bridges long model-thinking pauses. `0` disables it; with the hooks off there is no
  automatic detection at all.
- **`thermal_cutoff`** — safety net: if macOS throttles the CPU speed limit to ≤ this percent
  (or reports a serious/critical thermal state), force sleep regardless of activity so a
  closed Mac can't keep cooking under load. `0` disables the cutoff.
- **`sleep_when_lid_closed`** — when work ends with the lid **already shut**, macOS won't
  re-fire the lid-close sleep it suppressed while the Mac was held awake, so it would just sit
  there awake. With this on, the daemon nudges it to sleep (`pmset sleepnow`) on that transition
  — but only when macOS's own policy says the lid-close should sleep the Mac (IOKit's
  `AppleClamshellCausesSleep`, read after re-enabling sleep). So an active clamshell session on
  an external display, which reports `false`, is never yanked to sleep. Set `false` to leave all
  sleep decisions to macOS.
- **`lid_input_quiet_seconds`** — *fallback only.* When `AppleClamshellCausesSleep` can't be
  read, the daemon instead treats "no keyboard/mouse input for this long" (default 300 s) as a
  walk-away. Lower it for a faster hand-off to sleep; raise it to be more conservative.
- Values are **clamped** on load (`poll` 1–3600 s, `grace` 0–86400 s, `thermal_cutoff`
  0–100%, `heartbeat_window` 0–86400 s, `lid_input_quiet` 0–86400 s), so a bad config can't make
  the daemon busy-loop or stay awake forever. Unknown keys (e.g. a removed `process_patterns`)
  are ignored.

### Reliability guarantees
- **Startup reset:** the daemon always sets `disablesleep=0` on launch, in case a prior run
  crashed with it left on. `launchd` `KeepAlive` restarts it if it dies.
- **Drift reconciliation:** every poll it compares its belief against the real
  `pmset -g SleepDisabled` and re-asserts the correct state if they've diverged — so a stale
  belief can never leave your Mac stuck awake.
- **Log rotation:** logs to `/var/log/lunation-daemon.log` with rotation (1 MB × 3). `launchd`
  captures uncaught crash output separately to `/var/log/lunation-daemon.launchd.log`, so the
  two writers never fight over the rotated file.

### Security / threat model
The daemon runs as root and acts on files in `/etc/lunation/`, which is owned by the console
user so the menu-bar app can write them without `sudo`:
- `intent.json` — can force the Mac awake; `thermal.json` — can force it asleep;
  `config.json` — sets the thresholds and timing.
- The directory is mode **0755** (owner-write only). It is deliberately **not** group-writable:
  on macOS every account shares the `staff` primary group, so `0775` would effectively let any
  local user write these files. If ownership can't be set, the daemon leaves the dir root-owned
  rather than ever opening it world-writable.
- None of these inputs grant root code execution — the worst a local attacker with write access
  could do is keep the machine awake or force it to sleep. All numeric config is clamped, and
  stale `thermal.json` hints are ignored, so a crashed app can't pin the Mac asleep.

### Uninstall
```sh
sudo ./install.sh uninstall   # resets disablesleep, removes daemon + plist
```

### Detection tradeoffs
The daemon detects activity from Claude Code's heartbeat hooks — a direct signal from the
agent — not from CPU. This was a deliberate switch: a CPU heuristic falsely held the Mac
awake whenever the Claude desktop app was open (it pegs CPU while idle), and could miss
I/O-bound work that burns little CPU. The heartbeat is exact, but has its own tradeoffs:
- **Hooks must be enabled.** The menu-bar app enables them automatically the first time you
  install the helper — and never re-forces them, so turning them off in Settings sticks.
  Without the app, add them to `~/.claude/settings.json` by hand. With them off there is no
  automatic detection — only **Force awake**.
- **CLI only.** The heartbeat comes from the Claude Code CLI's hooks. The Claude desktop app
  (Cowork, Chat) writes no heartbeat and isn't auto-detected; use **Force awake** for those.
- **Long model-thinking pauses** are covered by the heartbeat window (default 180 s) — the
  hook fires on each prompt/tool use, so the Mac stays awake across pauses within the window.
- The design is deliberately conservative: a missed "awake" moment is less harmful than
  leaving sleep permanently disabled.

### Tests
Run everything from one entry point:
```sh
./run_tests.sh
```
That covers the daemon's logic (config clamping, force-intent expiry, the
idle→working→grace state machine, heartbeat freshness, drift detection, config-dir permissions),
the per-poll decision precedence (thermal beats force beats battery), and — when Xcode is
present — the menu-bar app's moon-phase logic:
```sh
python3 daemon/test_lunation.py    # daemon unit tests (stdlib, system python3)
python3 daemon/test_decision.py    # daemon decision/precedence tests
```

## Menu-bar app

`MenuBarApp/` is a SwiftUI `MenuBarExtra` app that sits on top of the daemon — it reads
status and writes config/intent, but never touches `pmset` itself (the root daemon does all
privileged work).

- **Live status:** Idle / Claude Code active / Winding down (with grace countdown) / Forced awake.
- **Force awake** with a duration: 1 h, 2 h, 8 h, until tomorrow, or indefinitely. Timed
  overrides show a live countdown and expire on their own. A manual force overrides the
  battery guard (deliberate opt-in) and shows a thermal warning when on battery.
- **Settings:** toggle **Claude Code detection** (the heartbeat hooks — required for any
  automatic keep-awake, and switched on automatically the first time you install the helper),
  heartbeat window, grace period, poll interval, thermal cutoff,
  allow-on-battery, launch-at-login, and a notifications toggle. Unsaved edits are flagged
  and the **Save** button enables only when there are changes.
- **Helper install:** installs a **classic LaunchDaemon** — one privileged step (authorized by
  an `osascript "… with administrator privileges"` prompt) copies the daemon to
  `/usr/local/lib/lunation/`, writes a `ProgramArguments` plist to `/Library/LaunchDaemons/`,
  and loads it via `launchctl bootstrap`. `SMAppService` is **not** used to register the
  daemon: `SMAppService.daemon` needs its `BundleProgram` to be a signed Mach-O, but our daemon
  is a `#!/usr/bin/python3` *script*, so launchd can't spawn it that way. It's used only to
  `unregister()` any stale registration left by older builds. "Installed" therefore means both
  files (plist + daemon binary) exist on disk, not an SMAppService status.

Open `MenuBarApp/Lunation.xcodeproj` in Xcode and run. The daemon script and its launchd
plist are bundled into the app and installed from there via the in-app "Install Helper" button.

### Building a release DMG
`./build-dmg.sh` produces a signed, notarized, stapled `dist/Lunation.dmg` ready to attach to a
GitHub Release. It archives the Release build, exports it with **Developer ID**, notarizes and
staples the app, wraps it in a DMG, signs it, then notarizes, staples, and Gatekeeper-verifies
the DMG. One-time prerequisites:
```sh
# a "Developer ID Application" cert must be in your keychain, plus a notarytool profile:
xcrun notarytool store-credentials notary --apple-id "you@example.com" --team-id 2WZ6A7Z8A4
brew install create-dmg   # for the styled drag-to-Applications window (else a plain DMG)
```
The install window (app icon → Applications alias over a branded background) is styled via
`create-dmg` using `dmg/background.png`; regenerate that art with `dmg/make-background.swift`.
Then just `./build-dmg.sh` (or `./build-dmg.sh path/to/Lunation.app` to package an already-built
app). Override `TEAM_ID`, `NOTARY_PROFILE`, etc. via env vars.
