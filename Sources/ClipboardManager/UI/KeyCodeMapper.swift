import AppKit
import Foundation

/// 键盘键码 → 可读文本；NSEvent 修饰键 → Carbon 位掩码。
enum KeyCodeMapper {
    static func displayString(keyCode: Int, modifiers: UInt) -> String {
        modifierString(modifiers) + keyString(keyCode)
    }

    static func modifierString(_ modifiers: UInt) -> String {
        var parts: [String] = []
        if modifiers & 4096 != 0 { parts.append("⌃") }  // kControlKey
        if modifiers & 2048 != 0 { parts.append("⌥") }  // kOptionKey
        if modifiers & 512 != 0 { parts.append("⇧") }   // kShiftKey
        if modifiers & 256 != 0 { parts.append("⌘") }   // kCommandKey
        return parts.joined()
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt {
        var value: UInt = 0
        if flags.contains(.control) { value |= 4096 }
        if flags.contains(.option) { value |= 2048 }
        if flags.contains(.shift) { value |= 512 }
        if flags.contains(.command) { value |= 256 }
        return value
    }

    static func keyString(_ keyCode: Int) -> String {
        switch keyCode {
        case 0: "A"; case 1: "S"; case 2: "D"; case 3: "F"; case 4: "H"; case 5: "G"
        case 6: "Z"; case 7: "X"; case 8: "C"; case 9: "V"; case 10: "B"; case 11: "B"
        case 12: "Q"; case 13: "W"; case 14: "E"; case 15: "R"; case 16: "Y"; case 17: "T"
        case 18: "1"; case 19: "2"; case 20: "3"; case 21: "4"; case 22: "6"; case 23: "5"
        case 24: "="; case 25: "9"; case 26: "7"; case 27: "-"; case 28: "8"; case 29: "0"
        case 30: "]"; case 31: "O"; case 32: "U"; case 33: "["; case 34: "I"; case 35: "P"
        case 36: "回车"; case 37: "L"; case 38: "J"; case 39: "'"; case 40: "K"; case 41: ";"
        case 42: "\\"; case 43: ","; case 44: "/"; case 45: "N"; case 46: "M"; case 47: "."
        case 48: "Tab"; case 49: "空格"; case 50: "`"; case 51: "删除"
        case 53: "Esc"; case 65: "小键盘."; case 67: "小键盘*"; case 69: "小键盘+"
        case 71: "小键盘清除"; case 75: "小键盘/"; case 76: "小键盘回车"; case 78: "小键盘-"
        case 82: "小键盘0"; case 83: "小键盘1"; case 84: "小键盘2"; case 85: "小键盘3"
        case 86: "小键盘4"; case 87: "小键盘5"; case 88: "小键盘6"; case 89: "小键盘7"
        case 91: "小键盘8"; case 92: "小键盘9"
        case 96: "F5"; case 97: "F6"; case 98: "F7"; case 99: "F3"; case 100: "F8"
        case 101: "F9"; case 103: "F11"; case 105: "F13"; case 106: "F16"; case 107: "F14"
        case 109: "F10"; case 111: "F12"; case 113: "F15"; case 114: "帮助"; case 115: "Home"
        case 116: "PageUp"; case 117: "前删"; case 118: "F4"; case 119: "End"; case 120: "F2"
        case 121: "PageDown"; case 122: "F1"; case 123: "←"; case 124: "→"; case 125: "↓"; case 126: "↑"
        default: "键\(keyCode)"
        }
    }
}
