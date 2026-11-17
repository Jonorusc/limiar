import Foundation

public struct Settings: Codable, Equatable, Sendable {
    public static let limitRange = 50...100
    /// Lowest allowed "resume charging at" value.
    public static let minimumResume = 20

    /// When false, Limiar never cuts the adapter.
    public var enabled: Bool = true
    /// Upper charge limit (%): wall power is cut when the battery reaches it.
    public var limit: Int = 80
    /// Charging resumes when the battery drops to this level (always below `limit`).
    public var resumeAt: Int = 75
    /// Turn the MagSafe LED green while Limiar is holding the charge.
    public var magSafeGreenWhenPaused: Bool = true

    public init(enabled: Bool = true, limit: Int = 80, resumeAt: Int? = nil, magSafeGreenWhenPaused: Bool = true) {
        self.enabled = enabled
        self.limit = limit
        self.resumeAt = resumeAt ?? max(Self.minimumResume, limit - 5)
        self.magSafeGreenWhenPaused = magSafeGreenWhenPaused
    }

    /// Valid range for `resumeAt` given a limit.
    public static func resumeRange(forLimit limit: Int) -> ClosedRange<Int> {
        minimumResume...max(minimumResume, min(limit, 100) - 1)
    }

    // Tolerant decoding so state files from older versions keep working
    // (v1.0 stored a relative `gap` instead of `resumeAt`).
    private enum CodingKeys: String, CodingKey { case enabled, limit, resumeAt, gap, magSafeGreenWhenPaused }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        limit = try c.decodeIfPresent(Int.self, forKey: .limit) ?? 80
        if let resume = try c.decodeIfPresent(Int.self, forKey: .resumeAt) {
            resumeAt = resume
        } else {
            resumeAt = limit - (try c.decodeIfPresent(Int.self, forKey: .gap) ?? 5)
        }
        magSafeGreenWhenPaused = try c.decodeIfPresent(Bool.self, forKey: .magSafeGreenWhenPaused) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(limit, forKey: .limit)
        try c.encode(resumeAt, forKey: .resumeAt)
        try c.encode(magSafeGreenWhenPaused, forKey: .magSafeGreenWhenPaused)
    }

    public func validated() -> Settings {
        let limit = limit.clamped(to: Self.limitRange)
        return Settings(
            enabled: enabled,
            limit: limit,
            resumeAt: resumeAt.clamped(to: Self.resumeRange(forLimit: limit)),
            magSafeGreenWhenPaused: magSafeGreenWhenPaused
        )
    }
}

public enum ChargeMode: Codable, Equatable, Sendable {
    /// Keep the battery between `resumeAt` and `limit`.
    case normal
    /// Charge to 100% once; stays full while plugged, back to `.normal` when unplugged.
    case topUp(completed: Bool)
    /// Run on battery while plugged in until `target`, then back to `.normal`.
    case discharge(target: Int)

    public static let dischargeRange = 10...95
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
