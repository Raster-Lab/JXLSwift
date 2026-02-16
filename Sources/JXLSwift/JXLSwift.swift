/// JXLSwift - A native Swift implementation of JPEG XL (ISO/IEC 18181) compression codec
///
/// This library provides a pure Swift implementation of the JPEG XL image compression
/// standard, optimized for Apple Silicon hardware with fallback support for x86-64.
///
/// # Features
/// - Native Swift implementation
/// - Apple Silicon optimizations (ARM NEON, SIMD)
/// - Apple Accelerate framework integration
/// - Metal GPU acceleration support
/// - Modular (lossless) and VarDCT (lossy) compression modes
///
/// # Architecture
/// The library is organized into several key modules:
/// - Core: Fundamental data structures and types
/// - Encoding: Compression pipeline implementation
/// - Hardware: Platform-specific optimizations
/// - Format: JPEG XL file format support

/// JXLSwift main namespace
public enum JXLSwift {
    /// Library version
    public static let version = "0.1.0"
    
    /// ISO/IEC standard version
    public static let standardVersion = "18181-1:2024"
}
