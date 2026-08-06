import Carbon.HIToolbox
import Combine
import Foundation

/// A single key + modifier combination, persisted as the user's chosen shortcut.
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: Int
    var modifiers: UInt32   // Carbon modifier flags (cmdKey/optionKey/controlKey/shiftKey)

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0  { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0   { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0     { s += "⌘" }
        s += Self.keyName(keyCode)
        return s
    }

    private static func keyName(_ code: Int) -> String {
        switch code {
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Escape: return "Esc"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        default:
            // Letters/digits map cleanly via the ASCII-adjacent Carbon keycodes
            // for the common case; anything exotic just shows the raw code.
            if let scalar = Self.asciiForKeyCode[code] { return String(scalar) }
            return "Key\(code)"
        }
    }

    private static let asciiForKeyCode: [Int: Character] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
    ]
}

/// User-configurable bindings for the five desk actions. Defaults match the
/// original hardcoded shortcuts.
@MainActor
final class ShortcutSettings: ObservableObject {
    // Same singleton fix as DeskController.shared — see its comment.
    static let shared = ShortcutSettings()

    @Published var stand: KeyCombo     { didSet { persist() } }
    @Published var sit: KeyCombo       { didSet { persist() } }
    @Published var nudgeUp: KeyCombo   { didSet { persist() } }
    @Published var nudgeDown: KeyCombo { didSet { persist() } }
    @Published var stop: KeyCombo      { didSet { persist() } }

    private static let defaultsKey = "shortcutBindings"

    init() {
        let base = UInt32(controlKey) | UInt32(optionKey)
        let withShift = base | UInt32(shiftKey)
        var loaded: [String: KeyCombo] = [:]
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: KeyCombo].self, from: data) {
            loaded = decoded
        }
        stand     = loaded["stand"]     ?? KeyCombo(keyCode: kVK_UpArrow,   modifiers: base)
        sit       = loaded["sit"]       ?? KeyCombo(keyCode: kVK_DownArrow, modifiers: base)
        nudgeUp   = loaded["nudgeUp"]   ?? KeyCombo(keyCode: kVK_UpArrow,   modifiers: withShift)
        nudgeDown = loaded["nudgeDown"] ?? KeyCombo(keyCode: kVK_DownArrow, modifiers: withShift)
        stop      = loaded["stop"]      ?? KeyCombo(keyCode: kVK_Space,    modifiers: base)
    }

    func resetToDefaults() {
        let base = UInt32(controlKey) | UInt32(optionKey)
        let withShift = base | UInt32(shiftKey)
        stand = KeyCombo(keyCode: kVK_UpArrow, modifiers: base)
        sit = KeyCombo(keyCode: kVK_DownArrow, modifiers: base)
        nudgeUp = KeyCombo(keyCode: kVK_UpArrow, modifiers: withShift)
        nudgeDown = KeyCombo(keyCode: kVK_DownArrow, modifiers: withShift)
        stop = KeyCombo(keyCode: kVK_Space, modifiers: base)
    }

    private func persist() {
        let dict: [String: KeyCombo] = [
            "stand": stand, "sit": sit, "nudgeUp": nudgeUp, "nudgeDown": nudgeDown, "stop": stop,
        ]
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Registers global (system-wide) hotkeys via the Carbon Hot Key API.
/// Unlike NSEvent global monitors, RegisterEventHotKey does NOT require the
/// Accessibility permission, which makes for a much smoother first-run.
@MainActor
final class HotKeyManager: ObservableObject {
    // Same singleton fix as DeskController.shared — see its comment.
    static let shared = HotKeyManager()

    private var refs: [EventHotKeyRef?] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1
    private var bindingsCancellable: AnyCancellable?
    private var boundShortcuts: ShortcutSettings?
    private var boundDesk: DeskController?

    /// Action names (matching ShortcutSettings' keys) whose combo failed to
    /// register — e.g. a system-reserved combo like ⌘Space. Surfaced in the
    /// settings window so a silent failure doesn't just look like "doesn't work".
    @Published var failedActions: Set<String> = []

    // Modifier flag constants (Carbon)
    static let cmd     = UInt32(cmdKey)
    static let option  = UInt32(optionKey)
    static let control = UInt32(controlKey)
    static let shift   = UInt32(shiftKey)

    func start() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            let id = hkID.id
            Task { @MainActor in mgr.handlers[id]?() }
            return noErr
        }, 1, &spec, selfPtr, &eventHandler)
    }

    /// Register a hotkey. `key` is a Carbon virtual keycode (e.g. kVK_UpArrow).
    /// Returns false if the system rejected the combo (e.g. already owned by
    /// another app or reserved by macOS).
    @discardableResult
    func register(key: Int, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        let id = nextID; nextID += 1
        let hkID = EventHotKeyID(signature: OSType(0x44534B42 /* 'DSKB' */), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(key), modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, ref != nil else { return false }
        handlers[id] = action
        refs.append(ref)
        return true
    }

    func unregisterAll() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs = []
        handlers = [:]
    }

    /// Apply the current bindings from `shortcuts`, and re-apply automatically
    /// whenever the user changes one in the settings window.
    func observe(_ shortcuts: ShortcutSettings, desk: DeskController) {
        boundShortcuts = shortcuts
        boundDesk = desk
        applyBindings(shortcuts, desk: desk)
        bindingsCancellable = shortcuts.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the new value is stored — defer so
            // the re-registration reads the value that's actually about to land.
            DispatchQueue.main.async { self?.applyBindings(shortcuts, desk: desk) }
        }
    }

    /// Temporarily drop all hotkeys — RegisterEventHotKey consumes matching
    /// keystrokes system-wide before any local NSEvent monitor sees them, so a
    /// shortcut recorder can never capture a combo that's currently bound
    /// (most obviously, re-recording the same action) unless we get out of the way.
    func suspend() { unregisterAll() }

    func resume() {
        guard let s = boundShortcuts, let d = boundDesk else { return }
        applyBindings(s, desk: d)
    }

    private func applyBindings(_ s: ShortcutSettings, desk: DeskController) {
        unregisterAll()
        let entries: [(name: String, combo: KeyCombo, action: () -> Void)] = [
            ("stand", s.stand, { desk.goStand() }),
            ("sit", s.sit, { desk.goSit() }),
            ("nudgeUp", s.nudgeUp, { desk.nudge(desk.nudgeCm) }),
            ("nudgeDown", s.nudgeDown, { desk.nudge(-desk.nudgeCm) }),
            ("stop", s.stop, { desk.stop() }),
        ]
        var failed: Set<String> = []
        var seen: [KeyCombo: String] = [:]
        for (name, combo, action) in entries {
            // Same combo bound to two of our own actions — RegisterEventHotKey
            // won't catch this (only one call ever reaches the system), so it
            // has to be checked before registering.
            if let other = seen[combo] {
                failed.insert(name)
                failed.insert(other)
                continue
            }
            seen[combo] = name
            if !register(key: combo.keyCode, modifiers: combo.modifiers, action: action) {
                failed.insert(name)
            }
        }
        failedActions = failed
    }
}
