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

    init(keyCode: UInt16?, modifiers: ShortcutModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Function key only (hold to talk default).
    static let fnKey = ShortcutBinding(keyCode: nil, modifiers: .function)

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
    static let togglePresets: [ShortcutBinding] = [.commandFn, .optionSpace, .commandShiftSpace, .f5]

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
        return parts.joined()
    }

    var menuTitle: String {
        switch self {
        case .fnKey:
            return "Fn"
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

    var storageValue: String {
        let keyValue = keyCode.map(String.init) ?? "x"
        return "\(modifiers.rawValue):\(keyValue)"
    }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let modifiersRaw = UInt(parts[0]) else { return nil }

        let keyCode: UInt16?
        if parts[1] == "x" {
            keyCode = nil
        } else if let parsedKey = UInt16(parts[1]) {
            keyCode = parsedKey
        } else {
            return nil
        }

        self.init(keyCode: keyCode, modifiers: ShortcutModifiers(rawValue: modifiersRaw))
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
    case toggle // Press once to start, again to stop

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
