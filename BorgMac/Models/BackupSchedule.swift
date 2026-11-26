import Foundation

struct BackupSchedule: Codable, Hashable, Identifiable {
    enum Frequency: String, Codable, CaseIterable, Identifiable {
        case hourly, daily, weekly
        var id: String { rawValue }
        var label: String {
            switch self {
            case .hourly: return "Hourly"
            case .daily:  return "Daily"
            case .weekly: return "Weekly"
            }
        }
    }

    var id: UUID = UUID()
    /// Short user-visible label ("Fotos diarias", "Downloads horario"). Free
    /// form; can be empty and the UI falls back to the frequency.
    var name: String = ""
    var frequency: Frequency = .daily
    /// 0–23. Ignored for `.hourly`.
    var hour: Int = 3
    /// 0–59. Ignored for `.hourly`.
    var minute: Int = 0
    /// launchd convention: 0 = Sunday … 6 = Saturday. Only used for `.weekly`.
    var weekday: Int = 1
    var paths: [String] = []
    /// Borg exclude patterns passed as `--exclude <pattern>` to `borg create`.
    /// Supports shell-style globs (`**/node_modules`, `*.log`, `*/Library/Caches`).
    var excludes: [String] = []
    var keepDaily: Int = 0
    var keepWeekly: Int = 0
    var keepMonthly: Int = 0
    /// Wi-Fi network names (SSIDs) this schedule may run on. Empty means
    /// "any network". When non-empty, a run that fires while the Mac is on
    /// another network (or not on Wi-Fi at all) is skipped, not failed.
    var allowedWiFiNetworks: [String] = []
    /// When true, the GUI starts this schedule right away at launch (and
    /// when the Mac joins an allowed Wi-Fi) if its last scheduled slot was
    /// missed, e.g. because the Mac was shut down at that time.
    var catchUpMissedRuns: Bool = true
    /// When the schedule was created. Used as the reference for catch-up
    /// before the first run has happened. Nil for schedules saved before
    /// this field existed.
    var createdAt: Date?

    /// True when the schedule is limited to specific Wi-Fi networks.
    var isNetworkRestricted: Bool { !allowedWiFiNetworks.isEmpty }

    /// True when any `--keep-*` value is set, i.e. the scheduled run
    /// should prune (and compact) the repository after backing up.
    var hasRetention: Bool { keepDaily > 0 || keepWeekly > 0 || keepMonthly > 0 }

    /// Decoder that tolerates missing fields — keeps legacy schedules (saved
    /// before multi-job support landed) readable. Any missing `id` gets a
    /// fresh UUID so the migration path can install a correctly-labeled plist.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decodeIfPresent(UUID.self,   forKey: .id)          ?? UUID()
        name        = try c.decodeIfPresent(String.self, forKey: .name)        ?? ""
        frequency   = try c.decodeIfPresent(Frequency.self, forKey: .frequency) ?? .daily
        hour        = try c.decodeIfPresent(Int.self,    forKey: .hour)        ?? 3
        minute      = try c.decodeIfPresent(Int.self,    forKey: .minute)      ?? 0
        weekday     = try c.decodeIfPresent(Int.self,    forKey: .weekday)     ?? 1
        paths       = try c.decodeIfPresent([String].self, forKey: .paths)     ?? []
        excludes    = try c.decodeIfPresent([String].self, forKey: .excludes)  ?? []
        keepDaily   = try c.decodeIfPresent(Int.self,    forKey: .keepDaily)   ?? 0
        keepWeekly  = try c.decodeIfPresent(Int.self,    forKey: .keepWeekly)  ?? 0
        keepMonthly = try c.decodeIfPresent(Int.self,    forKey: .keepMonthly) ?? 0
        allowedWiFiNetworks = try c.decodeIfPresent([String].self, forKey: .allowedWiFiNetworks) ?? []
        catchUpMissedRuns = try c.decodeIfPresent(Bool.self, forKey: .catchUpMissedRuns) ?? true
        createdAt   = try c.decodeIfPresent(Date.self,   forKey: .createdAt)
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        frequency: Frequency = .daily,
        hour: Int = 3,
        minute: Int = 0,
        weekday: Int = 1,
        paths: [String] = [],
        excludes: [String] = [],
        keepDaily: Int = 0,
        keepWeekly: Int = 0,
        keepMonthly: Int = 0,
        allowedWiFiNetworks: [String] = [],
        catchUpMissedRuns: Bool = true,
        createdAt: Date? = Date()
    ) {
        self.id = id
        self.name = name
        self.frequency = frequency
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.paths = paths
        self.excludes = excludes
        self.keepDaily = keepDaily
        self.keepWeekly = keepWeekly
        self.keepMonthly = keepMonthly
        self.allowedWiFiNetworks = allowedWiFiNetworks
        self.catchUpMissedRuns = catchUpMissedRuns
        self.createdAt = createdAt
    }

    /// Human-readable label used in the UI. Falls back to the frequency if
    /// the user didn't name the schedule.
    var displayName: String {
        name.isEmpty ? frequency.label : name
    }

    /// Common exclusion patterns offered as a one-click preset in both the
    /// schedule editor and the manual backup sheet. Kept deliberately short —
    /// anything more obscure the user can type in themselves.
    static let commonExcludePresets: [String] = [
        "**/.DS_Store",
        "**/node_modules",
        "**/__pycache__",
        "**/.venv",
        "**/target",
        "sh:*/Library/Caches",
    ]
}

struct BackupRunStatus: Codable, Hashable {
    var lastRun: Date?
    var lastSuccess: Date?
    var lastError: String?
    var lastArchiveName: String?
    var running: Bool = false
    /// Current attempt number (1-based) while `running == true`. Nil when idle.
    var attempt: Int?
    /// Total attempts the runner will make before giving up. Nil when idle.
    var maxAttempts: Int?

    // MARK: - Live progress (populated while `running == true`)
    //
    // These come from `borg create --log-json --progress` events that
    // the scheduled runner parses and writes back to the status file.
    // They're all optional because manual backups and older status files
    // don't carry them.

    /// Cumulative pre-compression bytes read from the filesystem.
    var progressOriginalBytes: Int64?
    /// Cumulative compressed bytes (after compression, before dedup).
    var progressCompressedBytes: Int64?
    /// Cumulative bytes actually written to the repo after dedup.
    var progressDedupedBytes: Int64?
    /// Number of files processed so far.
    var progressFileCount: Int?
    /// Path borg was working on at the last tick. Shown below the bar.
    var progressCurrentPath: String?
    /// When borg emitted the most recent progress event — used to hide
    /// stale progress data if a run crashed without clearing the flag.
    var progressUpdatedAt: Date?
    /// Wall-clock time the current attempt started, captured on first
    /// `markAttempt`. Used together with `progressOriginalBytes` to
    /// compute a rough ETA for the menu bar UI.
    var progressStartedAt: Date?

    /// Final `original_size` of the previous successful run. The UI
    /// divides the live `progressOriginalBytes` by this to turn the
    /// indeterminate borg progress into a percentage. Cleared when no
    /// successful run exists yet.
    var lastTotalOriginalBytes: Int64?

    /// PID of the headless `--run-backup` process that wrote this status.
    /// Used as a liveness check on GUI startup: if `running == true` but
    /// this pid is no longer alive (crashed, SIGKILLed, or killed by
    /// `launchctl kill` without the signal handler running to
    /// completion), the GUI rewrites the status as failed so the
    /// "in progress" UI doesn't wedge forever.
    var runnerPid: Int32?

    /// When the runner last decided not to run (e.g. not on an allowed
    /// Wi-Fi network). A skip is not a failure: `lastRun` / `lastError`
    /// are left untouched so the missed slot is still caught up later.
    var lastSkipped: Date?
    /// Human-readable reason for `lastSkipped`.
    var lastSkipReason: String?
}
