import Foundation
import Observation
@preconcurrency import ServiceManagement

// Plist used by the osascript fallback installer. Uses ProgramArguments so
// launchctl can load it directly without SMAppService resolving BundleProgram.
private let fallbackPlist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.lunation.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>/usr/local/lib/lunation/lunation-daemon</string>
    </array>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/lunation-daemon.launchd.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/lunation-daemon.launchd.log</string>
    <key>ThrottleInterval</key>
    <integer>5</integer>
</dict>
</plist>
"""

@Observable @MainActor
final class DaemonManager {

    // MARK: — Published state

    var isInstalled: Bool
    var isInstalling = false
    var installError: String?
    /// True when the daemon installed at `daemonDst` differs from the copy
    /// bundled in this app — i.e. the app was updated but the helper wasn't.
    /// Only meaningful for the osascript-fallback install (a file at daemonDst);
    /// an SMAppService install runs from the bundle directly, so it never drifts.
    var needsUpdate = false

    // MARK: — Well-known paths

    nonisolated static let label     = "com.lunation.daemon"
    nonisolated static let plistName = "\(label).plist"
    nonisolated static let plistPath = "/Library/LaunchDaemons/\(label).plist"
    nonisolated static let daemonDst = "/usr/local/lib/lunation/lunation-daemon"
    nonisolated static let configDir = "/etc/lunation"

    nonisolated static var bundledDaemonPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons/lunation-daemon")
            .path
    }

    // MARK: —

    init() {
        isInstalled = Self.isHelperInstalled()
        checkForUpdate()
    }

    /// We install the daemon the *only* way that actually runs a Python-script
    /// daemon reliably: a classic LaunchDaemon (plist in /Library/LaunchDaemons,
    /// binary in /usr/local/lib) loaded via launchctl. (SMAppService can't spawn
    /// a script — its BundleProgram must be a signed Mach-O — so we deliberately
    /// don't use it to register.) "Installed" therefore means BOTH files exist;
    /// the SMAppService registration status is NOT a reliable signal and a stale
    /// one previously made the app show a dead "Restart" for a daemon that wasn't
    /// really there.
    nonisolated static func isHelperInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistPath)
            && FileManager.default.fileExists(atPath: daemonDst)
    }

    /// Re-evaluate install state from disk (e.g. when the menu opens), so a
    /// helper removed out from under us stops showing as installed. Skipped mid
    /// install/uninstall so it can't race the in-flight transition.
    func refreshInstalled() {
        guard !isInstalling else { return }
        isInstalled = Self.isHelperInstalled()
        checkForUpdate()
    }

    /// Compare the installed daemon against the bundled one. No-op (false) when
    /// not installed via the fallback (no file at daemonDst) or when either copy
    /// can't be read — drift can only be asserted when both are present.
    func checkForUpdate() {
        guard isInstalled,
              let bundled = try? Data(contentsOf: URL(fileURLWithPath: Self.bundledDaemonPath)),
              let installed = try? Data(contentsOf: URL(fileURLWithPath: Self.daemonDst))
        else { needsUpdate = false; return }
        needsUpdate = bundled != installed
    }

    /// Re-copy the bundled daemon over the installed one and restart it. Uses the
    /// same privileged osascript path as the fallback install.
    func update() {
        guard !isInstalling else { return }
        isInstalling = true
        installError = nil

        Task.detached {
            let err = DaemonManager.performOsascriptInstall(
                daemonSrc: Self.bundledDaemonPath, user: NSUserName()
            )
            await MainActor.run { [weak self] in
                self?.isInstalling = false
                if let err { self?.installError = err }
                else       { self?.autoEnableHooksOnFirstInstall() }
                self?.checkForUpdate()
            }
        }
    }

    // MARK: — Public actions

    /// One-time: the first time the helper installs successfully, turn on the
    /// Claude Code heartbeat hooks automatically. They are now the ONLY signal
    /// that makes the daemon keep the Mac awake, so a fresh install should work
    /// without the user hunting for a toggle. We record a flag and never force
    /// them again — so a user who later turns the hooks off (or reinstalls /
    /// updates) keeps their choice. Best-effort: a malformed ~/.claude/settings.json
    /// just leaves the hooks off rather than blocking the install.
    private func autoEnableHooksOnFirstInstall() {
        let key = "didAutoEnableClaudeHooks"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? ClaudeHooks.setEnabled(true)
    }

    /// One-time: register the app as a login item on first install. Done silently
    /// — we do NOT redirect to System Settings the way the Settings toggle does,
    /// since stacking that on top of the install auth prompt is jarring. For most
    /// users the item lands enabled; those macOS puts in .requiresApproval can flip
    /// it themselves in Login Items. The flag means a later manual toggle-off is
    /// respected and never re-forced (same contract as Claude hooks above).
    private func autoEnableLoginItemOnFirstInstall() {
        let key = "didAutoEnableLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }

    func install() { runInstallOrRepair(reason: "install", enableHooks: true) }

    /// Install or repair the helper. One privileged step copies the daemon to
    /// /usr/local/lib, writes a classic LaunchDaemon plist, and (re)loads it via
    /// launchctl — the path that actually runs our Python daemon. We do NOT use
    /// SMAppService.register() (it can't spawn a script), but we DO unregister any
    /// stale SMAppService job first: an earlier build registered one, and that
    /// smd-managed, spawn-failing job is what launchctl couldn't control and hung
    /// trying to "restart." Used by both Install and Restart Helper, so a broken
    /// or half-removed install is repaired the same way it's created.
    private func runInstallOrRepair(reason: String, enableHooks: Bool) {
        guard !isInstalling else { return }
        isInstalling = true
        installError = nil

        DaemonManager.appLog("\(reason)(): begin")
        Task.detached {
            let service = SMAppService.daemon(plistName: Self.plistName)
            if service.status != .notRegistered {
                DaemonManager.appLog("\(reason)(): unregistering stale SMAppService daemon (status=\(service.status.rawValue))")
                try? await service.unregister()
            }
            let err = DaemonManager.performOsascriptInstall(
                daemonSrc: Self.bundledDaemonPath, user: NSUserName()
            )
            DaemonManager.appLog("\(reason)(): performOsascriptInstall err=\(err ?? "<nil>")")
            await MainActor.run { [weak self] in
                self?.isInstalling = false
                if let err { self?.installError = err }
                else {
                    self?.isInstalled = true
                    if enableHooks {
                        self?.autoEnableHooksOnFirstInstall()
                        self?.autoEnableLoginItemOnFirstInstall()
                    }
                }
                self?.checkForUpdate()
            }
        }
    }

    func uninstall() {
        guard !isInstalling else { return }
        isInstalling = true
        installError = nil

        DaemonManager.appLog("uninstall(): begin")
        Task.detached {
            // Unregister any stale SMAppService registration from older builds.
            let service = SMAppService.daemon(plistName: Self.plistName)
            if service.status != .notRegistered {
                try? await service.unregister()
            }

            // Remove the launchctl-installed plist + binary (prompts for auth).
            let err: String? = FileManager.default.fileExists(atPath: Self.plistPath)
                ? DaemonManager.performOsascriptUninstall()
                : nil
            DaemonManager.appLog("uninstall(): performOsascriptUninstall err=\(err ?? "<nil>")")

            await MainActor.run { [weak self] in
                self?.isInstalling = false
                // Reflect reality: if the user cancelled the auth dialog (or it
                // failed), the files are still there, so we're still installed.
                // Don't flash "Not installed" for an uninstall that didn't happen.
                self?.isInstalled = Self.isHelperInstalled()
                self?.needsUpdate = false
                if let err, err != "Installation cancelled." {
                    self?.installError = err
                }
            }
        }
    }

    /// Restart the helper when it's installed but not reporting status (crashed,
    /// unloaded, wedged, or files partially removed). Implemented as a full
    /// repair (re-copy + reload) rather than a bare `launchctl kickstart`: kickstart
    /// hangs on a broken/smd-managed job, and a repair also fixes missing files.
    func restart() { runInstallOrRepair(reason: "restart", enableHooks: false) }

    // MARK: — Osascript install / uninstall

    // A bash timeout wrapper injected into every privileged script: runs a
    // command with a hard 20s cap so a wedged or orphaned launchd job (e.g. a
    // spawn-failing SMAppService daemon) can never hang launchctl indefinitely.
    // This is the source-level guard; runPrivilegedScript's 120s watchdog is the
    // outer backstop.
    nonisolated private static let bashTimeoutFn = """
    lc() {
        "$@" & local p=$!
        ( sleep 20; /bin/kill -9 "$p" 2>/dev/null ) & local w=$!
        local rc=0
        wait "$p" 2>/dev/null || rc=$?
        /bin/kill "$w" 2>/dev/null || true
        return $rc
    }
    """

    nonisolated private static func performOsascriptInstall(daemonSrc: String, user: String) -> String? {
        let tmpPlist = tmpFile(suffix: ".plist")
        guard (try? fallbackPlist.write(to: tmpPlist, atomically: true, encoding: .utf8)) != nil else {
            return "Failed to create temporary plist file."
        }
        defer { try? FileManager.default.removeItem(at: tmpPlist) }

        let defaultConfig = #"{"grace_period_seconds":90,"poll_interval_seconds":10,"allow_battery":false,"thermal_cutoff":50,"heartbeat_window_seconds":180,"sleep_when_lid_closed":true,"lid_input_quiet_seconds":300}"#

        let script = """
        #!/bin/bash
        set -e
        \(bashTimeoutFn)

        # --- Migrate from the old 'lunation' install, if present ---
        OLD_PLIST=/Library/LaunchDaemons/com.lunation.daemon.plist
        lc /bin/launchctl bootout 'system/\(label)' 2>/dev/null \
            || lc /bin/launchctl unload "$OLD_PLIST" 2>/dev/null || true
        # Reset sleep state before tearing the old daemon down, so a stale
        # disablesleep can never be left stuck once it's gone.
        /usr/bin/pmset -a disablesleep 0 2>/dev/null || true
        /bin/rm -f "$OLD_PLIST"
        /bin/rm -rf /usr/local/lib/lunation

        /bin/mkdir -p /usr/local/lib/lunation '\(configDir)'
        /usr/sbin/chown '\(user)' '\(configDir)'
        # Carry over the user's old config (allow_battery, thresholds, …) on first install.
        if [ ! -f '\(configDir)/config.json' ] && [ -f /etc/lunation/config.json ]; then
            /bin/cp /etc/lunation/config.json '\(configDir)/config.json'
            /usr/sbin/chown '\(user)' '\(configDir)/config.json'
        fi

        /bin/cp '\(daemonSrc)' '\(daemonDst)'
        /bin/chmod 755 '\(daemonDst)'
        if [ ! -f '\(configDir)/config.json' ]; then
            /usr/bin/printf '%s' '\(defaultConfig)' > '\(configDir)/config.json'
        fi
        lc /bin/launchctl bootout 'system/\(label)' 2>/dev/null \
            || lc /bin/launchctl unload '\(plistPath)' 2>/dev/null || true
        /bin/cp '\(tmpPlist.path)' '\(plistPath)'
        /bin/chmod 644 '\(plistPath)'
        /usr/sbin/chown root:wheel '\(plistPath)'
        lc /bin/launchctl enable 'system/\(label)' 2>/dev/null || true
        lc /bin/launchctl bootstrap system '\(plistPath)' 2>/dev/null \
            || lc /bin/launchctl load -w '\(plistPath)'
        """
        return runPrivilegedScript(script)
    }

    nonisolated private static func performOsascriptUninstall() -> String? {
        let script = """
        #!/bin/bash
        \(bashTimeoutFn)
        /usr/bin/pmset -a disablesleep 0 2>/dev/null || true
        lc /bin/launchctl bootout 'system/\(label)' 2>/dev/null \
            || lc /bin/launchctl unload '\(plistPath)' 2>/dev/null || true
        /bin/rm -f '\(plistPath)'
        /bin/rm -rf /usr/local/lib/lunation
        """
        return runPrivilegedScript(script)
    }

    nonisolated private static func runPrivilegedScript(_ script: String) -> String? {
        let tmp = tmpFile(suffix: ".sh")
        do {
            try script.write(to: tmp, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: tmp.path
            )
        } catch {
            return "Failed to write script: \(error.localizedDescription)"
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        let escaped = tmp.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = #"do shell script "bash \"\#(escaped)\"" with administrator privileges"#

        // Run the admin-auth AppleScript in a SEPARATE `osascript` process, not
        // in-process via NSAppleScript. In-process, `do shell script … with
        // administrator privileges` deadlocks: Authorization Services needs a
        // pumping run loop to present the SecurityAgent dialog, but
        // executeAndReturnError blocks its thread synchronously — on a background
        // thread there's no run loop, and on the main thread the run loop it
        // needs is the one we just blocked. Either way the dialog never appears
        // and it hangs (and a force-quit then SIGTERMs the privileged child).
        // A child osascript process has its own run loop, so the dialog shows
        // normally; this (background) thread just blocks waiting on it.
        appLog("runPrivilegedScript: launching osascript for admin auth")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", appleScript]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()   // discard the script's own stdout
        do {
            try proc.run()
        } catch {
            appLog("runPrivilegedScript: launch FAILED: \(error.localizedDescription)")
            return "Failed to launch osascript: \(error.localizedDescription)"
        }
        appLog("runPrivilegedScript: osascript pid=\(proc.processIdentifier); waiting (watchdog 120s)")

        // Watchdog: a privileged step must NEVER hang the UI forever. If the auth
        // dialog or the script doesn't finish in the window, kill it and surface
        // an error so isInstalling resets and the button recovers. 120s covers
        // password entry comfortably; only a real wedge waits it out.
        let deadline = Date().addingTimeInterval(120)
        while proc.isRunning {
            if Date() >= deadline {
                appLog("runPrivilegedScript: TIMEOUT — terminating pid=\(proc.processIdentifier)")
                proc.terminate()
                Thread.sleep(forTimeInterval: 1)
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                return "The privileged step timed out (no response after 120s). "
                     + "Try again, or reinstall the helper."
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        let status = proc.terminationStatus
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        let msg = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        appLog("runPrivilegedScript: osascript exited status=\(status) stderr=\(msg.isEmpty ? "<empty>" : msg)")

        if status == 0 { return nil }
        // Cancel in the auth dialog surfaces as AppleScript error -128.
        if msg.contains("-128") || msg.localizedCaseInsensitiveContains("cancel") {
            return "Installation cancelled."
        }
        return msg.isEmpty ? "Privileged operation failed (status \(status))." : msg
    }

    /// Best-effort append-only log to /tmp/lunation-app.log so the install /
    /// restart flow can be traced from outside Xcode (`cat /tmp/lunation-app.log`).
    nonisolated private static func appLog(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        let path = "/tmp/lunation-app.log"
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        guard let fh = FileHandle(forWritingAtPath: path) else { return }
        defer { try? fh.close() }
        fh.seekToEndOfFile()
        if let d = line.data(using: .utf8) { fh.write(d) }
    }

    nonisolated private static func tmpFile(suffix: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lunation-\(UUID().uuidString)\(suffix)")
    }
}
