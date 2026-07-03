import SwiftUI

struct MenuBarView: View {
    @Environment(StatusMonitor.self) private var monitor
    @Environment(DaemonManager.self) private var daemon
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    @State private var forceError: String?
    @State private var pendingForce: Bool? = nil

    @State private var claudeHooksEnabled = false
    @State private var claudeNudgeError: String?
    @AppStorage("claudeNudgeDismissed") private var claudeNudgeDismissed = false

    // First-run nudge: surface the more-reliable Claude Code heartbeat detection
    // in the menu (not just Settings) while it's off, so a user who never opens
    // Settings still discovers it. Vanishes for good once enabled (here or in
    // Settings) or dismissed.
    private var showClaudeNudge: Bool {
        daemon.isInstalled && monitor.daemonConnected
            && !claudeHooksEnabled && !claudeNudgeDismissed
    }

    private var effectiveForceAwake: Bool { pendingForce ?? monitor.status.forceAwake }
    private var awaitingConfirmation: Bool {
        guard let p = pendingForce else { return false }
        return p != monitor.status.forceAwake
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !daemon.isInstalled {
                setupSection
            } else if !monitor.daemonConnected {
                if daemon.needsUpdate { updateBanner; Divider() }
                notRespondingSection
            } else {
                if daemon.needsUpdate { updateBanner; Divider() }
                statusSection
                if showClaudeNudge {
                    Divider()
                    claudeNudgeSection
                }
                if let err = forceError {
                    Text(err).font(.caption).foregroundStyle(.red)
                        .padding(.horizontal, 12).padding(.bottom, 4)
                }
                Divider()
                forceSection
            }

            Divider()
            menuButton("Settings") {
                dismiss()
                // Promote from agent to regular app and activate BEFORE opening,
                // so the Settings window opens into the now-foreground app and
                // lands in front. Doing this on every click is what fixes reopens:
                // the window is reused, so makeNSView won't re-run and the
                // becomeKey fallback doesn't fire when it opens behind. Reverts to
                // .accessory on window close (see ActiveSpaceConfigurator).
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            .padding(.top, 4)
            menuButton("Quit") { NSApplication.shared.terminate(nil) }
        }
        .frame(width: 240)
        .padding(.bottom, 4)
        .onAppear {
            daemon.refreshInstalled()
            claudeHooksEnabled = ClaudeHooks.isEnabled()
        }
        .onChange(of: monitor.status.forceAwake) { _, confirmed in
            if confirmed == pendingForce { pendingForce = nil }
        }
    }

    // MARK: — Update banner

    // Installed helper differs from the bundled one (app updated, helper not).
    private var updateBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                Text("Helper update available").fontWeight(.medium)
            }
            .padding(.horizontal, 12).padding(.top, 10)

            Text("The installed helper differs from this app's version.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)

            menuButton(daemon.isInstalling ? "Updating…" : "Update Helper") {
                daemon.update()
            }
            .disabled(daemon.isInstalling)
            .padding(.bottom, 2)
        }
    }

    // MARK: — Claude Code detection nudge

    private var claudeNudgeSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "moon.stars.fill").foregroundStyle(.blue)
                Text("Enable Claude Code detection").fontWeight(.medium)
                Spacer()
                Button { claudeNudgeDismissed = true } label: {
                    Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(.horizontal, 12).padding(.top, 10)

            Text("Signals activity directly via Claude Code hooks — this is how "
                 + "Lunation detects work and keeps your Mac awake.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)

            if let err = claudeNudgeError {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
            }

            menuButton("Enable") { enableClaudeHooks() }
                .padding(.bottom, 2)
        }
    }

    // MARK: — Setup section

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                Text("Helper not installed").fontWeight(.medium)
            }
            .padding(.horizontal, 12).padding(.top, 10)

            if let err = daemon.installError {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
            }

            menuButton(daemon.isInstalling ? "Installing…" : "Install Helper") {
                daemon.install()
            }
            .disabled(daemon.isInstalling)
            .padding(.bottom, 2)
        }
    }

    // MARK: — Not-responding section

    // Installed, but the daemon isn't reporting fresh status. Offer a repair
    // action instead of a dead-end "Daemon not running" with disabled controls.
    private var notRespondingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text("Helper not responding").fontWeight(.medium)
            }
            .padding(.horizontal, 12).padding(.top, 10)

            Text("The helper is installed but isn’t reporting status.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12)

            if let err = daemon.installError {
                Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
            }

            menuButton(daemon.isInstalling ? "Restarting…" : "Restart Helper") {
                daemon.restart()
            }
            .disabled(daemon.isInstalling)
            .padding(.bottom, 2)
        }
    }

    // MARK: — Status section

    private var statusSection: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(monitor.statusColor)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(monitor.statusLabel).fontWeight(.medium)
                if monitor.status.thermalTrip {
                    Label("Sleeping to cool down", systemImage: "thermometer.high")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.top, 8)
    }

    // MARK: — Force-awake section

    @ViewBuilder
    private var forceSection: some View {
        if awaitingConfirmation {
            // Pending — show spinner while daemon processes the intent
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(pendingForce == true ? "Enabling…" : "Stopping…")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        } else if effectiveForceAwake {
            activeForceRow
        } else {
            inactiveForcePicker
        }
    }

    // Force is active — show countdown (if timed) and a Stop button.
    private var activeForceRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Forced awake").fontWeight(.medium)
                    // Timed override: drive a 1s ticker so the countdown updates
                    // smoothly instead of jumping with the ~10s status poll.
                    if monitor.forceAwakeTimeRemaining != nil {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            if let remaining = monitor.forceAwakeTimeRemaining {
                                Text(formatRemaining(remaining))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)

                Spacer()

                Button("Stop") { setForce(false) }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 12)
                    .disabled(!monitor.daemonConnected)
            }

            // Forcing awake on battery means a closed Mac can't shed heat.
            if !monitor.status.onAC {
                Label(
                    "On battery — a closed Mac may overheat. Keep it ventilated.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Force is inactive — a row of evenly-sized duration pills.
    private var inactiveForcePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Force awake for")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12)

            HStack(spacing: 6) {
                durationPill("1h", help: "1 hour")          { setForce(true, hours: 1) }
                durationPill("2h", help: "2 hours")         { setForce(true, hours: 2) }
                durationPill("8h", help: "8 hours")         { setForce(true, hours: 8) }
                durationPill(systemImage: "calendar",
                             help: "Until tomorrow morning") { setForce(true, untilTomorrow: true) }
                durationPill("∞", help: "Indefinitely")     { setForce(true) }
            }
            .padding(.horizontal, 12)

            // Desktop Claude is mostly server-side and writes no heartbeat, so
            // auto-detection (CLI-only) can't see it — point those users here.
            // Label(
                // "Desktop Claude (Cowork, Chat, Code) can’t be auto-detected — use this for those sessions. Or just to force awake for a while.",
                // systemImage: "info.circle"
            // )
            // .labelStyle(.titleAndIcon)
            // .font(.caption2).foregroundStyle(.secondary)
            // .fixedSize(horizontal: false, vertical: true)
            // .padding(.horizontal, 12).padding(.top, 2)
        }
        .padding(.vertical, 8)
        .disabled(!monitor.daemonConnected)
    }

    @ViewBuilder
    private func durationPill(_ label: String? = nil, systemImage: String? = nil,
                              help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let systemImage { Image(systemName: systemImage) }
                else if let label  { Text(label) }
            }
            .font(.caption.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 26)
            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: — Actions

    private func setForce(_ on: Bool, hours: Double = 0, untilTomorrow: Bool = false) {
        pendingForce = on
        forceError = nil
        let expiresAt: Date?
        if on && hours > 0 {
            expiresAt = Date().addingTimeInterval(hours * 3600)
        } else if on && untilTomorrow {
            expiresAt = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400))
        } else {
            expiresAt = nil
        }
        do {
            try IntentWriter.setForceAwake(on, expiresAt: expiresAt)
            Task { @MainActor in
                for _ in 0..<15 {
                    try? await Task.sleep(for: .seconds(1))
                    monitor.refresh()
                    guard pendingForce != nil else { break }
                }
                pendingForce = nil
            }
        } catch {
            pendingForce = nil
            forceError = "Could not write intent: \(error.localizedDescription)"
        }
    }

    private func enableClaudeHooks() {
        claudeNudgeError = nil
        do {
            try ClaudeHooks.setEnabled(true)
            claudeHooksEnabled = true   // hides the nudge; mirrors Settings' toggle
        } catch {
            claudeNudgeError = error.localizedDescription
        }
    }

    // MARK: — Helpers

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m remaining" }
        if m > 0 { return "\(m)m \(s)s remaining" }
        return "\(s)s remaining"
    }

    @ViewBuilder
    private func menuButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
