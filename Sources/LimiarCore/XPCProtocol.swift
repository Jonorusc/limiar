import Foundation

public enum LimiarIDs {
    public static let daemonMachService = "app.limiar.daemon"
    public static let daemonPlistName = "app.limiar.daemon.plist"
    public static let appBundleID = "app.limiar.Limiar"
    public static let logSubsystem = "app.limiar"
    /// Legacy v1 install (pre-rename), removed on upgrade.
    public static let legacyDaemonLabel = "com.joaolucas.limiar.daemon"
    /// Bumped whenever the daemon/app wire contract or behaviour changes.
    public static let version = "1.1.0"
}

/// Errors are sent as codes so the app can localize them.
public enum DaemonError: Codable, Equatable, Sendable {
    case batteryReadFailed
    case smcWriteFailed(key: String)
}

/// Calls from the menu bar app into the root daemon. Payloads are JSON (`Wire`) to avoid
/// NSSecureCoding boilerplate; replies carry an error message or nil on success.
@objc public protocol LimiarDaemonProtocol {
    /// Registers the caller for push updates and returns the current `DaemonStatus`.
    func subscribe(reply: @escaping @Sendable (Data) -> Void)
    func updateSettings(_ settings: Data, reply: @escaping @Sendable (String?) -> Void)
    func setMode(_ mode: Data, reply: @escaping @Sendable (String?) -> Void)
}

/// Calls from the daemon back into the app (exported by the app on the same connection).
@objc public protocol LimiarClientProtocol {
    func statusDidChange(_ status: Data)
    func didEmit(_ notice: Data)
}

public struct DaemonStatus: Codable, Equatable, Sendable {
    public var battery: BatteryReading?
    public var adapterEnabled: Bool
    public var settings: Settings
    public var mode: ChargeMode
    public var scheduledWake: Date?
    public var lastError: DaemonError?
    public var daemonVersion: String
    public var hasMagSafeLED: Bool
    /// Modification time of the running daemon executable; lets the app detect a stale daemon
    /// after the bundle was replaced (even when the version string didn't change).
    public var executableStamp: Double?

    public init(battery: BatteryReading?, adapterEnabled: Bool, settings: Settings, mode: ChargeMode,
                scheduledWake: Date? = nil, lastError: DaemonError? = nil, daemonVersion: String = LimiarIDs.version,
                hasMagSafeLED: Bool = false, executableStamp: Double? = nil) {
        self.battery = battery
        self.adapterEnabled = adapterEnabled
        self.settings = settings
        self.mode = mode
        self.scheduledWake = scheduledWake
        self.lastError = lastError
        self.daemonVersion = daemonVersion
        self.hasMagSafeLED = hasMagSafeLED
        self.executableStamp = executableStamp
    }

    // Tolerant decoding: app and daemon can briefly run different builds after an update.
    private enum CodingKeys: String, CodingKey {
        case battery, adapterEnabled, settings, mode, scheduledWake, lastError, daemonVersion, hasMagSafeLED, executableStamp
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        battery = try? c.decodeIfPresent(BatteryReading.self, forKey: .battery)
        adapterEnabled = try c.decodeIfPresent(Bool.self, forKey: .adapterEnabled) ?? true
        settings = (try? c.decodeIfPresent(Settings.self, forKey: .settings)) ?? Settings()
        mode = (try? c.decodeIfPresent(ChargeMode.self, forKey: .mode)) ?? .normal
        scheduledWake = try? c.decodeIfPresent(Date.self, forKey: .scheduledWake)
        lastError = try? c.decodeIfPresent(DaemonError.self, forKey: .lastError)
        daemonVersion = (try? c.decodeIfPresent(String.self, forKey: .daemonVersion)) ?? "unknown"
        hasMagSafeLED = (try? c.decodeIfPresent(Bool.self, forKey: .hasMagSafeLED)) ?? false
        executableStamp = try? c.decodeIfPresent(Double.self, forKey: .executableStamp)
    }

    /// Modification time of an executable, as used for `executableStamp`.
    public static func stamp(of url: URL?) -> Double? {
        guard let url, let date = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        else { return nil }
        return date.timeIntervalSince1970.rounded()
    }
}

public enum Wire {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
