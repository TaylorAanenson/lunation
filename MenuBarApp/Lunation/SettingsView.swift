import AppKit
import ServiceManagement
import SwiftUI

private struct ActiveSpaceConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.collectionBehavior.insert(.moveToActiveSpace)
            // Transparent background lets the glass sections show the desktop through them.
            window.isOpaque = false
            // window.backgroundColor = .clear
            context.coordinator.observe(window)
            // First open: makeNSView runs once, possibly after the window has
            // already become key, so the observer below could miss that event —
            // pull it to the front explicitly here too.
            window.makeKeyAndOrderFront(nil)
            Coordinator.bringToFront(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class Coordinator {
        private var keyObservation: NSObjectProtocol?
        private var closeObservation: NSObjectProtocol?

        func observe(_ window: NSWindow) {
            // Reopens: the Settings window is reused, so makeNSView won't run
            // again — but it becomes key each time it's shown. Lift it then.
            keyObservation = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { _ in Coordinator.bringToFront(window) }

            // Drop back to a background agent once Settings closes, so the Dock
            // icon we add below doesn't linger.
            closeObservation = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in NSApp.setActivationPolicy(.accessory) }
        }

        /// Pull the Settings window above whatever is currently frontmost. We run
        /// as an LSUIElement (agent) app, which macOS forbids from stealing focus
        /// — so activating/ordering-front alone leaves the window *behind* the
        /// foreground app. Temporarily promoting to `.regular` lets activation
        /// actually take, bringing the window to the front (and adding a Dock icon
        /// for the moment Settings is open; reverted on close, above).
        static func bringToFront(_ window: NSWindow) {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }

        deinit {
            keyObservation.map { NotificationCenter.default.removeObserver($0) }
            closeObservation.map { NotificationCenter.default.removeObserver($0) }
        }
    }
}

struct SettingsView: View {
    @Environment(DaemonManager.self) private var daemon
    @State private var config      = ConfigStore()
    @State private var saveError:  String?
    @State private var showSaved   = false
    @State private var loginError: String?
    @State private var claudeHooksEnabled = false
    @State private var hooksError: String?
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                glassSection("Claude Code") {
                    Toggle("Keep awake while Claude Code is working", isOn: claudeHooksBinding)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    sectionDivider()
                    Text(verbatim: "Adds heartbeat hooks to ~/.claude/settings.json so Claude Code signals activity directly. This is how Lunation detects work — with it off, only Force Awake keeps your Mac up. Leaves your other hooks untouched.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                    sectionDivider()
                    row("Heartbeat window") {
                        HStack(spacing: 4) {
                            TextField("", value: $config.heartbeatWindow, format: .number)
                                .frame(width: 52).multilineTextAlignment(.trailing)
                            Text("seconds").foregroundStyle(.secondary)
                        }
                    }
                    // Only meaningful once the hooks are writing heartbeats; grey it
                    // out otherwise so it doesn't read as an active knob.
                    .disabled(!claudeHooksEnabled)
                    .opacity(claudeHooksEnabled ? 1 : 0.5)
                    sectionDivider()
                    Label(
                        "Detection works only for the Claude Code CLI. The Claude "
                        + "desktop app (Cowork, Chat, Code) can’t be detected — use “Force "
                        + "awake” in the menu for those sessions.",
                        systemImage: "info.circle"
                    )
                    .labelStyle(.titleAndIcon)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    if let err = hooksError {
                        sectionDivider()
                        Label(err, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red).font(.callout)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }

                glassSection("Timing") {
                    row("Grace period") {
                        HStack(spacing: 4) {
                            TextField("", value: $config.gracePeriod, format: .number)
                                .frame(width: 52).multilineTextAlignment(.trailing)
                            Text("seconds").foregroundStyle(.secondary)
                        }
                    }
                    Text("How long to keep the Mac awake after Claude Code goes quiet, so "
                         + "short pauses between prompts or turns don’t let it sleep mid-session.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                    sectionDivider()
                    row("Poll interval") {
                        HStack(spacing: 4) {
                            TextField("", value: $config.pollInterval, format: .number)
                                .frame(width: 52).multilineTextAlignment(.trailing)
                            Text("seconds").foregroundStyle(.secondary)
                        }
                    }
                    Text("How often the helper checks for activity. Lower reacts faster; "
                         + "higher is lighter on the system.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                }

                glassSection("Power") {
                    Toggle("Allow on battery", isOn: $config.allowBattery)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    if config.allowBattery {
                        sectionDivider()
                        Label(
                            "A closed Mac on battery can overheat. Keep it ventilated.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .font(.callout)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    sectionDivider()
                    row("Thermal cutoff") {
                        HStack(spacing: 4) {
                            TextField("", value: $config.thermalCutoff, format: .number)
                                .frame(width: 52).multilineTextAlignment(.trailing)
                            Text("%").foregroundStyle(.secondary)
                        }
                    }
                    Text("Force sleep if macOS throttles the CPU to this speed limit or "
                         + "below — protects a closed Mac under load. 0 disables.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                }

                glassSection("Notifications") {
                    Toggle("Notify on sleep state changes", isOn: $notificationsEnabled)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }

                glassSection("Startup") {
                    Toggle("Launch at login", isOn: launchAtLoginBinding)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    if let err = loginError {
                        sectionDivider()
                        Label(err, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red).font(.callout)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                }

                glassSection("Helper daemon") {
                    row("Status") {
                        Text(daemon.isInstalled ? "Installed" : "Not installed")
                            .foregroundStyle(daemon.isInstalled ? .primary : .secondary)
                    }
                    if let err = daemon.installError {
                        sectionDivider()
                        Label(err, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                    }
                    sectionDivider()
                    HStack(spacing: 8) {
                        Button(installButtonLabel) { daemon.install() }
                            .disabled(daemon.isInstalling)

                        if daemon.isInstalled {
                            Button("Uninstall") { daemon.uninstall() }
                                .disabled(daemon.isInstalling)
                                .foregroundStyle(.red)
                        }

                        Spacer()

                        Button("Open Logs") {
                            NSWorkspace.shared.open(
                                URL(fileURLWithPath: "/var/log/lunation-daemon.log")
                            )
                        }
                        .disabled(!FileManager.default.fileExists(
                            atPath: "/var/log/lunation-daemon.log"
                        ))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                if let err = saveError {
                    Label(err, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .padding(.horizontal, 4)
                }

                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    Text("Lunation \(version)")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                if showSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.opacity)
                } else {
                    Text("Changes are saved automatically")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .animation(.easeInOut(duration: 0.2), value: showSaved)
        }
        .frame(width: 400, height: 500)
        .background(ActiveSpaceConfigurator())
        .onAppear { claudeHooksEnabled = ClaudeHooks.isEnabled() }
        // Everything auto-saves: the config fields write /etc/lunation/config.json
        // on change; notifications persist via @AppStorage; the hooks toggle writes
        // ~/.claude/settings.json in its own setter. Each path flashes "Saved".
        .onChange(of: notificationsEnabled) { _, _ in flashSaved() }
        .onChange(of: config.changeToken) { _, _ in autosave() }
    }

    private var claudeHooksBinding: Binding<Bool> {
        Binding(
            get: { claudeHooksEnabled },
            set: { newValue in
                hooksError = nil
                do {
                    try ClaudeHooks.setEnabled(newValue)
                    claudeHooksEnabled = newValue
                    flashSaved()   // applied immediately — confirm it stuck
                } catch {
                    hooksError = error.localizedDescription
                    claudeHooksEnabled = ClaudeHooks.isEnabled()   // reflect real state
                }
            }
        )
    }

    // MARK: — Helpers

    private var installButtonLabel: String {
        if daemon.isInstalling { return "Working…" }
        return daemon.isInstalled ? "Reinstall" : "Install"
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            // .requiresApproval counts as "on": the login item IS registered, it's
            // just waiting for the user to approve it in System Settings. Treating
            // it as off made the toggle spring back and look broken.
            get: {
                switch SMAppService.mainApp.status {
                case .enabled, .requiresApproval: return true
                default:                          return false
                }
            },
            set: { enabled in
                loginError = nil
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                        // First registration usually lands in .requiresApproval —
                        // send the user straight to the Login Items pane to finish.
                        if SMAppService.mainApp.status == .requiresApproval {
                            loginError = "Approve “Lunation” under Login Items to finish enabling launch at login."
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    loginError = error.localizedDescription
                }
            }
        )
    }

    @ViewBuilder
    private func glassSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(in: .rect(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func row<Trailing: View>(
        _ label: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func sectionDivider() -> some View {
        Divider().padding(.leading, 16)
    }

    // MARK: —

    private func autosave() {
        saveError = nil
        do {
            try config.save()
            flashSaved()
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Briefly show the green "Saved" confirmation. Also used by the toggles that
    /// apply immediately (Claude Code hooks, notifications) — they don't go through
    /// the Save button, so this is the feedback that the change took effect.
    private func flashSaved() {
        showSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showSaved = false }
    }
}
