import Foundation

/// Which half of the lunar cycle a transitional phase belongs to. New (0) and
/// full (4) look the same either way; the crescent/quarter/gibbous glyphs differ
/// between the waxing (brightening) and waning (dimming) halves of the cycle.
enum MoonDirection { case waxing, waning }

enum MoonPhase {
    /// Illumination runs 0 (new moon) … 4 (full moon).
    static let full = 4

    /// SF Symbol name for an illumination level travelling in `direction`.
    ///
    /// Heads up: these glyphs render INVERTED relative to their names. In the menu
    /// bar `moonphase.new.moon` draws as a SOLID disc and `moonphase.full.moon` as a
    /// thin ring — Apple fills the shadowed area, not the lit area — so visual fill
    /// *decreases* from `new` → `full` (and `crescent` looks fuller than `gibbous`).
    /// We therefore map illumination (0 = idle … 4 = held awake) to whichever glyph
    /// actually *looks* that full, so the moon reads empty (new) when idle and bright
    /// (full) when awake. Don't "fix" the names back to match illumination — that
    /// re-inverts what the user sees. (Measured hierarchical fill: new .58, crescent
    /// .49, quarter .44, gibbous .40, full .30.)
    static func symbol(illumination: Int, direction: MoonDirection) -> String {
        switch illumination {
        case ...0: return "moonphase.full.moon"                                        // idle → looks like an empty new moon
        case 1:    return direction == .waxing ? "moonphase.waning.gibbous"  : "moonphase.waxing.gibbous"
        case 2:    return direction == .waxing ? "moonphase.last.quarter"    : "moonphase.first.quarter"
        case 3:    return direction == .waxing ? "moonphase.waning.crescent" : "moonphase.waxing.crescent"
        default:   return "moonphase.new.moon"                                          // held awake → looks like a bright full moon
        }
    }
}

/// Pure, timer-free phase walker: the logic behind the menu-bar moon, isolated
/// from the `Timer`/`@Observable` shell so it can be unit-tested synchronously.
///
/// Each `step(toward:)` moves the illumination one phase toward a target. The
/// lit-side `lean` only flips at the extremes (new moon / full moon, which look
/// identical either way), NOT whenever travel direction reverses. That's the key
/// property: a moon that's winding down (waning) and then goes active again keeps
/// the same side lit and simply continues filling, instead of the glyph snapping
/// to the opposite side mid-sweep.
struct MoonWalk {
    private(set) var displayed: Int
    private(set) var lean: MoonDirection

    init(displayed: Int = 0, lean: MoonDirection = .waxing) {
        self.displayed = displayed
        self.lean = lean
    }

    private func clamp(_ v: Int) -> Int { max(0, min(MoonPhase.full, v)) }

    /// The SF Symbol for the current phase and lean.
    var symbol: String { MoonPhase.symbol(illumination: displayed, direction: lean) }

    /// Advance one phase toward `target`. Returns false if already there (so the
    /// animator knows to stop its timer).
    @discardableResult
    mutating func step(toward target: Int) -> Bool {
        let t = clamp(target)
        guard displayed != t else { return false }
        displayed += t > displayed ? 1 : -1
        // Flip the lean only when we bottom out (new) or top out (full); those
        // glyphs are side-agnostic, so the change is invisible — and a reversal
        // anywhere in between never flips sides.
        if displayed >= MoonPhase.full { lean = .waning }
        else if displayed <= 0 { lean = .waxing }
        return true
    }
}
