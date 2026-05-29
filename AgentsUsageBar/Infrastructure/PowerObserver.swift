import Foundation
import AppKit
import os

/// Observes macOS sleep/wake events and drives the polling scheduler accordingly.
///
/// **POLL-04**: On `willSleepNotification` → calls `scheduler.stop()` to pause the polling loop.
/// On `didWakeNotification` → checks day rollover, calls `store.refresh(now:)`, then `scheduler.start()`.
///
/// **Energy Impact (POLL-09)**: The polling loop uses `Task.sleep(for:)` which is App-Nap-friendly.
/// The sleep observer pauses the loop ENTIRELY on `willSleep`. Energy Impact is "Low" after 1h idle.
///
/// **Pitfall 4 (wake-then-immediate-threshold race)**: PowerObserver must be instantiated and
/// retained BEFORE the scheduler starts so the sleep/wake observers are live before any wake event.
/// `AppDependencies.makeProduction()` constructs the observer after the scheduler for this reason,
/// and `AgentsUsageBarApp` force-realizes it before calling `scheduler.start()`.
///
/// Note: `@MainActor` ensures all stored properties and closures are accessed on the main actor,
/// matching `AggregateStore`'s isolation (also `@MainActor`).
@MainActor
public final class PowerObserver {

    // MARK: - Private state

    private let store: AggregateStore
    private let scheduler: PollScheduler
    private let clock: any Clock

    // `nonisolated(unsafe)` for these last-cleanup-only properties: they are written
    // exactly once in `init` (on the main actor), then read solely by the nonisolated
    // `deinit`. NotificationCenter is thread-safe and `removeObserver(_:)` is callable
    // from any isolation context. This pattern is required because Swift 6 strict
    // concurrency forbids accessing non-Sendable stored properties from a nonisolated `deinit`.
    nonisolated(unsafe) private let notificationCenter: NotificationCenter
    nonisolated(unsafe) private var sleepToken: NSObjectProtocol?
    nonisolated(unsafe) private var wakeToken: NSObjectProtocol?

    private var lastKnownDay: String

    private let logger = AppLogger.logger(category: "power")

    // MARK: - Init

    /// Creates a `PowerObserver` and immediately subscribes to sleep/wake notifications.
    ///
    /// - Parameters:
    ///   - store: The aggregate store to refresh on wake.
    ///   - scheduler: The poll scheduler to stop on sleep and start on wake.
    ///   - clock: Clock abstraction for testable time comparisons.
    ///   - notificationCenter: Notification center to observe. Defaults to
    ///     `NSWorkspace.shared.notificationCenter`. Tests inject a fresh `NotificationCenter()`.
    public init(
        store: AggregateStore,
        scheduler: PollScheduler,
        clock: any Clock,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.store = store
        self.scheduler = scheduler
        self.clock = clock
        self.notificationCenter = notificationCenter
        self.lastKnownDay = TodayHelper.formatYYYYMMDD(clock.now())

        // Subscribe to willSleep — pause the polling loop to conserve energy (POLL-09).
        sleepToken = notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleSleep()
            }
        }

        // Subscribe to didWake — refresh data and resume polling.
        wakeToken = notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleWake()
            }
        }
    }

    deinit {
        if let token = sleepToken { notificationCenter.removeObserver(token) }
        if let token = wakeToken { notificationCenter.removeObserver(token) }
    }

    // MARK: - Internal handlers (accessible for direct testing)

    /// Called on `willSleepNotification`. Stops the scheduler (pauses polling loop).
    internal func handleSleep() async {
        logger.notice("sleep — pausing scheduler")
        await scheduler.stop()
    }

    /// Called on `didWakeNotification`. Detects day rollover, refreshes the store, then resumes polling.
    internal func handleWake() async {
        let now = clock.now()
        let today = TodayHelper.formatYYYYMMDD(now)
        if today != lastKnownDay {
            // Day rolled while asleep — UserDefaults FSM state is date-keyed; new day = new empty
            // allRecordsForToday(<new>) — no explicit reset required (RESEARCH §D.1).
            logger.notice("wake — day rolled \(self.lastKnownDay, privacy: .public) → \(today, privacy: .public)")
            lastKnownDay = today
        } else {
            logger.notice("wake — refreshing")
        }
        await store.refresh(now: now)
        await scheduler.start()
    }
}
