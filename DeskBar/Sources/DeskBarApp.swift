import SwiftUI
import AppKit

@main
struct DeskBarApp: App {
    // Backed by shared singletons, not the autoclosure default — see
    // DeskController.shared's comment for why that distinction matters here.
    @StateObject private var desk = DeskController.shared
    @StateObject private var hotkeys = HotKeyManager.shared
    @StateObject private var shortcuts = ShortcutSettings.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView(desk: desk, shortcuts: shortcuts)
        } label: {
            // Glanceable height + connection state in the menu bar.
            Image(nsImage: statusIcon)
            if desk.isReady {
                Text("\(Int(desk.heightCm.rounded()))")
            }
        }
        .menuBarExtraStyle(.window)

        Window("DeskBar Shortcuts", id: "shortcuts") {
            ShortcutSettingsView(shortcuts: shortcuts, hotkeys: hotkeys)
        }
        .windowResizability(.contentSize)
    }

    // MenuBarExtra flattens its label into an NSStatusItem button image, which
    // forces template (monochrome, menu-bar-tinted) rendering — SwiftUI color
    // modifiers (.foregroundStyle, .renderingMode) get discarded in that
    // conversion. Building a pre-colored NSImage with isTemplate = false is the
    // only way to keep the color.
    private var statusIcon: NSImage {
        let symbolName = desk.isReady ? (desk.isStanding ? "figure.stand" : "chair.lounge") : "chair"
        let tint: NSColor = desk.isMoving ? .systemOrange : (desk.isReady ? .systemGreen : .systemRed)
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) ?? NSImage()
        let img = base.withSymbolConfiguration(config) ?? base
        img.isTemplate = false
        return img
    }

    init() {
        // Single-instance guard: if another copy is already running, focus it
        // and exit before creating a second menu-bar item or hotkeys.
        Self.terminateIfAlreadyRunning()

        HotKeyManager.shared.start()
        HotKeyManager.shared.observe(ShortcutSettings.shared, desk: DeskController.shared)
    }

    private static func terminateIfAlreadyRunning() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.pedro.deskbar"
        let mePID = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != mePID }
        if let existing = others.first {
            existing.activate()
            exit(0)
        }
    }
}
