import Darwin
import Foundation

enum IntentWriter {
    private static let intentPath = URL(fileURLWithPath: "/etc/lunation/intent.json")
    private static let wakeFifo   = "/var/run/lunation.wake"

    static func setForceAwake(_ value: Bool, expiresAt: Date? = nil) throws {
        var dict: [String: Any] = ["force_awake": value]
        if value, let expires = expiresAt {
            dict["expires_at"] = expires.timeIntervalSince1970
        }
        let data = try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
        try data.write(to: intentPath, options: .atomic)
        wakeDaemon()
    }

    private static func wakeDaemon() {
        let fd = Darwin.open(wakeFifo, O_WRONLY | O_NONBLOCK)
        guard fd >= 0 else { return }
        var byte: UInt8 = 1
        _ = Darwin.write(fd, &byte, 1)
        Darwin.close(fd)
    }
}

/// Reports the macOS thermal state (`ProcessInfo.thermalState`) to a file the
/// daemon honors. This is the model-independent thermal signal that works on
/// both Apple Silicon and Intel — unlike `pmset -g therm`'s `CPU_Speed_Limit`,
/// which is absent on Apple Silicon. The daemon forces sleep on serious/critical
/// regardless of activity (see `read_thermal_hint` in the daemon) and keeps its
/// own `CPU_Speed_Limit` check as an Intel-only fallback, so the safety net
/// never depends solely on this app running.
enum ThermalReporter {
    private static let thermalPath = URL(fileURLWithPath: "/etc/lunation/thermal.json")

    static func levelString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:    return "nominal"
        case .fair:       return "fair"
        case .serious:    return "serious"
        case .critical:   return "critical"
        @unknown default: return "nominal"
        }
    }

    /// Write the current thermal state with a timestamp. Best-effort: failures
    /// (dir not yet created/chowned, etc.) are ignored. The daemon treats a
    /// missing or stale hint as nominal, so a missed write just means "no
    /// app-sourced cutoff this tick" — never a stuck-awake Mac.
    static func report() {
        let dict: [String: Any] = [
            "level": levelString(),
            "timestamp": Date().timeIntervalSince1970,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? data.write(to: thermalPath, options: .atomic)
    }
}
