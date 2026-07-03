import Foundation
import Observation

@Observable @MainActor
final class ConfigStore {
    var gracePeriod: Int          = 90
    var pollInterval: Int         = 10
    var allowBattery: Bool        = false
    var thermalCutoff: Int        = 50    // CPU speed-limit % at/below which to force sleep; 0 disables
    var heartbeatWindow: Int      = 180   // seconds a Claude Code heartbeat counts as active; 0 disables

    @ObservationIgnored private let configPath = URL(fileURLWithPath: "/etc/lunation/config.json")

    /// All persisted values combined into one Equatable value, so the view can
    /// watch a single thing (`.onChange`) and auto-save on any edit. Reading the
    /// observable properties here makes SwiftUI re-evaluate it as the user edits.
    var changeToken: String {
        "\(gracePeriod)|\(pollInterval)|\(allowBattery)|\(thermalCutoff)|\(heartbeatWindow)"
    }

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        gracePeriod     = json["grace_period_seconds"]      as? Int    ?? gracePeriod
        pollInterval    = json["poll_interval_seconds"]     as? Int    ?? pollInterval
        allowBattery    = json["allow_battery"]             as? Bool   ?? allowBattery
        thermalCutoff   = json["thermal_cutoff"]            as? Int    ?? thermalCutoff
        heartbeatWindow = json["heartbeat_window_seconds"]  as? Int    ?? heartbeatWindow
    }

    func save() throws {
        // Start from whatever is on disk so keys the app doesn't manage —
        // anything a future daemon version adds — survive a save instead of
        // being clobbered by a whole-file replace. We overwrite only the keys
        // we own below.
        var payload: [String: Any] = {
            guard let data = try? Data(contentsOf: configPath),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return json
        }()

        payload["grace_period_seconds"]     = gracePeriod
        payload["poll_interval_seconds"]    = pollInterval
        payload["allow_battery"]            = allowBattery
        payload["thermal_cutoff"]           = thermalCutoff
        payload["heartbeat_window_seconds"] = heartbeatWindow
        // Detection is heartbeat-only now; strip any process-match keys a prior
        // install (or the old installer's seed config) may have left behind.
        payload.removeValue(forKey: "process_patterns")
        payload.removeValue(forKey: "process_pattern")
        payload.removeValue(forKey: "cpu_threshold")

        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: configPath, options: .atomic)
    }
}

/// Manages the Lunation heartbeat hooks in the user's Claude Code settings
/// (`~/.claude/settings.json`). When enabled, Claude Code touches the heartbeat
/// file as it works so the daemon counts it as active (OR'd with the CPU
/// heuristic, and reliable through long model-thinking pauses). Our entries are
/// identified by the heartbeat path in the command, so enable/disable only
/// touches our hooks and leaves the user's other hooks intact.
enum ClaudeHooks {
    static let heartbeatPath = "/etc/lunation/heartbeat"
    // Old path from the 'lunation' name; recognized so enabling cleanly replaces
    // a pre-rename install's hooks instead of leaving them behind.
    private static let legacyHeartbeatPath = "/etc/lunation/heartbeat"
    private static let touchCmd = "touch \(heartbeatPath)"
    private static let clearCmd = "rm -f \(heartbeatPath)"

    // (event, optional tool matcher, command). UserPromptSubmit/PostToolUse mark
    // activity; Stop clears the heartbeat so the daemon idles promptly.
    private static let specs: [(event: String, matcher: String?, command: String)] = [
        ("UserPromptSubmit", nil, touchCmd),
        ("PostToolUse",      "*", touchCmd),
        ("Stop",             nil, clearCmd),
    ]

    private static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// True if any of our heartbeat hooks are present. Lenient: an unreadable or
    /// missing file just reads as "not enabled".
    static func isEnabled() -> Bool {
        guard let root = try? loadSettings(),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        // Reflect the *current* path. A stale legacy-only config reads as off, so
        // re-enabling rewrites it to the new path.
        return specs.contains { spec in
            (hooks[spec.event] as? [[String: Any]])?
                .contains { groupReferences($0, [heartbeatPath]) } ?? false
        }
    }

    /// Add (or remove) our heartbeat hooks, preserving everything else. Throws
    /// rather than overwriting if the existing file isn't a JSON object.
    static func setEnabled(_ on: Bool) throws {
        var root = try loadSettings() ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]

        for spec in specs {
            var groups = hooks[spec.event] as? [[String: Any]] ?? []
            // Drop any prior copy of ours — current OR legacy path — so this is
            // idempotent and migrates a pre-rename install.
            groups.removeAll { groupReferences($0, [heartbeatPath, legacyHeartbeatPath]) }
            if on {
                var group: [String: Any] = [
                    "hooks": [["type": "command", "command": spec.command]]
                ]
                if let m = spec.matcher { group["matcher"] = m }
                groups.append(group)
            }
            if groups.isEmpty { hooks.removeValue(forKey: spec.event) }
            else              { hooks[spec.event] = groups }
        }

        if hooks.isEmpty { root.removeValue(forKey: "hooks") }
        else             { root["hooks"] = hooks }

        try FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    // MARK: — helpers

    /// Returns nil if the file is absent; throws if present but not a JSON object
    /// (so setEnabled won't clobber a hand-edited file it can't understand).
    private static func loadSettings() throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return nil }
        let data = try Data(contentsOf: settingsURL)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Lunation", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "~/.claude/settings.json isn’t a JSON object — edit it by hand instead."])
        }
        return obj
    }

    private static func groupReferences(_ group: [String: Any], _ paths: [String]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { hook in
            guard let cmd = hook["command"] as? String else { return false }
            return paths.contains { cmd.contains($0) }
        }
    }
}
