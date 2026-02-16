/// Shared utilities for the jxl-tool command line interface

import Foundation

/// Format byte count as a human-readable string
func formatBytes(_ bytes: Int) -> String {
    if bytes < 1024 {
        return "\(bytes) B"
    } else if bytes < 1024 * 1024 {
        return String(format: "%.1f KB", Double(bytes) / 1024)
    } else {
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

/// A `TextOutputStream` that writes to standard error.
struct StandardError: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}

/// Standard error output stream for error messages.
nonisolated(unsafe) var standardError = StandardError()
