import SwiftUI
import AppKit

@main
struct LunationApp: App {
    @State private var monitor = StatusMonitor()
    @State private var daemon  = DaemonManager()

    init() { NotificationSender.remindToInstallIfNeeded() }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(monitor)
                .environment(daemon)
        } label: {
            // MenuBarExtra renders its label as a template status image, where
            // SwiftUI .overlay badges get flattened/clipped and often don't show.
            // For the badged states we composite an NSImage ourselves (what status
            // items natively expect); the plain working state keeps the SwiftUI
            // symbol so its hierarchical moon-phase shading is preserved.
            if let badgeSymbol {
                Image(nsImage: MenuBarIcon.render(base: menuBarIcon, badge: badgeSymbol))
            } else {
                Image(systemName: menuBarIcon)
                    .symbolRenderingMode(.hierarchical)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(daemon)
        }
    }

    private var menuBarIcon: String {
        // Not installed and daemon-down both mean "not working" → same sleepy icon
        // (monitor.menuBarIcon returns moonphase.new.moon when the daemon isn't reporting).
        guard daemon.isInstalled else { return "moonphase.new.moon" }
        return monitor.menuBarIcon
    }

    /// The corner-badge SF Symbol for the two "not working" states, or nil when
    /// running. Not installed → install (Install Helper); installed-but-down →
    /// error (Restart Helper). Distinct SHAPES so they're tellable apart even when
    /// the menu bar renders them monochrome.
    private var badgeSymbol: String? {
        if !daemon.isInstalled      { return "arrow.down.circle.fill" }
        if !monitor.daemonConnected { return "exclamationmark.circle.fill" }
        return nil
    }
}

/// Builds the menu-bar status image: an SF Symbol base with an optional badge
/// composited into the bottom-right corner (moonphase.new.moon leaves that corner clear).
/// Rendered as a template image so it stays monochrome and adapts to light/dark
/// menu bars — a colored badge can't survive template rendering, so the states
/// are distinguished by badge shape, not color.
enum MenuBarIcon {
    static func render(base: String, badge: String?) -> NSImage {
        let baseImg = NSImage(systemSymbolName: base, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? NSImage()

        guard let badge,
              let badgeImg = NSImage(systemSymbolName: badge, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .bold)) else {
            baseImg.isTemplate = true
            return baseImg
        }

        let size = baseImg.size
        let bSize = badgeImg.size
        let img = NSImage(size: size)
        img.lockFocus()
        baseImg.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        // Punch a small transparent gap around the badge so it reads as a separate
        // mark instead of merging with the moon in monochrome.
        let origin = NSPoint(x: size.width - bSize.width, y: 0)
        if let ctx = NSGraphicsContext.current {
            ctx.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: NSRect(x: origin.x - 1.2, y: origin.y - 1.2,
                                        width: bSize.width + 2.4, height: bSize.height + 2.4)).fill()
            ctx.compositingOperation = .sourceOver
        }
        badgeImg.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        img.unlockFocus()
        img.isTemplate = true
        return img
    }
}
