# lunation — project brief

## What this is
A macOS tool that keeps the Mac awake **with the lid closed** for exactly as long as a
long, unattended task (typically Claude Code) is working — then lets it sleep again
automatically. The point is to shut the laptop and walk away during long agent/build runs
without (a) the Mac sleeping mid-task or (b) leaving sleep disabled after the task finishes.

## The product
lunation is two pieces, both in this repo:
- **`daemon/`** — a root `launchd` LaunchDaemon that detects when Claude Code is working
  (heartbeat-only) and toggles `pmset -a disablesleep` on its own. This is the core.
- **`MenuBarApp/`** — a SwiftUI `MenuBarExtra` app on top of the daemon: live status, a
  manual Force Awake, and settings. It installs the daemon and enables the CLI hooks.

There is **no CLI / wrapper.** An earlier v1 was a `lunation` bash wrapper you ran your task
*through*; it has been **removed** because it only covered commands launched through it and
required remembering the prefix. Do not reintroduce a wrapper — the daemon + menu-bar app is
the whole product now.

## Hard technical facts (do NOT relearn these the hard way)
- **`caffeinate` cannot keep the Mac awake with the lid closed.** Neither can standard
  IOKit power assertions (`PreventUserIdleSystemSleep` / `PreventSystemSleep`). Lid-close
  sleep is governed separately.
- The lever that actually works is **`sudo pmset -a disablesleep 1`** (revert with `0`).
  It is **root-only** and **global** (affects the whole system while set, not one process).
  Build everything around this. Do not waste time trying to make it lid-proof via
  `caffeinate` or IOKit assertions — they won't override the lid.
- **Thermals are a real hazard.** A closed Mac under load can't shed heat. Never encourage
  bag/enclosed use; default to refusing on battery.
- **App Store is impossible** for this category (pmset/disablesleep + a root daemon violate
  sandbox/guidelines). Distribution is notarized, outside the App Store.

## Why the wrapper was dropped
The removed v1 wrapper only covered a command launched **through** it — it couldn't detect a
`claude` session you started normally, and you had to remember the `lunation` prefix. The
ambient daemon below solves both by watching for Claude Code work directly, no matter how the
agent was launched.

## M2 — Ambient daemon
A `launchd` **LaunchDaemon** (runs as root, so it can call `pmset` without a password)
that watches for Claude Code actually working and toggles sleep on its own.

Spec:
- Install at `/Library/LaunchDaemons/com.<you>.lunation.plist`, `KeepAlive` true so it
  restarts if it dies.
- Poll every ~10s (configurable).
- **Activity detection (heartbeat-only):** the Claude Code CLI's hooks touch a heartbeat
  file (`/etc/lunation/heartbeat`) on each prompt/tool use and clear it on Stop. The daemon
  counts work as active if the heartbeat was touched within a configurable window (~180s,
  which bridges model-thinking pauses). This is the ONLY activity signal — see the resolved
  design note below for why the CPU heuristic was removed.
- **Grace period:** only return to "idle" after no fresh heartbeat for N consecutive seconds
  (start ~90s), giving a smooth wind-down after the agent stops.
- **Idempotency:** track desired vs current state; only call `pmset` on a transition.
- **Power guardrail:** if on battery, do not disable sleep (log it). Optional opt-in config.
- **Reliability (critical):** ALWAYS reset `disablesleep 0` on daemon startup (safety net
  in case a previous run left it set), and on graceful stop. If the daemon is killed while
  sleep is disabled, the next launchd restart must clean it up.
- Config via a small JSON/plist (thresholds, allow-battery, poll interval, heartbeat
  window). Log to a file under `/var/log` or unified logging.

Resolved design note (was: "CPU heuristic can misfire"): the CPU/process heuristic was
**removed entirely**. It falsely held the Mac awake whenever the Claude **desktop app** was
open — that app pegs CPU (>100%) while idle and matched the `claude` process pattern — and it
could also miss low-CPU I/O-bound work. Detection is now heartbeat-only: an exact signal from
the CLI, with no false positives from the desktop app. Tradeoff: detection needs the hooks.
The menu-bar app enables them **automatically on first install** (`DaemonManager`, one-time
via a `didAutoEnableClaudeHooks` UserDefaults flag — a later manual toggle-off is respected
and never overridden). With them off, only manual Force Awake keeps the Mac up. This is the
accepted, simplest reliable approach.

## M3 — Menu-bar app (after the daemon works)
A SwiftUI `MenuBarExtra` app that sits on top of the daemon:
- Live status: Idle / Awake (Claude working) / Forced awake.
- Manual one-click "stay awake now" toggle and "sleep normally."
- Settings: heartbeat window, grace period, allow-battery, thermal cutoff, poll interval.

Privilege model:
- The app must NOT disable sleep directly (and must NOT run `claude` as root). The **root
  daemon** does the privileged work; the app only reads status and writes config/intent.
- **Do NOT use `SMAppService` to register the daemon.** It was tried and does not work here:
  `SMAppService.daemon` requires `BundleProgram` to be a signed Mach-O in the app bundle, but
  our daemon is a `#!/usr/bin/python3` *script*, so launchd fails to spawn it (`EX_CONFIG`,
  "penalty box") — it registers but never runs, and the resulting smd-managed job can't be
  controlled with `launchctl` (kickstart hangs). Instead the app installs a **classic
  LaunchDaemon** the same way `daemon/install.sh` does: copy the daemon to
  `/usr/local/lib/lunation/`, write a `ProgramArguments` plist (explicit `/usr/bin/python3
  <path>`) to `/Library/LaunchDaemons/`, and load it via `launchctl bootstrap`, authorized by
  a one-shot `osascript "… with administrator privileges"` run as a **subprocess** (in-process
  `NSAppleScript` deadlocks the auth UI). "Installed" = both files exist (not SM status).
  SMAppService is still used only to `unregister()` any stale registration from older builds.
- App ↔ daemon communication: keep it simple first — app writes a config/intent file the
  daemon reads; upgrade to XPC if needed.
- Distribute notarized, outside the App Store.

## Working agreement for Claude Code
- Respect the hard technical facts above; don't reintroduce caffeinate/IOKit for lid-close.
- Reliability of the **revert** is the top priority — never leave a user's Mac with sleep
  permanently disabled. Defensive resets on startup/stop/crash.
- Keep the thermal/battery guardrails in every layer.
- Build M2 fully and prove it (close the lid, run a real Claude Code task, confirm it stays
  awake then sleeps within the grace period after) before starting M3.
