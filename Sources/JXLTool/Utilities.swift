// Shared CLI utilities.

import Foundation

func formatBytes(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
    return String(format: "%.2f MB", Double(bytes) / (1024 * 1024))
}

/// Short human-readable label for a channel count. Used by the CLI
/// progress messages.
func channelDescription(_ channels: Int) -> String {
    switch channels {
    case 1: return "grayscale"
    case 2: return "grayscale+alpha"
    case 3: return "RGB"
    case 4: return "RGBA"
    default: return "\(channels)-channel"
    }
}

struct StandardError: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}
nonisolated(unsafe) var standardError = StandardError()
