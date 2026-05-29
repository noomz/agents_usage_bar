import Foundation

/// Actor owning the single long-lived polling `Task` that drives `AggregateStore.refresh(now:)`.
///
/// Design constraints (B7):
/// - Holds a **strong, direct reference** to `AggregateStore` — no `StoreRefreshable` protocol seam.
/// - Phase 2 sleep/wake observers will call `stop()` / `start()` externally via `NSWorkspace` —
///   no extra protocol needed now.
///
/// Polling loop pattern (POLL-01 / CLAUDE.md "Concurrency & Polling Pattern"):
/// - One `Task<Void, Never>` slot — `start()` always cancels any prior task before creating one.
/// - Loop: `await store.refresh(now:) → try? await Task.sleep(for:) → repeat`.
/// - `try?` on sleep absorbs cancellation cleanly; `Task.isCancelled` check prevents an extra
///   refresh after cancellation.
/// - NO `Timer.scheduledTimer`, NO `DispatchSourceTimer`, NO `AsyncTimerSequence`,
///   NO `Combine`, NO `Timer.publish` — pure structured concurrency only (CLAUDE.md).
public actor PollScheduler {

    // MARK: - Dependencies

    /// Strong direct reference to the aggregate store (B7 — no protocol seam).
    private let store: AggregateStore
    private let clock: any Clock

    // MARK: - State

    private var interval: RefreshInterval
    private var task: Task<Void, Never>?

    // MARK: - Init

    /// Creates a scheduler wired directly to `store`.
    ///
    /// - Parameters:
    ///   - store: The `AggregateStore` to drive. Strong reference.
    ///   - clock: Wall-clock source injected for testability.
    ///   - interval: Initial polling cadence. Defaults to `.m5` (POLL-02 / D-15).
    public init(store: AggregateStore, clock: any Clock, interval: RefreshInterval = .m5) {
        self.store = store
        self.clock = clock
        self.interval = interval
    }

    // MARK: - Public API

    /// Starts the polling loop.
    ///
    /// If a loop is already running, it is cancelled and replaced (POLL-01: single-task guarantee).
    /// If `interval == .manual`, returns immediately without spawning a loop.
    public func start() {
        // Cancel any existing loop — enforces POLL-01 single-task invariant.
        task?.cancel()
        task = nil

        // .manual means no automatic loop — only popover-open refresh triggers are active.
        guard let duration = interval.seconds.map({ Duration.seconds($0) }) else {
            return
        }

        // Capture values so a subsequent `updateInterval` doesn't bleed into this loop.
        let capturedStore = store
        let capturedClock = clock
        let capturedDuration = duration

        task = Task {
            while !Task.isCancelled {
                await capturedStore.refresh(now: capturedClock.now())
                if Task.isCancelled { break }
                try? await Task.sleep(for: capturedDuration)
            }
        }
    }

    /// Cancels the running loop (if any) and clears the task slot.
    ///
    /// In-flight `URLSession` requests are cancelled via structured concurrency propagation (POLL-07).
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Replaces the current loop with a new one running at `new` cadence.
    ///
    /// Equivalent to `stop()` + updating `interval` + `start()`.
    public func updateInterval(_ new: RefreshInterval) {
        interval = new
        task?.cancel()
        task = nil
        start()
    }

    /// Returns `true` if a non-cancelled polling loop is active.
    public func isRunning() -> Bool {
        guard let t = task else { return false }
        return !t.isCancelled
    }

    /// Returns the current polling interval.
    public func currentInterval() -> RefreshInterval {
        interval
    }
}
