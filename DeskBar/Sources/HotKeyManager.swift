import Carbon.HIToolbox
import Foundation

/// Registers global (system-wide) hotkeys via the Carbon Hot Key API.
/// Unlike NSEvent global monitors, RegisterEventHotKey does NOT require the
/// Accessibility permission, which makes for a much smoother first-run.
@MainActor
final class HotKeyManager {
    private var refs: [EventHotKeyRef?] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

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
    func register(key: Int, modifiers: UInt32, action: @escaping () -> Void) {
        let id = nextID; nextID += 1
        handlers[id] = action
        let hkID = EventHotKeyID(signature: OSType(0x44534B42 /* 'DSKB' */), id: id)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(key), modifiers, hkID,
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}
