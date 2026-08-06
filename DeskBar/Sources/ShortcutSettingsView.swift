import SwiftUI
import AppKit
import Carbon.HIToolbox

struct ShortcutSettingsView: View {
    @ObservedObject var shortcuts: ShortcutSettings
    @ObservedObject var hotkeys: HotKeyManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard Shortcuts")
                .font(.title3).bold()
            Text("Click a shortcut, then press the key combo you want. Requires at least one modifier key.")
                .font(.caption).foregroundStyle(.secondary)

            VStack(spacing: 10) {
                row("Stand", "stand", $shortcuts.stand)
                row("Sit", "sit", $shortcuts.sit)
                row("Nudge up", "nudgeUp", $shortcuts.nudgeUp)
                row("Nudge down", "nudgeDown", $shortcuts.nudgeDown)
                row("Stop", "stop", $shortcuts.stop)
            }

            if !hotkeys.failedActions.isEmpty {
                Text("Highlighted shortcuts didn't register — likely already used by macOS or another app.")
                    .font(.caption).foregroundStyle(.red)
            }

            Button("Reset to Defaults") { shortcuts.resetToDefaults() }
                .controlSize(.small)
        }
        .padding(20)
        .frame(width: 340)
    }

    private var allBindings: [(key: String, title: String, combo: KeyCombo)] {
        [
            ("stand", "Stand", shortcuts.stand),
            ("sit", "Sit", shortcuts.sit),
            ("nudgeUp", "Nudge up", shortcuts.nudgeUp),
            ("nudgeDown", "Nudge down", shortcuts.nudgeDown),
            ("stop", "Stop", shortcuts.stop),
        ]
    }

    /// Title of whichever *other* action already owns this combo, if any —
    /// used to block a recording before it's accepted rather than just
    /// flagging the collision after the fact.
    private func conflict(for combo: KeyCombo, excluding actionKey: String) -> String? {
        allBindings.first { $0.key != actionKey && $0.combo == combo }?.title
    }

    private func row(_ title: String, _ actionKey: String, _ combo: Binding<KeyCombo>) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .foregroundStyle(hotkeys.failedActions.contains(actionKey) ? .red : .primary)
            Spacer()
            ShortcutRecorderField(combo: combo, hotkeys: hotkeys) { newCombo in
                conflict(for: newCombo, excluding: actionKey)
            }
        }
    }
}

/// Click to arm, then press a key combo (must include at least one modifier)
/// to record it. Captures via a local key-down monitor scoped to this app's
/// windows — no Accessibility permission needed since we're not listening
/// system-wide, just while our own settings window is key.
struct ShortcutRecorderField: View {
    @Binding var combo: KeyCombo
    @ObservedObject var hotkeys: HotKeyManager
    /// Returns the title of whichever other action already owns a combo, or nil.
    var conflictCheck: (KeyCombo) -> String?

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var conflictMessage: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button(isRecording ? "Press keys…" : combo.displayString) {
                isRecording ? stopRecording() : startRecording()
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .orange : nil)
            .frame(width: 120)
            .onDisappear { stopRecording() }

            if let conflictMessage {
                Text(conflictMessage)
                    .font(.caption2).foregroundStyle(.red)
                    .frame(width: 120)
            }
        }
    }

    private func startRecording() {
        // RegisterEventHotKey grabs matching keystrokes system-wide before this
        // local monitor would ever see them — most obviously when re-recording
        // the very combo that's currently bound. Drop all bindings while armed.
        hotkeys.suspend()
        isRecording = true
        conflictMessage = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let mods = carbonModifiers(from: event.modifierFlags)
            guard mods != 0 else { return nil }   // require a modifier; swallow bare keys
            let newCombo = KeyCombo(keyCode: Int(event.keyCode), modifiers: mods)
            if let owner = conflictCheck(newCombo) {
                // Reject and stay armed — let them try a different combo without
                // re-clicking, rather than silently creating a duplicate binding.
                conflictMessage = "Already used by \(owner) — try another combo."
                return nil
            }
            combo = newCombo
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hotkeys.resume()
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }
}
