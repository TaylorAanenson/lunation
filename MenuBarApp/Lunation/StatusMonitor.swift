import Combine
import Foundation
import Observation
import SwiftUI

struct DaemonStatus: Codable {
    var state: String
    var sleepDisabled: Bool
    var forceAwake: Bool
    var timestamp: Double
    var consecutiveBelow: Double = 0
    var gracePeriod: Int = 90
    var expiresAt: Double?
    var onAC: Bool = true
    var thermalTrip: Bool = false

    enum CodingKeys: String, CodingKey {
        case state, timestamp
        case sleepDisabled     = "sleep_disabled"
        case forceAwake        = "force_awake"
        case consecutiveBelow  = "consecutive_below"
        case gracePeriod       = "grace_period"
        case expiresAt         = "expires_at"
        case onAC              = "on_ac"
        case thermalTrip       = "thermal_trip"
    }

    static let disconnected = DaemonStatus(
        state: "disconnected", sleepDisabled: false, forceAwake: false, timestamp: 0
    )
}

extension DaemonStatus {
    // Custom decoder so fields the daemon may omit (added in a later daemon
    // version, or not relevant this poll) fall back to defaults instead of
    // failing the whole decode. Swift's synthesized Codable throws keyNotFound
    // for a missing non-optional key *even when it has a default value*, which
    // would make a running-but-older daemon look "not running" in the app.
    // Only the four fields every daemon version always writes are required.
    // Declared in an extension so the memberwise init (used by `.disconnected`)
    // is still synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            state:            try c.decode(String.self, forKey: .state),
            sleepDisabled:    try c.decode(Bool.self, forKey: .sleepDisabled),
            forceAwake:       try c.decode(Bool.self, forKey: .forceAwake),
            timestamp:        try c.decode(Double.self, forKey: .timestamp),
            consecutiveBelow: try c.decodeIfPresent(Double.self, forKey: .consecutiveBelow) ?? 0,
            gracePeriod:      try c.decodeIfPresent(Int.self, forKey: .gracePeriod) ?? 90,
            expiresAt:        try c.decodeIfPresent(Double.self, forKey: .expiresAt),
            onAC:             try c.decodeIfPresent(Bool.self, forKey: .onAC) ?? true,
            thermalTrip:      try c.decodeIfPresent(Bool.self, forKey: .thermalTrip) ?? false
        )
    }
}

/// The timer-driven shell around `MoonWalk`: steps the menu-bar moon one phase
/// at a time toward a target illumination, so every state change *cycles through*
/// the intermediate phases instead of snapping. The grace state feeds a target
/// derived from how far through the wind-down it is, so the wane tracks real
/// progress. All the phase/lean logic lives in `MoonWalk` (see MoonPhase.swift).
@Observable @MainActor
final class MoonPhaseAnimator {
    /// The glyph currently shown in the menu bar.
    private(set) var symbol = "moonphase.new.moon"

    @ObservationIgnored private var walk = MoonWalk()
    @ObservationIgnored private var target = 0             // desired illumination 0…4
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let stepInterval = 0.45    // seconds per phase step (~1.8s end-to-end)

    /// Set the illumination the moon should settle on. If it differs from what's
    /// shown, the animator starts stepping one phase per `stepInterval` toward it.
    func setTarget(_ illumination: Int) {
        target = max(0, min(MoonPhase.full, illumination))
        if walk.displayed != target && timer == nil { start() }
    }

    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        if walk.step(toward: target) {
            symbol = walk.symbol
        } else {
            stop()
        }
    }
}

@Observable @MainActor
final class StatusMonitor {
    var status = DaemonStatus.disconnected
    var daemonConnected = false

    @ObservationIgnored private var timer: AnyCancellable?
    @ObservationIgnored private let statusPath = URL(fileURLWithPath: "/var/run/lunation.status.json")
    @ObservationIgnored private var lastSleepDisabled: Bool? = nil
    @ObservationIgnored let moon = MoonPhaseAnimator()

    // Status glyph: the moon waxes awake and wanes back to sleep, so the visual
    // fill tracks sleep state — new moon = free to sleep, full moon = held awake,
    // the partial phases = a live transition between the two (driven by `moon`).
    var menuBarIcon: String {
        guard daemonConnected else { return "moonphase.new.moon" }   // daemon down — off the cycle
        return moon.symbol
    }

    /// How far through the wind-down grace period we are, 0 (just entered) … 1
    /// (about to go idle). Drives the wane so the phase reflects real progress.
    private var graceProgress: Double {
        guard status.gracePeriod > 0 else { return 1 }
        return min(1, max(0, status.consecutiveBelow / Double(status.gracePeriod)))
    }

    /// Translate the daemon's state into a target illumination for the animator.
    /// Grace wanes from full toward new across the grace period; otherwise the
    /// moon is full whenever sleep is actually being held off, new when the Mac
    /// is free to sleep. Force-awake holds full via `sleepDisabled`.
    private func updateMoon() {
        if status.state == "grace" && !status.forceAwake {
            let level = Int(((1 - graceProgress) * Double(MoonPhase.full)).rounded())
            moon.setTarget(level)
        } else if status.sleepDisabled {
            moon.setTarget(MoonPhase.full)
        } else {
            moon.setTarget(0)
        }
    }

    var statusLabel: String {
        guard daemonConnected else { return "Daemon not running" }
        if status.forceAwake { return "Forced awake" }
        switch status.state {
        case "working": return "Claude Code active"
        case "grace":
            if let secs = graceSecondsRemaining, secs > 0 { return "Winding down… ~\(secs)s" }
            return "Winding down…"
        default: return "Idle"
        }
    }

    var graceSecondsRemaining: Int? {
        guard status.state == "grace", status.gracePeriod > 0 else { return nil }
        return max(0, status.gracePeriod - Int(status.consecutiveBelow))
    }

    /// Remaining seconds on a timed force-awake. Nil when indefinite or force is off.
    var forceAwakeTimeRemaining: TimeInterval? {
        guard status.forceAwake, let expires = status.expiresAt else { return nil }
        let remaining = expires - Date().timeIntervalSince1970
        return max(0, remaining)
    }

    var statusColor: Color {
        guard daemonConnected else { return .secondary }
        if status.forceAwake   { return .orange }
        switch status.state {
        case "working": return .green
        case "grace":   return .yellow
        default:        return .secondary
        }
    }

    init() {
        timer = Timer.publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    func refresh() {
        // Report current OS thermal state for the daemon's thermal cutoff. Done
        // on the same 5s cadence; the daemon treats a hint older than 30s as
        // nominal, so this comfortably keeps it fresh while the app is running.
        ThermalReporter.report()

        guard let data = try? Data(contentsOf: statusPath),
              let decoded = try? JSONDecoder().decode(DaemonStatus.self, from: data),
              Date().timeIntervalSince1970 - decoded.timestamp < 60
        else {
            status = .disconnected
            daemonConnected = false
            lastSleepDisabled = nil
            return
        }
        status = decoded
        daemonConnected = true
        updateMoon()
        notifyIfNeeded(sleepDisabled: decoded.sleepDisabled, forceAwake: decoded.forceAwake)
    }

    private func notifyIfNeeded(sleepDisabled: Bool, forceAwake: Bool) {
        defer { lastSleepDisabled = sleepDisabled }
        guard let last = lastSleepDisabled, last != sleepDisabled else { return }
        guard UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true else { return }
        if sleepDisabled {
            NotificationSender.send(
                title: "Keeping your Mac awake",
                body: forceAwake ? "Sleep is manually suppressed" : "A monitored process is active"
            )
        } else {
            NotificationSender.send(
                title: "Your Mac can sleep again",
                body: "Monitored processes have gone idle"
            )
        }
    }
}
