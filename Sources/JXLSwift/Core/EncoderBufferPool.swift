/// General-purpose reusable buffer pool for the JXLSwift encoder and decoder.
///
/// The encoder's inner loops allocate a large number of small-to-medium `[Float]`
/// and `[UInt8]` arrays (channel planes, DCT blocks, entropy symbol buffers).
/// Allocating these on every call causes GC pressure and fragmentation.
///
/// `EncoderBufferPool` maintains a thread-safe free list of previously-used
/// buffers.  Callers borrow a buffer of at least `minimumCapacity` elements,
/// use it, then return it via `release(_:)`.  Returned buffers are cleared and
/// recycled; they are never returned to Swift's allocator until the pool itself
/// is deallocated.
///
/// # Usage
/// ```swift
/// let pool = EncoderBufferPool<Float>()
/// var buffer = pool.acquire(minimumCapacity: 256)
/// // … fill and process buffer …
/// pool.release(&buffer)   // returns buffer to free list
/// ```
///
/// # Thread Safety
/// All operations on `EncoderBufferPool` are thread-safe.  Multiple encoder
/// threads may share a single pool instance.

import Foundation

// MARK: - EncoderBufferPool

/// A thread-safe pool of reusable arrays.
///
/// - Note: The pool is generic over element type `T`.  Separate pool instances
///   should be used for `Float`, `UInt8`, `Int32`, etc.
public final class EncoderBufferPool<T>: @unchecked Sendable {

    // MARK: - Configuration

    /// Maximum number of buffers to keep in the free list.
    /// Buffers beyond this limit are simply released to Swift's allocator.
    public let maxPoolSize: Int

    // MARK: - State (protected by `lock`)

    private let lock = NSLock()
    private var freeList: [[T]] = []

    // MARK: - Statistics

    private var _acquireCount: Int = 0
    private var _hitCount: Int = 0

    // MARK: - Lifecycle

    /// Create a pool.
    ///
    /// - Parameter maxPoolSize: Maximum number of buffers retained in the pool.
    ///   Defaults to `ProcessInfo.processInfo.activeProcessorCount * 2` to avoid
    ///   unbounded growth on highly parallel workloads.
    public init(maxPoolSize: Int? = nil) {
        self.maxPoolSize = maxPoolSize ?? max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
    }

    // MARK: - Acquire / Release

    /// Borrow a buffer with at least `minimumCapacity` elements.
    ///
    /// If the pool contains a suitable buffer it is returned directly;
    /// otherwise a new buffer is allocated.  The returned buffer is **not**
    /// guaranteed to be zeroed — callers must initialise before use.
    ///
    /// - Parameter minimumCapacity: Required element count.
    /// - Returns: A buffer with `count >= minimumCapacity`.
    public func acquire(minimumCapacity: Int) -> [T] {
        lock.lock()
        _acquireCount += 1

        // Try to find a buffer that fits in the free list (best-fit)
        if let idx = freeList.indices.first(where: { freeList[$0].capacity >= minimumCapacity }) {
            let buffer = freeList.remove(at: idx)
            _hitCount += 1
            lock.unlock()
            return buffer
        }

        lock.unlock()
        // No suitable buffer in the pool — allocate a new one.
        // Use next power-of-two capacity to reduce future misses.
        let capacity = nextPowerOfTwo(minimumCapacity)
        var buf: [T] = []
        buf.reserveCapacity(capacity)
        return buf
    }

    /// Return a buffer to the pool for future reuse.
    ///
    /// The buffer is cleared (`removeAll(keepingCapacity: true)`) before being
    /// stored.  If the free list is already at `maxPoolSize` the buffer is
    /// simply discarded.
    ///
    /// - Parameter buffer: The buffer to return.  Passed `inout` so the caller's
    ///   reference is cleared, preventing accidental use-after-return.
    public func release(_ buffer: inout [T]) {
        var toReturn = buffer
        buffer = []
        toReturn.removeAll(keepingCapacity: true)

        lock.lock()
        defer { lock.unlock() }
        guard freeList.count < maxPoolSize else { return }
        freeList.append(toReturn)
    }

    // MARK: - Statistics

    /// Total number of `acquire` calls since the pool was created.
    public var acquireCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _acquireCount
    }

    /// Number of `acquire` calls that were served from the free list.
    public var hitCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _hitCount
    }

    /// Cache hit rate (0–1).
    public var hitRate: Double {
        lock.lock(); defer { lock.unlock() }
        guard _acquireCount > 0 else { return 0 }
        return Double(_hitCount) / Double(_acquireCount)
    }

    /// Number of buffers currently in the free list.
    public var freeListCount: Int {
        lock.lock(); defer { lock.unlock() }
        return freeList.count
    }

    /// Remove all buffers from the free list, releasing their memory.
    public func drain() {
        lock.lock(); defer { lock.unlock() }
        freeList.removeAll(keepingCapacity: false)
    }

    // MARK: - Private Helpers

    private func nextPowerOfTwo(_ n: Int) -> Int {
        guard n > 0 else { return 1 }
        var p = 1
        while p < n { p <<= 1 }
        return p
    }
}

// MARK: - Shared Encoding Pools

/// Shared buffer pools for the encoding pipeline.
///
/// Using shared pools allows multiple consecutive encode calls (e.g. in an
/// animation loop) to reuse the same channel-plane buffers without extra
/// allocations.
///
/// # Thread Safety
/// All pool instances are thread-safe. Different encoders may call into the
/// same shared pool concurrently.
public enum SharedEncodingPools {
    /// Pool for `[Float]` channel-plane and DCT-coefficient buffers.
    public static let floatPool = EncoderBufferPool<Float>()

    /// Pool for `[UInt8]` bitstream output buffers.
    public static let bytePool = EncoderBufferPool<UInt8>()

    /// Pool for `[Int32]` quantised-coefficient buffers.
    public static let int32Pool = EncoderBufferPool<Int32>()

    /// Reset statistics on all shared pools (useful between benchmark runs).
    public static func drainAll() {
        floatPool.drain()
        bytePool.drain()
        int32Pool.drain()
    }
}
