import SwiftUI
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
}
