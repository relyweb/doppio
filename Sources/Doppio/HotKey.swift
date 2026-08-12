import AppKit
import Carbon.HIToolbox

/// Registers a single, user-configurable system-wide hotkey to toggle
/// keep-awake.
///
/// Uses Carbon `RegisterEventHotKey`, which works for background/accessory apps
/// without the Accessibility permission that `CGEvent` taps would require.
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Invoked on the main thread each time the hotkey fires.
    var onFire: (() -> Void)?

    private init() {}

    var isRegistered: Bool { hotKeyRef != nil }

    /// (Re)register with the given key code + Carbon modifier mask.
    /// Returns false if the OS rejected the combination (e.g. already taken).
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x44_50_4B_31), id: 1)  // 'DPK1'
        let status = RegisterEventHotKey(keyCode, modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { hotKeyRef = nil; return false }
        return hotKeyRef != nil
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { mgr.onFire?() }
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)
    }

    // MARK: - Display

    /// Human-readable shortcut, e.g. "⌃⌥⌘K".
    static func display(modifiers: UInt32, label: String) -> String {
        glyphs(modifiers: modifiers) + label
    }

    /// Conventionally ordered modifier glyphs (⌃⌥⇧⌘).
    static func glyphs(modifiers: UInt32) -> String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s
    }
}
