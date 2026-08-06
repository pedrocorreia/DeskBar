import SwiftUI
import AppKit
import Carbon.HIToolbox

struct ShortcutSettingsView: View {
    @ObservedObject var shortcuts: ShortcutSettings
    @ObservedObject var hotkeys: HotKeyManager
    @Environment(\.scenePhase) private var scenePhase

    /// Which action's field currently owns the recording monitor, if any.
    /// Centralized here (rather than per-field @State) so arming one field
    /// deterministically disarms any other — otherwise two overlapping local
    /// monitors could both fire on the next keypress.
    @State private var activeRecorder: String?

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
        .onChange(of: scenePhase) { phase in
            // Recording suspends every global hotkey (see ShortcutRecorderField).
            // If the user arms a field then switches to another app instead of
            // pressing a combo, that suspension would otherwise never lift.
            guard phase != .active, activeRecorder != nil else { return }
            activeRecorder = nil
            hotkeys.resume()
        }
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
            ShortcutRecorderField(
                combo: combo,
                hotkeys: hotkeys,
                actionKey: actionKey,
                activeRecorder: $activeRecorder,
                conflictCheck: { newCombo in conflict(for: newCombo, excluding: actionKey) }
            )
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
    let actionKey: String
    @Binding var activeRecorder: String?
    /// Returns the title of whichever other action already owns a combo, or nil.
    var conflictCheck: (KeyCombo) -> String?

    @State private var monitor: Any?
    @State private var conflictMessage: String?

    private var isRecording: Bool { activeRecorder == actionKey }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button(isRecording ? "Press keys…" : combo.displayString) {
                isRecording ? stopRecording() : startRecording()
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .orange : nil)
            .frame(width: 120)
            .onDisappear { if monitor != nil { stopRecording() } }

            if let conflictMessage {
                Text(conflictMessage)
                    .font(.caption2).foregroundStyle(.red)
                    .frame(width: 120)
            }
        }
        .onChange(of: activeRecorder) { newValue in
            // Another field armed itself — tear down our own monitor, but
            // don't touch global hotkey suspension: it's the new field's to
            // manage now, and it already re-suspended when it armed.
            guard newValue != actionKey, monitor != nil else { return }
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            conflictMessage = nil
        }
    }

    private func startRecording() {
        // RegisterEventHotKey grabs matching keystrokes system-wide before this
        // local monitor would ever see them — most obviously when re-recording
        // the very combo that's currently bound. Drop all bindings while armed.
        hotkeys.suspend()
        activeRecorder = actionKey
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
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if activeRecorder == actionKey { activeRecorder = nil }
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
