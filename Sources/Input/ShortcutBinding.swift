import Carbon.HIToolbox
import Foundation

/// Modifier keys that can be part of a shortcut.
struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    var rawValue: UInt

    init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    static let command = ShortcutModifiers(rawValue: 1 << 0)
    static let control = ShortcutModifiers(rawValue: 1 << 1)
    static let option = ShortcutModifiers(rawValue: 1 << 2)
    static let shift = ShortcutModifiers(rawValue: 1 << 3)
    static let function = ShortcutModifiers(rawValue: 1 << 4)

    /// Convert from CGEventFlags.
    init(flags: CGEventFlags) {
        var mods = ShortcutModifiers()
        if flags.contains(.maskCommand) { mods.insert(.command) }
        if flags.contains(.maskControl) { mods.insert(.control) }
        if flags.contains(.maskAlternate) { mods.insert(.option) }
        if flags.contains(.maskShift) { mods.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { mods.insert(.function) }
        self = mods
    }
}

/// A keyboard shortcut binding for dictation activation.
struct ShortcutBinding: Codable, Equatable, Hashable {
    let keyCode: UInt16?
    let modifiers: ShortcutModifiers
    /// When true, the binding fires on two quick clean taps of a bare
    /// modifier (keyCode nil) instead of on the modifier being held. A
    /// double-press binding is toggle-only: it starts a hands-free session
    /// and a single press of the same modifier stops it.
    let isDoublePress: Bool

    init(keyCode: UInt16?, modifiers: ShortcutModifiers, isDoublePress: Bool = false) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isDoublePress = isDoublePress && keyCode == nil
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers, isDoublePress
    }

    // Custom decode so payloads encoded before `isDoublePress` existed still decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let keyCode = try container.decodeIfPresent(UInt16.self, forKey: .keyCode)
        let modifiers = try container.decode(ShortcutModifiers.self, forKey: .modifiers)
        let isDoublePress = try container.decodeIfPresent(Bool.self, forKey: .isDoublePress) ?? false
        self.init(keyCode: keyCode, modifiers: modifiers, isDoublePress: isDoublePress)
    }

    /// Function key only (hold to talk default).
    static let fnKey = ShortcutBinding(keyCode: nil, modifiers: .function)

    /// Function key pressed twice quickly (default toggle / hands-free shortcut).
    static let fnDoublePress = ShortcutBinding(keyCode: nil, modifiers: .function, isDoublePress: true)

    /// Command + Function key.
    static let commandFn = ShortcutBinding(keyCode: nil, modifiers: [.command, .function])

    /// Right Option key.
    static let rightOption = ShortcutBinding(keyCode: UInt16(kVK_RightOption), modifiers: .option)

    /// Control + Space.
    static let controlSpace = ShortcutBinding(keyCode: UInt16(kVK_Space), modifiers: .control)

    /// Option + Space.
    static let optionSpace = ShortcutBinding(keyCode: UInt16(kVK_Space), modifiers: .option)

    /// Command + Shift + Space.
    static let commandShiftSpace = ShortcutBinding(keyCode: UInt16(kVK_Space), modifiers: [.command, .shift])

    /// F5 key.
    static let f5 = ShortcutBinding(keyCode: UInt16(kVK_F5), modifiers: [])

    /// Built-in preset shortcuts for hold-to-talk.
    static let holdPresets: [ShortcutBinding] = [.fnKey, .rightOption, .controlSpace, .f5]

    /// Built-in preset shortcuts for toggle recording.
    /// `fnDoublePress` is toggle-only and is never offered as a hold preset.
    static let togglePresets: [ShortcutBinding] = [.fnDoublePress, .commandFn, .optionSpace, .commandShiftSpace, .f5]

    var displayName: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("^") }
        if modifiers.contains(.option) { parts.append("\u{2325}") }
        if modifiers.contains(.shift) { parts.append("\u{21E7}") }
        if modifiers.contains(.command) { parts.append("\u{2318}") }
        if modifiers.contains(.function) { parts.append("fn") }
        if let keyCode {
            parts.append(Self.keyCodeName(keyCode))
        }
        let joined = parts.joined()
        return isDoublePress ? "\(joined) \(joined)" : joined
    }

    var menuTitle: String {
        switch self {
        case .fnKey:
            return "Fn"
        case .fnDoublePress:
            return "Fn twice"
        case .commandFn:
            return "Command + Fn"
        case .rightOption:
            return "Right Option"
        case .controlSpace:
            return "Control + Space"
        case .optionSpace:
            return "Option + Space"
        case .commandShiftSpace:
            return "Command + Shift + Space"
        case .f5:
            return "F5"
        default:
            return displayName
        }
    }

    /// The phrase that starts a toggle session with this binding, e.g.
    /// "Press Fn twice" or "Press Command + Fn".
    var toggleStartPhrase: String {
        if isDoublePress {
            return "Press \(Self(keyCode: keyCode, modifiers: modifiers).menuTitle) twice"
        }
        return "Press \(menuTitle)"
    }

    /// The phrase that stops a running toggle session, e.g. "press Fn once"
    /// or "press Command + Fn again". Lowercase so it reads mid-sentence.
    var toggleStopPhrase: String {
        if isDoublePress {
            return "press \(Self(keyCode: keyCode, modifiers: modifiers).menuTitle) once"
        }
        return "press \(menuTitle) again"
    }

    /// "<modifiers>:<keyCode|x>", plus a ":2" suffix for double-press
    /// bindings (e.g. "16:x:2"). Single-press values keep the original
    /// two-part format so previously stored values still decode.
    var storageValue: String {
        let keyValue = keyCode.map(String.init) ?? "x"
        let base = "\(modifiers.rawValue):\(keyValue)"
        return isDoublePress ? "\(base):2" : base
    }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3, let modifiersRaw = UInt(parts[0]) else { return nil }

        let isDoublePress: Bool
        if parts.count == 3 {
            // Only bare-modifier double presses are representable.
            guard parts[2] == "2", parts[1] == "x" else { return nil }
            isDoublePress = true
        } else {
            isDoublePress = false
        }

        let keyCode: UInt16?
        if parts[1] == "x" {
            keyCode = nil
        } else if let parsedKey = UInt16(parts[1]) {
            keyCode = parsedKey
        } else {
            return nil
        }

        self.init(keyCode: keyCode, modifiers: ShortcutModifiers(rawValue: modifiersRaw), isDoublePress: isDoublePress)
    }

    private static func keyCodeName(_ code: UInt16) -> String {
        switch Int(code) {
        case kVK_F5: return "F5"
        case kVK_RightOption: return "Right \u{2325}"
        case kVK_Space: return "Space"
        case kVK_Return: return "\u{21A9}"
        default: return "Key(\(code))"
        }
    }
}

/// How dictation was triggered.
enum RecordingTriggerMode: String, CaseIterable, Identifiable {
    case hold   // Hold key to record, release to stop
    case toggle // Press to start (twice for a double-press binding), press again to stop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hold:
            return "Hold to talk"
        case .toggle:
            return "Press to start/stop"
        }
    }
}

extension String {
    /// The string with its first character uppercased ("press Fn once" -> "Press Fn once").
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
