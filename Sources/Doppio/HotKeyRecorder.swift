// SPDX-License-Identifier: Apache-2.0
import AppKit
import Carbon.HIToolbox

/// Modal capture of a single global-hotkey combination, used by the
/// Preferences window's "Change…" button.
enum HotKeyRecorder {
    /// Present a modal that records the next key combo. Returns nil on
    /// cancel/Esc. Requires at least one modifier (⌘/⌥/⌃/⇧).
    static func record(current: String) -> (keyCode: UInt32, modifiers: UInt32, label: String)? {
        let alert = NSAlert()
        alert.messageText = "Change Hotkey"
        alert.informativeText = "Press the new shortcut (must include ⌘, ⌥, ⌃ or ⇧).\nCurrent: \(current)   ·   Esc to cancel"
        alert.addButton(withTitle: "Cancel")

        var result: (keyCode: UInt32, modifiers: UInt32, label: String)?
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                NSApp.stopModal(withCode: .cancel); return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var mods: UInt32 = 0
            if flags.contains(.command) { mods |= UInt32(cmdKey) }
            if flags.contains(.option)  { mods |= UInt32(optionKey) }
            if flags.contains(.control) { mods |= UInt32(controlKey) }
            if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
            guard mods != 0 else { return nil }   // need a modifier; keep waiting
            result = (UInt32(event.keyCode), mods, keyLabel(for: event))
            NSApp.stopModal(withCode: .stop)
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }
        return result
    }

    private static func keyLabel(for event: NSEvent) -> String {
        let specials: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
            kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let s = specials[Int(event.keyCode)] { return s }
        if let ch = event.charactersIgnoringModifiers, let first = ch.unicodeScalars.first,
           first.value >= 0x20 {
            return ch.uppercased()
        }
        return "key\(event.keyCode)"
    }
}
