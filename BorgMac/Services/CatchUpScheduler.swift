import Foundation
import AppKit

/// Starts scheduled backups whose last slot was missed.
///
/// launchd fires `StartCalendarInterval` jobs that were due while the Mac
/// slept as soon as it wakes, but not jobs that were due while it was shut
/// down, and an hourly `StartInterval` job only fires one full interval
/// after it is loaded at login. So when BorgMac starts (typically as a
/// login item after a reboot), wakes, or joins a different Wi-Fi network,
/// it checks every schedule: if the last successful run is older than the
/// most recent slot the schedule should have fired at, the launchd job is
/// kickstarted right away.
///
/// Kickstarting goes through launchd (same as "Run now"), so the backup
/// runs in the usual headless runner and launchd itself guarantees that a
/// job already running under the same label is not started twice.
@MainActor
final class CatchUpScheduler {
    static let shared = CatchUpScheduler()

    /// Delay after launch / wake before checking, so the network (and any
    /// VPN or mounted volume) has a chance to come up first.
    static let settleDelay: TimeInterval = 45
    /// Don't kick the same schedule again within this window, so a run
    /// that keeps failing doesn't restart on every network blip.
    static let cooldown: TimeInterval = 15 * 60
    /// Grace after a slot passes during which launchd itself is expected
    /// to be starting the job.
    static let slotGrace: TimeInterval = 2 * 60
    /// After a kickstart, treat the repository as busy for this long even
    /// if the runner hasn't written `running: true` to its status file yet.
    static let kickSettle: TimeInterval = 60
    /// How soon to check again when an overdue schedule had to wait for
    /// another backup of the same repository.
    static let busyRecheck: TimeInterval = 5 * 60

    private var lastKick: [UUID: Date] = [:]
    private var pending: DispatchWorkItem?
    private var started = false

    /// Hooks the scheduler up to launch, wake and Wi-Fi changes. Idempotent.
    func start() {
        guard !started else { return }
        started = true

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in CatchUpScheduler.shared.scheduleCheck(after: Self.settleDelay, reason: "wake") }
        }

        WiFiMonitor.shared.onNetworkChange = { _ in
            CatchUpScheduler.shared.scheduleCheck(after: 15, reason: "network change")
        }

        scheduleCheck(after: Self.settleDelay, reason: "launch")
    }

    /// Debounced check: a newer request replaces a pending one.
    func scheduleCheck(after delay: TimeInterval, reason: String) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.runOverdueSchedules(reason: reason) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func runOverdueSchedules(reason: String, now: Date = Date()) {
        WiFiMonitor.shared.refresh()
        var deferred = false
        for repo in Self.loadRepositories() {
            // One backup per repository at a time: borg holds an exclusive
            // repository lock, so a second run would only wait on it (or
            // fail once `--lock-wait` runs out). Skip the repo while any of
            // its schedules is running or was just kicked, and start at
            // most one overdue schedule per check. The rest are picked up
            // by the follow-up check below.
            var repoBusy = repo.schedules.contains { schedule in
                if BackupStatusFile.read(for: schedule.id)?.running == true { return true }
                if let last = lastKick[schedule.id], now.timeIntervalSince(last) < Self.kickSettle { return true }
                return false
            }

            for schedule in repo.schedules {
                guard ScheduleManager.isInstalled(repoId: repo.id, scheduleId: schedule.id) else { continue }
                let status = BackupStatusFile.read(for: schedule.id)
                guard Self.isOverdue(schedule: schedule, status: status, now: now) else { continue }
                if let last = lastKick[schedule.id], now.timeIntervalSince(last) < Self.cooldown { continue }
                // Don't spawn a runner that would only skip.
                if WiFiNetwork.skipReason(for: schedule) != nil { continue }

                if repoBusy {
                    deferred = true
                    continue
                }

                do {
                    try ScheduleManager.kickstart(repoId: repo.id, scheduleId: schedule.id)
                    lastKick[schedule.id] = now
                    repoBusy = true
                    NSLog("%@", "BorgMac: catch-up (\(reason)) started \(repo.name) / \(schedule.displayName)")
                } catch {
                    NSLog("%@", "BorgMac: catch-up kickstart failed for \(schedule.id): \(error.localizedDescription)")
                }
            }
        }
        // Another overdue schedule is waiting for its repository to be
        // free: look again later instead of waiting for the next wake or
        // network change.
        if deferred {
            scheduleCheck(after: Self.busyRecheck, reason: "repository busy")
        }
    }

    /// True when the schedule's most recent slot passed without a run.
    static func isOverdue(
        schedule: BackupSchedule,
        status: BackupRunStatus?,
        now: Date = Date()
    ) -> Bool {
        guard schedule.catchUpMissedRuns, !schedule.paths.isEmpty else { return false }
        if status?.running == true { return false }
        guard let slot = ScheduleManager.previousFireDate(for: schedule, before: now) else { return false }
        if schedule.frequency != .hourly, now.timeIntervalSince(slot) < slotGrace { return false }

        // Prefer the last success; fall back to the last attempt (so a
        // schedule that has never succeeded isn't restarted after every
        // failure) and then to the creation date (so a brand-new schedule
        // doesn't fire the moment it's saved). Schedules from before
        // `createdAt` existed that have never run count as overdue.
        guard let reference = status?.lastSuccess ?? status?.lastRun ?? schedule.createdAt else {
            return true
        }
        return reference < slot
    }

    private static func loadRepositories() -> [Repository] {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = support.appendingPathComponent("BorgMac/repositories.json")
        guard let data = try? Data(contentsOf: url),
              let repos = try? JSONDecoder().decode([Repository].self, from: data) else {
            return []
        }
        return repos
    }
}
