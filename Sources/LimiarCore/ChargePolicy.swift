import Foundation

public enum PolicyEvent: Equatable, Sendable {
    /// Periodic check or power-source change.
    case tick
    /// System is about to sleep; the daemon can't act until it wakes.
    case willSleep
}

public enum PolicyNotice: Codable, Equatable, Sendable {
    case limitReached(limit: Int)
    case topUpCompleted
    case dischargeCompleted(target: Int)
}

public struct PolicyDecision: Equatable, Sendable {
    public var adapterEnabled: Bool
    public var mode: ChargeMode
    /// Minutes from now to schedule a wake, so the daemon can stop charging during sleep.
    public var wakeAfterMinutes: Int?
    public var notices: [PolicyNotice]
    /// Desired MagSafe LED state; `.system` hands control back to macOS.
    public var led: MagSafeLED = .system
}

/// Pure charge-control state machine. No I/O: easy to test and reason about.
public enum ChargePolicy {
    /// Worst-case charging speed used to schedule a wake before overshooting the limit.
    /// A 30 W charge on a MacBook Air M4 adds roughly 1–1.5 %/min at low SoC; 2 is conservative.
    public static let worstCasePercentPerMinute = 2
    public static let minimumWakeMinutes = 3
    /// While charging, going to sleep this close to the limit means sleeping on battery instead.
    public static let sleepNearLimitMargin = 5

    public static func evaluate(
        settings rawSettings: Settings,
        mode: ChargeMode,
        adapterEnabled: Bool,
        adapterSettled: Bool = true,
        reading: BatteryReading,
        event: PolicyEvent
    ) -> PolicyDecision {
        let settings = rawSettings.validated()
        var decision = evaluateAdapter(settings: settings, mode: mode, adapterEnabled: adapterEnabled,
                                       adapterSettled: adapterSettled, reading: reading, event: event)
        // Green LED = "plugged in but deliberately not charging".
        let holding = settings.enabled && !decision.adapterEnabled
        decision.led = (holding && settings.magSafeGreenWhenPaused) ? .green : .system
        return decision
    }

    private static func evaluateAdapter(
        settings: Settings,
        mode: ChargeMode,
        adapterEnabled: Bool,
        adapterSettled: Bool,
        reading: BatteryReading,
        event: PolicyEvent
    ) -> PolicyDecision {

        guard settings.enabled else {
            return PolicyDecision(adapterEnabled: true, mode: .normal, wakeAfterMinutes: nil, notices: [])
        }

        switch mode {
        case .topUp(let completed):
            // With the adapter enabled (and settled after a CHIE change), ExternalConnected is
            // trustworthy: unplugging ends the top-up.
            if adapterEnabled && adapterSettled && !reading.externalConnected {
                return evaluateNormal(settings, adapterEnabled: adapterEnabled, reading: reading, event: event, notices: [])
            }
            let full = reading.fullyCharged || reading.soc >= 100
            let notices: [PolicyNotice] = (full && !completed) ? [.topUpCompleted] : []
            return PolicyDecision(adapterEnabled: true, mode: .topUp(completed: completed || full),
                                  wakeAfterMinutes: nil, notices: notices)

        case .discharge(let target):
            if reading.soc <= target {
                return evaluateNormal(settings, adapterEnabled: adapterEnabled, reading: reading, event: event,
                                      notices: [.dischargeCompleted(target: target)])
            }
            return PolicyDecision(adapterEnabled: false, mode: mode, wakeAfterMinutes: nil, notices: [])

        case .normal:
            return evaluateNormal(settings, adapterEnabled: adapterEnabled, reading: reading, event: event, notices: [])
        }
    }

    private static func evaluateNormal(
        _ settings: Settings,
        adapterEnabled: Bool,
        reading: BatteryReading,
        event: PolicyEvent,
        notices: [PolicyNotice]
    ) -> PolicyDecision {
        var notices = notices
        let limit = settings.limit

        if limit >= 100 {
            return PolicyDecision(adapterEnabled: true, mode: .normal, wakeAfterMinutes: nil, notices: notices)
        }

        if event == .willSleep {
            // Already holding (and not yet at the resume point): keep holding through sleep.
            let holding = !adapterEnabled && reading.soc > settings.resumeAt
            // Charging and close to the limit: sleep on battery (tiny drain) so we can't overshoot.
            let nearLimit = reading.soc >= limit - sleepNearLimitMargin
            if holding || nearLimit {
                return PolicyDecision(adapterEnabled: false, mode: .normal, wakeAfterMinutes: nil, notices: notices)
            }
            // Far below: keep charging, but wake up before we could reach the limit.
            let minutes = max(minimumWakeMinutes, (limit - reading.soc) / worstCasePercentPerMinute)
            return PolicyDecision(adapterEnabled: true, mode: .normal, wakeAfterMinutes: minutes, notices: notices)
        }

        let enable: Bool
        if reading.soc >= limit {
            enable = false
            if adapterEnabled { notices.append(.limitReached(limit: limit)) }
        } else if reading.soc <= settings.resumeAt {
            enable = true
        } else {
            enable = adapterEnabled // hysteresis band: keep current state
        }
        return PolicyDecision(adapterEnabled: enable, mode: .normal, wakeAfterMinutes: nil, notices: notices)
    }
}
