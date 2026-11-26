import Foundation
import CoreWLAN
import CoreLocation

/// Reads the name (SSID) of the Wi-Fi network the Mac is currently on.
///
/// Since macOS 14, CoreWLAN only reveals the SSID to processes that have
/// Location Services authorization. The GUI asks for it (see
/// `WiFiMonitor`); the headless `--run-backup` process shares the app's
/// bundle and therefore its authorization, but launchd-spawned processes
/// don't always get the SSID even then. So the GUI also writes the SSID
/// it sees to a small cache file, and the runner falls back to that file
/// while the GUI process that wrote it is still alive (it keeps the file
/// current by watching for network changes).
///
/// Deliberately non-isolated so both the GUI and the runner can use it.
enum WiFiNetwork {
    /// Result of resolving the current network for a run decision.
    enum Resolution: Equatable {
        /// On Wi-Fi with this SSID.
        case connected(String)
        /// Wi-Fi is off or not associated with any network.
        case notConnected
        /// Wi-Fi is on, but macOS hides the network name from us
        /// (Location Services not granted to BorgMac).
        case unknown
    }

    // MARK: - Direct CoreWLAN read

    /// SSID as reported by CoreWLAN in this process, or nil when off Wi-Fi
    /// or when macOS hides it.
    static func currentSSIDDirect() -> String? {
        guard let iface = CWWiFiClient.shared().interface() else { return nil }
        guard let ssid = iface.ssid()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ssid.isEmpty else { return nil }
        return ssid
    }

    /// True when the Wi-Fi radio is on and associated with *some* network,
    /// even if the SSID itself is hidden from us.
    static func isAssociated() -> Bool {
        guard let iface = CWWiFiClient.shared().interface(), iface.powerOn() else { return false }
        // Neither the interface mode nor the RSSI is location-gated,
        // unlike ssid/bssid. Both read "nothing" when not associated.
        return iface.interfaceMode() != CWInterfaceMode.none || iface.rssiValue() != 0
    }

    // MARK: - Cache shared between GUI and runner

    struct Cache: Codable {
        var ssid: String?
        var associated: Bool
        var updatedAt: Date
        /// PID of the GUI process that keeps this file current.
        var writerPid: Int32
    }

    static var cacheURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("BorgMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("wifi.json")
    }

    static func writeCache(ssid: String?, associated: Bool) {
        let cache = Cache(ssid: ssid, associated: associated, updatedAt: Date(), writerPid: getpid())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    static func readCache() -> Cache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Cache.self, from: data)
    }

    // MARK: - Resolution

    /// Best answer to "which Wi-Fi are we on?" for the run decision.
    static func resolveCurrent() -> Resolution {
        if let ssid = currentSSIDDirect() {
            return .connected(ssid)
        }
        let associated = isAssociated()
        if !associated {
            return .notConnected
        }
        // Associated but SSID hidden: trust the GUI's cache if the GUI that
        // wrote it is still running (it updates the file on every change).
        if let cache = readCache(), isAlive(pid: cache.writerPid), cache.associated {
            if let ssid = cache.ssid, !ssid.isEmpty {
                return .connected(ssid)
            }
        }
        return .unknown
    }

    /// Returns nil when the schedule may run, or a human-readable reason
    /// why it must be skipped.
    static func skipReason(for schedule: BackupSchedule, resolution: Resolution? = nil) -> String? {
        guard schedule.isNetworkRestricted else { return nil }
        let allowed = schedule.allowedWiFiNetworks.joined(separator: ", ")
        switch resolution ?? resolveCurrent() {
        case .connected(let ssid):
            if schedule.allowedWiFiNetworks.contains(ssid) { return nil }
            return "on Wi-Fi \"\(ssid)\", allowed: \(allowed)"
        case .notConnected:
            return "not on Wi-Fi, allowed: \(allowed)"
        case .unknown:
            return "Wi-Fi name unavailable. Open BorgMac and allow Location Services so it can read the network name."
        }
    }

    private static func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }
}

/// GUI-side observer of the current Wi-Fi network. Owns the Location
/// Services authorization request, keeps `WiFiNetwork`'s cache file current
/// for the headless runner, and tells the catch-up scheduler when the
/// network changes so a backup that was skipped on the wrong network can
/// run as soon as the Mac joins an allowed one.
@MainActor
final class WiFiMonitor: NSObject, ObservableObject {
    static let shared = WiFiMonitor()

    @Published private(set) var currentSSID: String?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus

    /// Called on the main actor whenever the SSID changes.
    var onNetworkChange: (@MainActor (String?) -> Void)?

    private let locationManager = CLLocationManager()
    private let wifiClient = CWWiFiClient.shared()
    private var pollTimer: Timer?
    private var started = false

    override init() {
        authorizationStatus = locationManager.authorizationStatus
        super.init()
        locationManager.delegate = self
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedAlways
    }

    /// Starts watching. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        wifiClient.delegate = self
        try? wifiClient.startMonitoringEvent(with: .ssidDidChange)
        try? wifiClient.startMonitoringEvent(with: .linkDidChange)
        // Belt and braces: CoreWLAN events can be suppressed without
        // location authorization, so also poll cheaply.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    /// Asks macOS for Location Services authorization, which is required
    /// to read the Wi-Fi name. Only prompts when not determined yet.
    func requestAuthorization() {
        if authorizationStatus == .notDetermined {
            locationManager.requestAlwaysAuthorization()
        }
    }

    func refresh() {
        let ssid = WiFiNetwork.currentSSIDDirect()
        let associated = ssid != nil || WiFiNetwork.isAssociated()
        WiFiNetwork.writeCache(ssid: ssid, associated: associated)
        if ssid != currentSSID {
            currentSSID = ssid
            onNetworkChange?(ssid)
        }
    }
}

extension WiFiMonitor: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            self.refresh()
        }
    }
}

extension WiFiMonitor: CWEventDelegate {
    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in self.refresh() }
    }

    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor in self.refresh() }
    }
}
