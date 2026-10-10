import UIKit
import GhosttyKit

/// Helpers for turning UIKit input into libghostty key events.
///
/// libghostty on iOS identifies physical keys by USB HID usage (the
/// same values as `UIKeyboardHIDUsage`), encoded with the keyboard
/// usage page as `0x07_0000 | usage`.
enum KeyInput {
    /// HID usages for keys we synthesize from the software keyboard and
    /// the accessory bar.
    enum Usage: UInt32 {
        case enter = 0x28
        case escape = 0x29
        case backspace = 0x2A
        case tab = 0x2B
        case space = 0x2C
        case arrowRight = 0x4F
        case arrowLeft = 0x50
        case arrowDown = 0x51
        case arrowUp = 0x52
        case home = 0x4A
        case pageUp = 0x4B
        case end = 0x4D
        case pageDown = 0x4E
    }

    static func keycode(_ usage: UInt32) -> UInt32 {
        0x07_0000 | usage
    }

    static func keycode(_ usage: Usage) -> UInt32 {
        keycode(usage.rawValue)
    }

    /// The HID usage for an unshifted US-layout character, used so that
    /// modifier combinations (Ctrl+C) encode as the physical key would.
    static func usage(for character: Character) -> UInt32? {
        guard let scalar = character.lowercased().unicodeScalars.first,
              character.unicodeScalars.count == 1 else { return nil }
        switch scalar {
        case "a"..."z": return 0x04 + (scalar.value - 0x61)
        case "1"..."9": return 0x1E + (scalar.value - 0x31)
        case "0": return 0x27
        case "-": return 0x2D
        case "=": return 0x2E
        case "[": return 0x2F
        case "]": return 0x30
        case "\\": return 0x31
        case ";": return 0x33
        case "'": return 0x34
        case "`": return 0x35
        case ",": return 0x36
        case ".": return 0x37
        case "/": return 0x38
        case " ": return Usage.space.rawValue
        default: return nil
        }
    }

    /// The US-layout shifted form of a character (`a`→`A`, `-`→`_`).
    /// Characters without one are returned unchanged.
    static func shifted(_ character: Character) -> Character {
        if character.isLetter { return Character(character.uppercased()) }
        let table: [Character: Character] = [
            "1": "!", "2": "@", "3": "#", "4": "$", "5": "%",
            "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
            "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|",
            ";": ":", "'": "\"", "`": "~", ",": "<", ".": ">", "/": "?",
        ]
        return table[character] ?? character
    }

    static func mods(_ flags: UIKeyModifierFlags) -> ghostty_input_mods_e {
        var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.alternate) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.alphaShift) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// The text to attach to a key event. Control characters and the
    /// private-use range UIKit uses for function keys are dropped so that
    /// libghostty encodes the key itself.
    static func eventText(_ characters: String) -> String? {
        guard let scalar = characters.unicodeScalars.first else { return nil }
        if scalar.value < 0x20 || scalar.value == 0x7F { return nil }
        if (0xF700...0xF8FF).contains(scalar.value) { return nil }
        return characters
    }

    /// Send a single key press + release to a surface. Returns whether
    /// libghostty handled the press.
    @discardableResult
    static func send(
        to surface: ghostty_surface_t,
        keycode: UInt32,
        mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE,
        text: String? = nil,
        unshifted: UInt32 = 0,
        action: ghostty_input_action_e
    ) -> Bool {
        func make(_ textPtr: UnsafePointer<CChar>?) -> ghostty_input_key_s {
            ghostty_input_key_s(
                action: action,
                mods: mods,
                consumed_mods: GHOSTTY_MODS_NONE,
                keycode: keycode,
                text: textPtr,
                unshifted_codepoint: unshifted,
                composing: false)
        }

        if let text, action != GHOSTTY_ACTION_RELEASE {
            return text.withCString { ghostty_surface_key(surface, make($0)) }
        }
        return ghostty_surface_key(surface, make(nil))
    }

    /// Press and release a key.
    static func tap(
        _ surface: ghostty_surface_t,
        keycode: UInt32,
        mods: ghostty_input_mods_e = GHOSTTY_MODS_NONE,
        text: String? = nil,
        unshifted: UInt32 = 0
    ) {
        send(to: surface, keycode: keycode, mods: mods, text: text, unshifted: unshifted,
             action: GHOSTTY_ACTION_PRESS)
        send(to: surface, keycode: keycode, mods: mods, unshifted: unshifted,
             action: GHOSTTY_ACTION_RELEASE)
    }

    /// Type a string from the software keyboard, one key event per
    /// character so the terminal's key encoding applies (rather than
    /// treating it as a paste).
    static func type(
        _ string: String,
        into surface: ghostty_surface_t,
        ctrl: Bool,
        alt: Bool,
        shift: Bool = false
    ) {
        for original in string {
            let character = shift ? shifted(original) : original
            let shiftMods = shift ? GHOSTTY_MODS_SHIFT : GHOSTTY_MODS_NONE
            if character == "\n" || character == "\r" {
                tap(surface, keycode: keycode(.enter), mods: shiftMods)
                continue
            }
            if character == "\t" {
                // Shift+Tab encodes as backtab (CSI Z).
                tap(surface, keycode: keycode(.tab), mods: shiftMods)
                continue
            }

            let usage = usage(for: original)
            let unshifted = original.lowercased().unicodeScalars.first?.value ?? 0
            var mods: UInt32 = GHOSTTY_MODS_NONE.rawValue
            if ctrl { mods |= GHOSTTY_MODS_CTRL.rawValue }
            if alt { mods |= GHOSTTY_MODS_ALT.rawValue }
            if shift || character.isUppercase { mods |= GHOSTTY_MODS_SHIFT.rawValue }

            tap(
                surface,
                keycode: usage.map { keycode($0) } ?? 0,
                mods: ghostty_input_mods_e(rawValue: mods),
                // With Ctrl held the key itself is encoded (Ctrl+C -> 0x03).
                text: ctrl ? nil : String(character),
                unshifted: unshifted)
        }
    }
}
