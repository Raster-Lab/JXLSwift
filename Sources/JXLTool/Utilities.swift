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
