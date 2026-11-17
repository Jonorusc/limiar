import CSMC
import Foundation

public struct SMCError: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public let key: String
    public let code: Int32
    public let kernReturn: Int32

    public var description: String {
        let kr = String(format: "0x%08x", UInt32(bitPattern: kernReturn))
        return "SMC \(operation) \(key) falhou (code=\(code), kr=\(kr))"
    }
}

/// Thin wrapper over the AppleSMC user client. Not thread-safe: use from one actor/thread.
public final class SMCClient {
    /// `CHIE` controls adapter (wall power) input. 0x00 = enabled, 0x08 = disabled.
    /// Verified writable as root on Mac16,12 / macOS 27.2 (firmware 20457.41.3).
    public static let adapterKey = "CHIE"
    static let adapterEnabledValue: UInt8 = 0x00
    static let adapterDisabledValue: UInt8 = 0x08

    private var conn: smc_conn_t = 0

    public init() throws {
        var c: smc_conn_t = 0
        let rc = smc_open(&c)
        guard rc == SMC_OK else {
            throw SMCError(operation: "open", key: "-", code: rc, kernReturn: smc_last_kern_return())
        }
        conn = c
    }

    deinit { smc_close(conn) }

    public func read(_ key: String) throws -> [UInt8] {
        precondition(key.utf8.count == 4, "SMC keys have exactly 4 characters")
        var buf = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        let rc = key.withCString { smc_read(conn, $0, &buf, &size) }
        guard rc == SMC_OK else {
            throw SMCError(operation: "read", key: key, code: rc, kernReturn: smc_last_kern_return())
        }
        return Array(buf.prefix(Int(size)))
    }

    public func write(_ key: String, _ bytes: [UInt8]) throws {
        precondition(key.utf8.count == 4, "SMC keys have exactly 4 characters")
        let rc = key.withCString { k in bytes.withUnsafeBufferPointer { smc_write(conn, k, $0.baseAddress, UInt32($0.count)) } }
        guard rc == SMC_OK else {
            throw SMCError(operation: "write", key: key, code: rc, kernReturn: smc_last_kern_return())
        }
    }

    public func keyExists(_ key: String) -> Bool {
        var info = smc_key_info_t()
        return key.withCString { smc_key_info(conn, $0, &info) } == SMC_OK
    }

    // MARK: Adapter control

    /// `true` when wall power is allowed to reach the system/battery.
    public func isAdapterEnabled() throws -> Bool {
        try read(Self.adapterKey).first != Self.adapterDisabledValue
    }

    /// Requires root.
    public func setAdapter(enabled: Bool) throws {
        try write(Self.adapterKey, [enabled ? Self.adapterEnabledValue : Self.adapterDisabledValue])
    }

    // MARK: Charger presence

    /// `AC-W` holds the connected adapter's power class; 0xFF (-1) means no adapter.
    /// Unlike ExternalConnected it keeps reporting the charger while CHIE cuts wall power.
    public static let adapterPresenceKey = "AC-W"

    /// `nil` when the key isn't available on this Mac.
    public func isChargerPlugged() -> Bool? {
        guard let byte = try? read(Self.adapterPresenceKey).first else { return nil }
        return byte != 0xFF
    }

    // MARK: MagSafe LED

    /// `ACLC` drives the MagSafe connector LED.
    public static let magSafeLEDKey = "ACLC"

    public var hasMagSafeLED: Bool { keyExists(Self.magSafeLEDKey) }

    public func magSafeLED() throws -> MagSafeLED? {
        try read(Self.magSafeLEDKey).first.flatMap(MagSafeLED.init(rawValue:))
    }

    /// Requires root.
    public func setMagSafeLED(_ led: MagSafeLED) throws {
        try write(Self.magSafeLEDKey, [led.rawValue])
    }
}

/// Values accepted by the `ACLC` SMC key.
public enum MagSafeLED: UInt8, Codable, Sendable, CaseIterable {
    /// Let macOS decide (orange while charging, green when full).
    case system = 0x00
    case off = 0x01
    case green = 0x03
    case orange = 0x04
}
