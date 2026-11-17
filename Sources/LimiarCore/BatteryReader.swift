import Foundation
import IOKit

/// Snapshot of the AppleSmartBattery registry entry.
public struct BatteryReading: Codable, Equatable, Sendable {
    public var soc: Int                 // 0...100 (CurrentCapacity, MaxCapacity == 100 on Apple Silicon)
    public var isCharging: Bool
    public var externalConnected: Bool  // false while CHIE cuts the adapter, even if plugged in
    public var fullyCharged: Bool
    public var amperage: Int            // mA, negative = discharging
    public var cycleCount: Int
    public var healthPercent: Int       // AppleRawMaxCapacity / DesignCapacity
    /// Physical charger signals that may survive a CHIE cut (used only for display).
    public var rawExternalConnected: Bool
    public var adapterWatts: Int

    public init(soc: Int, isCharging: Bool, externalConnected: Bool, fullyCharged: Bool = false,
                amperage: Int = 0, cycleCount: Int = 0, healthPercent: Int = 100,
                rawExternalConnected: Bool? = nil, adapterWatts: Int = 0) {
        self.soc = soc
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.fullyCharged = fullyCharged
        self.amperage = amperage
        self.cycleCount = cycleCount
        self.healthPercent = healthPercent
        self.rawExternalConnected = rawExternalConnected ?? externalConnected
        self.adapterWatts = adapterWatts
    }
}

public enum BatteryReader {
    public enum ReadError: Error { case serviceNotFound, propertiesUnavailable }

    public static func read() throws -> BatteryReading {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { throw ReadError.serviceNotFound }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any]
        else { throw ReadError.propertiesUnavailable }

        func int(_ key: String) -> Int { (dict[key] as? NSNumber)?.intValue ?? 0 }
        func bool(_ key: String) -> Bool { (dict[key] as? NSNumber)?.boolValue ?? false }

        let maxCap = max(int("MaxCapacity"), 1)
        let soc = min(100, max(0, int("CurrentCapacity") * 100 / maxCap))
        let design = int("DesignCapacity")
        let rawMax = int("AppleRawMaxCapacity")
        let health = design > 0 ? Int((Double(rawMax) / Double(design) * 100).rounded()) : 100
        // InstantAmperage is a signed 64-bit value exposed as unsigned; reinterpret.
        let amperage = Int(truncatingIfNeeded: (dict["InstantAmperage"] as? NSNumber)?.int64Value ?? 0)

        return BatteryReading(
            soc: soc,
            isCharging: bool("IsCharging"),
            externalConnected: bool("ExternalConnected"),
            fullyCharged: bool("FullyCharged"),
            amperage: amperage,
            cycleCount: int("CycleCount"),
            healthPercent: health,
            rawExternalConnected: bool("AppleRawExternalConnected"),
            adapterWatts: ((dict["AdapterDetails"] as? [String: Any])?["Watts"] as? NSNumber)?.intValue ?? 0
        )
    }
}
