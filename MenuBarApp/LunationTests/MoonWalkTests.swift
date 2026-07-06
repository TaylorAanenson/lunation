import XCTest

// `MoonPhase.swift` is compiled into this test target directly (see the project's
// LunationTests Sources phase), so these are hostless logic tests: no app launch,
// no @testable import, just the pure `MoonWalk` logic exercised synchronously.

/// Tests for `MoonWalk` — the pure phase-stepping logic behind the menu-bar moon.
/// `MoonWalk` is timer-free, so these run synchronously with no app host.
final class MoonWalkTests: XCTestCase {

    /// Drive a walk toward `target` until it settles, collecting the symbol after
    /// every step (not the starting symbol). Caps iterations so a logic bug can't
    /// hang the suite.
    private func sweep(_ walk: inout MoonWalk, toward target: Int) -> [String] {
        var symbols: [String] = []
        var guardCount = 0
        while walk.step(toward: target) {
            symbols.append(walk.symbol)
            guardCount += 1
            XCTAssertLessThan(guardCount, 50, "walk failed to converge on \(target)")
        }
        return symbols
    }

    /// Classify a glyph by which side is lit. New/full are side-agnostic (nil).
    private func litSide(_ symbol: String) -> String? {
        if symbol.contains("new") || symbol.contains("full") { return nil }
        if symbol.contains("waxing") || symbol.contains("first.quarter") { return "right" }
        if symbol.contains("waning") || symbol.contains("last.quarter")  { return "left" }
        return nil
    }

    // MARK: — Basic stepping

    func test_starts_at_new_moon() {
        let walk = MoonWalk()
        XCTAssertEqual(walk.displayed, 0)
        // Idle (illumination 0) is the empty-looking moon. SF Symbols' moonphase
        // names render inverted, so that glyph is "moonphase.full.moon" (see MoonPhase).
        XCTAssertEqual(walk.symbol, "moonphase.full.moon")
    }

    func test_step_returns_false_when_already_at_target() {
        var walk = MoonWalk(displayed: 4, lean: .waning)
        XCTAssertFalse(walk.step(toward: 4))
        XCTAssertEqual(walk.displayed, 4)
    }

    func test_clamps_out_of_range_target() {
        var walk = MoonWalk()
        _ = sweep(&walk, toward: 99)
        XCTAssertEqual(walk.displayed, MoonPhase.full)   // never exceeds full
        _ = sweep(&walk, toward: -99)
        XCTAssertEqual(walk.displayed, 0)                // never below new
    }

    func test_full_wax_sweep_reaches_full_in_four_steps() {
        var walk = MoonWalk()
        let symbols = sweep(&walk, toward: 4)
        XCTAssertEqual(symbols.count, 4)
        // Fully lit (illumination 4) is the bright disc — the inverted-name glyph
        // "moonphase.new.moon" (see MoonPhase.symbol).
        XCTAssertEqual(symbols.last, "moonphase.new.moon")
    }

    // MARK: — Lean flips only at the extremes

    func test_lean_flips_to_waning_only_at_full() {
        var walk = MoonWalk()           // starts .waxing
        _ = walk.step(toward: 4)        // 0 -> 1
        XCTAssertEqual(walk.lean, .waxing)
        _ = walk.step(toward: 4)        // 1 -> 2
        XCTAssertEqual(walk.lean, .waxing)
        _ = walk.step(toward: 4)        // 2 -> 3
        XCTAssertEqual(walk.lean, .waxing)
        _ = walk.step(toward: 4)        // 3 -> 4 (top out)
        XCTAssertEqual(walk.lean, .waning)
    }

    func test_lean_flips_to_waxing_only_at_new() {
        var walk = MoonWalk(displayed: 4, lean: .waning)
        _ = walk.step(toward: 0)        // 4 -> 3
        XCTAssertEqual(walk.lean, .waning)
        _ = walk.step(toward: 0)        // 3 -> 2
        XCTAssertEqual(walk.lean, .waning)
        _ = walk.step(toward: 0)        // 2 -> 1
        XCTAssertEqual(walk.lean, .waning)
        _ = walk.step(toward: 0)        // 1 -> 0 (bottom out)
        XCTAssertEqual(walk.lean, .waxing)
    }

    // MARK: — The fix: reversing mid-wind-down never flips the lit side

    func test_reversal_during_wind_down_keeps_same_lit_side() {
        // Wax to full, then wane partway down (the "wind down"), then go active
        // again before reaching new moon. The lit side must not flip across the
        // reversal — that snap was the reported bug.
        var walk = MoonWalk()
        _ = sweep(&walk, toward: 4)     // up to full; lean is now .waning

        var sides: [String?] = []
        // Wane down to level 2 …
        while walk.displayed > 2 {
            _ = walk.step(toward: 0)
            sides.append(litSide(walk.symbol))
        }
        let sideAtReversal = litSide(walk.symbol)   // side while wound down to 2
        // … then reverse back up to full (task active again).
        while walk.step(toward: 4) {
            sides.append(litSide(walk.symbol))
        }

        // No two consecutive *partial* phases may light opposite sides.
        let partials = sides.compactMap { $0 }
        for (a, b) in zip(partials, partials.dropFirst()) {
            XCTAssertEqual(a, b, "lit side flipped mid-sweep: \(a) -> \(b)")
        }
        // And the wax after the reversal stays on the wind-down's side. At full
        // illumination the glyph is the side-agnostic "moonphase.new.moon" (inverted
        // name), so substitute a right-lit proxy to read the side back.
        XCTAssertEqual(litSide(walk.symbol == "moonphase.new.moon"
                               ? "moonphase.waxing.gibbous" : walk.symbol),
                       sideAtReversal)
    }

    func test_reversal_preserves_fill_level_not_reset() {
        // Position is carried, not reset: reversing from level 2 waxes 2 -> 3 -> 4,
        // it does not jump to full or restart from new.
        var walk = MoonWalk(displayed: 2, lean: .waning)
        XCTAssertTrue(walk.step(toward: 4))
        XCTAssertEqual(walk.displayed, 3)   // continues from 2, one step at a time
        XCTAssertTrue(walk.step(toward: 4))
        XCTAssertEqual(walk.displayed, 4)
    }
}
