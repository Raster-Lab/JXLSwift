/// Work-Stealing Thread Pool for Multi-Core Scaling
///
/// Provides a high-throughput thread pool that maximises utilisation of all
/// available CPU cores by allowing idle threads to steal work from busy threads.
///
/// # Design
/// Each worker thread owns a double-ended queue (deque) of pending work items.
/// When a thread's own deque is empty it attempts to steal a work item from the
/// back of another randomly-chosen worker's deque.  This strategy balances load
/// without a central bottleneck and achieves near-linear scaling on workloads
/// where individual tasks are roughly equal in cost (such as DCT blocks).
///
/// # Usage
/// ```swift
/// let pool = WorkStealingThreadPool()
/// for block in dctBlocks {
///     pool.submit {
///         process(block)
///     }
/// }
/// pool.waitForAll()
/// ```
///
/// # Thread Safety
/// All public methods are thread-safe and may be called from any thread.

import Foundation

// MARK: - WorkItem

/// A single unit of work for the thread pool.
private final class WorkItem: @unchecked Sendable {
    let body: @Sendable () -> Void
    init(_ body: @Sendable @escaping () -> Void) {
        self.body = body
    }
}

// MARK: - WorkDeque

/// A thread-safe double-ended queue used as each worker's local task list.
///
/// The owning worker pushes and pops from the *back* (LIFO order for
/// cache-warm reuse); stealing threads pop from the *front* (FIFO order).
private final class WorkDeque: @unchecked Sendable {
    private var items: [WorkItem] = []
    private let lock = NSLock()

    /// Push a work item to the back of the deque (called by the owner).
    func pushBack(_ item: WorkItem) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    /// Pop a work item from the back (called by the owner — LIFO).
    func popBack() -> WorkItem? {
        lock.lock()
        defer { lock.unlock() }
        return items.isEmpty ? nil : items.removeLast()
    }

    /// Steal a work item from the front (called by other workers — FIFO).
    func stealFront() -> WorkItem? {
        lock.lock()
        defer { lock.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
    }
}

// MARK: - WorkStealingThreadPool

/// A fixed-size thread pool with per-thread work queues and work-stealing.
///
/// Prefer this over `DispatchQueue.concurrentPerform` when:
/// - Tasks have non-uniform cost and queue balance matters.
/// - You need a persistent pool (avoids thread-creation overhead per call).
/// - You require explicit `waitForAll()` without a DispatchGroup at each call site.
public final class WorkStealingThreadPool: @unchecked Sendable {

    // MARK: - Configuration

    /// Number of worker threads in the pool.
    public let threadCount: Int

    // MARK: - State

    private var deques: [WorkDeque]
    private var threads: [Thread] = []

    /// Protects `incomingQueue`.
    private let incomingLock = NSLock()
    private var incomingQueue: [WorkItem] = []

    /// Wakes idle worker threads when new work arrives.
    private let semaphore = DispatchSemaphore(value: 0)

    /// Shutdown flag.
    private let shutdownLock = NSLock()
    private var _isShutdown = false

    /// Pending-work counter.  Protected by `pendingCondition` (its own internal lock).
    private let pendingCondition = NSCondition()
    private var _pendingCount: Int = 0

    // MARK: - Lifecycle

    /// Create a thread pool.
    ///
    /// - Parameter threadCount: Number of worker threads.  Defaults to the
    ///   number of active processor cores to maximise throughput without
    ///   over-subscribing.
    public init(threadCount: Int? = nil) {
        let count = threadCount ?? max(1, ProcessInfo.processInfo.activeProcessorCount)
        self.threadCount = count
        self.deques = (0..<count).map { _ in WorkDeque() }
        for i in 0..<count {
            let thread = Thread { [weak self] in self?.workerLoop(index: i) }
            thread.name = "JXLSwift.WorkStealingPool-\(i)"
            thread.qualityOfService = .userInitiated
            self.threads.append(thread)
        }
        // Start threads after self is fully initialised.
        threads.forEach { $0.start() }
    }

    deinit {
        shutdown()
    }

    // MARK: - Submission

    /// Submit a work item to the pool.
    ///
    /// - Parameter work: A `@Sendable` closure to execute on a worker thread.
    public func submit(_ work: @Sendable @escaping () -> Void) {
        let item = WorkItem(work)

        // Increment pending count *before* the item becomes visible to workers,
        // so that waitForAll() cannot slip past a zero count too early.
        pendingCondition.lock()
        _pendingCount += 1
        pendingCondition.unlock()

        incomingLock.lock()
        incomingQueue.append(item)
        incomingLock.unlock()

        semaphore.signal()
    }

    /// Submit a collection of work items and wait for all of them to finish.
    ///
    /// - Parameter works: Array of `@Sendable` closures.
    public func submitAll(_ works: [@Sendable () -> Void]) {
        for work in works {
            submit(work)
        }
        waitForAll()
    }

    // MARK: - Synchronisation

    /// Block the calling thread until all previously submitted work items
    /// have been executed.
    public func waitForAll() {
        pendingCondition.lock()
        while _pendingCount > 0 {
            // 500 ms timeout guards against spurious wake losses.
            pendingCondition.wait(until: Date(timeIntervalSinceNow: 0.5))
        }
        pendingCondition.unlock()
    }

    // MARK: - Statistics

    /// Total number of work items currently waiting or being executed.
    public var pendingCount: Int {
        pendingCondition.lock()
        defer { pendingCondition.unlock() }
        return _pendingCount
    }

    // MARK: - Shutdown

    /// Signal all worker threads to exit.
    ///
    /// Called automatically in `deinit`. Safe to call explicitly when the pool
    /// is no longer needed.
    public func shutdown() {
        shutdownLock.lock()
        let alreadyShutdown = _isShutdown
        _isShutdown = true
        shutdownLock.unlock()
        guard !alreadyShutdown else { return }
        // Wake all threads so they can observe the shutdown flag.
        for _ in 0..<threadCount {
            semaphore.signal()
        }
    }

    // MARK: - Worker Loop

    private func workerLoop(index: Int) {
        while true {
            // Check shutdown.
            shutdownLock.lock()
            let shouldStop = _isShutdown
            shutdownLock.unlock()
            if shouldStop { break }

            // Drain incoming queue into per-thread deques (round-robin).
            incomingLock.lock()
            if !incomingQueue.isEmpty {
                for (i, item) in incomingQueue.enumerated() {
                    deques[i % threadCount].pushBack(item)
                }
                incomingQueue.removeAll(keepingCapacity: true)
            }
            incomingLock.unlock()

            // Execute from own deque first (LIFO — cache-warm locality).
            if let item = deques[index].popBack() {
                item.body()
                markDone()
                continue
            }

            // Try to steal from another worker's deque (FIFO).
            var stolen = false
            for offset in 1..<threadCount {
                let victimIndex = (index + offset) % threadCount
                if let item = deques[victimIndex].stealFront() {
                    item.body()
                    markDone()
                    stolen = true
                    break
                }
            }
            if stolen { continue }

            // Nothing to do — park briefly (1 ms) to avoid a busy-wait.
            _ = semaphore.wait(timeout: .now() + 0.001)
        }
    }

    private func markDone() {
        pendingCondition.lock()
        _pendingCount -= 1
        if _pendingCount <= 0 {
            _pendingCount = 0
            pendingCondition.broadcast()
        }
        pendingCondition.unlock()
    }
}

// MARK: - Shared Pool

/// Singleton thread pool shared across JXLSwift encoder/decoder instances.
///
/// Using a shared pool prevents over-subscription when multiple encoders
/// run concurrently in the same process.
public enum SharedThreadPool {
    /// The shared `WorkStealingThreadPool` instance.
    public static let shared = WorkStealingThreadPool()
}
