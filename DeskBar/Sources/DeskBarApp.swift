import SwiftUI
import AppKit
import Carbon.HIToolbox

@main
struct DeskBarApp: App {
    @StateObject private var desk = DeskController()
    @State private var hotkeys = HotKeyManager()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(desk: desk)
        } label: {
            // Glanceable height in the menu bar.
            Image(systemName: desk.isReady ? (desk.isStanding ? "figure.stand" : "chair.lounge")
                                           : "chair")
            if desk.isReady {
                Text("\(Int(desk.heightCm.rounded()))")
            }
        }
        .menuBarExtraStyle(.window)
    }

    init() {
        // Single-instance guard: if another copy is already running, focus it
        // and exit before creating a second menu-bar item or hotkeys.
        Self.terminateIfAlreadyRunning()

        // Capture the desk instance for the hotkey closures.
        let deskRef = _desk.wrappedValue
        let hk = hotkeys
        let mods = HotKeyManager.control | HotKeyManager.option
        hk.start()
        hk.register(key: kVK_UpArrow,   modifiers: mods) { deskRef.goStand() }
        hk.register(key: kVK_DownArrow, modifiers: mods) { deskRef.goSit() }
        hk.register(key: kVK_UpArrow,   modifiers: mods | HotKeyManager.shift) { deskRef.nudge(2) }
        hk.register(key: kVK_DownArrow, modifiers: mods | HotKeyManager.shift) { deskRef.nudge(-2) }
        hk.register(key: kVK_Space,     modifiers: mods) { deskRef.stop() }
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
