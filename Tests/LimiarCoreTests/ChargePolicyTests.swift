import Foundation
import Testing
@testable import LimiarCore

private func reading(_ soc: Int, plugged: Bool = true, full: Bool = false, external: Bool? = nil) -> BatteryReading {
    BatteryReading(soc: soc, isCharging: plugged && soc < 100, externalConnected: external ?? plugged,
                   fullyCharged: full, chargerConnected: plugged)
}

private func eval(
    _ soc: Int,
    adapter: Bool = true,
    settled: Bool = true,
    mode: ChargeMode = .normal,
    settings: Settings = Settings(),
    plugged: Bool = true,
    full: Bool = false,
    event: PolicyEvent = .tick
) -> PolicyDecision {
    ChargePolicy.evaluate(settings: settings, mode: mode, adapterEnabled: adapter, adapterSettled: settled,
                          reading: reading(soc, plugged: plugged, full: full), event: event)
}

@Suite("Normal mode hysteresis")
struct NormalModeTests {
    @Test func cutsAtLimitAndNotifiesOnce() {
        let d = eval(80, adapter: true)
        #expect(d.adapterEnabled == false)
        #expect(d.notices == [.limitReached(limit: 80)])

        let again = eval(81, adapter: false)
        #expect(again.adapterEnabled == false)
        #expect(again.notices.isEmpty)
    }

    @Test func keepsStateInsideBand() {
        #expect(eval(77, adapter: false).adapterEnabled == false)
        #expect(eval(77, adapter: true).adapterEnabled == true)
    }

    @Test func resumesAtLowerBound() {
        #expect(eval(75, adapter: false).adapterEnabled == true)
        #expect(eval(40, adapter: false).adapterEnabled == true)
    }

    @Test func limit100NeverCuts() {
        #expect(eval(100, adapter: true, settings: Settings(limit: 100)).adapterEnabled == true)
    }

    @Test func disabledAlwaysRestoresAdapter() {
        let d = eval(95, adapter: false, mode: .discharge(target: 50), settings: Settings(enabled: false))
        #expect(d.adapterEnabled == true)
        #expect(d.mode == .normal)
    }

    @Test func invalidSettingsAreClamped() {
        // limit 20 is clamped to 50
        #expect(eval(55, adapter: true, settings: Settings(limit: 20)).adapterEnabled == false)
    }
}

@Suite("Sleep")
struct SleepTests {
    @Test func nearLimitSleepsOnBattery() {
        let d = eval(78, adapter: true, event: .willSleep)
        #expect(d.adapterEnabled == false)
        #expect(d.wakeAfterMinutes == nil)
    }

    @Test func farBelowKeepsChargingAndSchedulesWake() {
        let d = eval(40, adapter: true, event: .willSleep)
        #expect(d.adapterEnabled == true)
        #expect(d.wakeAfterMinutes == 20) // (80 - 40) / 2
    }

    @Test func wakeHasMinimum() {
        let d = eval(74, adapter: true, event: .willSleep)
        #expect(d.wakeAfterMinutes == ChargePolicy.minimumWakeMinutes)
    }

    @Test func holdingStaysCutThroughSleep() {
        let d = eval(60, adapter: false, settings: Settings(resumeAt: 40), event: .willSleep)
        #expect(d.adapterEnabled == false)
    }

    @Test func chargingFarFromLimitKeepsChargingWithLowResume() {
        let d = eval(60, adapter: true, settings: Settings(resumeAt: 40), event: .willSleep)
        #expect(d.adapterEnabled == true)
        #expect(d.wakeAfterMinutes == 10)
    }

    @Test func noLimitNoWake() {
        let d = eval(40, settings: Settings(limit: 100), event: .willSleep)
        #expect(d.wakeAfterMinutes == nil)
    }
}

@Suite("Top-up to 100%")
struct TopUpTests {
    @Test func enablesAdapterAboveLimit() {
        // Power was cut at the limit: ExternalConnected reads false, but the cable is plugged in.
        let r = BatteryReading(soc: 90, isCharging: false, externalConnected: false, chargerConnected: true)
        let d = ChargePolicy.evaluate(settings: Settings(), mode: .topUp(completed: false), adapterEnabled: false,
                                      reading: r, event: .tick)
        #expect(d.adapterEnabled == true)
        #expect(d.mode == .topUp(completed: false))
    }

    @Test func notifiesOnceWhenFull() {
        let d = eval(100, mode: .topUp(completed: false), full: true)
        #expect(d.notices == [.topUpCompleted])
        #expect(d.mode == .topUp(completed: true))
        let again = eval(100, mode: .topUp(completed: true), full: true)
        #expect(again.notices.isEmpty)
    }

    @Test func unplugReturnsToNormal() {
        let d = eval(100, adapter: true, mode: .topUp(completed: true), plugged: false)
        #expect(d.mode == .normal)
        #expect(d.adapterEnabled == false) // above limit: cut so replugging won't recharge
    }

    @Test func cutPowerWithCableStillPluggedDoesNotEndTopUp() {
        // While CHIE switches, ExternalConnected reads false but the cable is still there.
        let r = BatteryReading(soc: 85, isCharging: false, externalConnected: false, chargerConnected: true)
        let d = ChargePolicy.evaluate(settings: Settings(), mode: .topUp(completed: false), adapterEnabled: true,
                                      adapterSettled: false, reading: r, event: .tick)
        #expect(d.mode == .topUp(completed: false))
    }

    @Test func unplugWhilePowerCutEndsTopUp() {
        let r = BatteryReading(soc: 85, isCharging: false, externalConnected: false, chargerConnected: false)
        let d = ChargePolicy.evaluate(settings: Settings(), mode: .topUp(completed: false), adapterEnabled: false,
                                      reading: r, event: .tick)
        #expect(d.mode == .normal)
    }

    @Test func staysOnDuringSleep() {
        let d = eval(90, mode: .topUp(completed: false), event: .willSleep)
        #expect(d.adapterEnabled == true)
    }
}

@Suite("Forced discharge")
struct DischargeTests {
    @Test func cutsUntilTarget() {
        let d = eval(70, adapter: true, mode: .discharge(target: 50))
        #expect(d.adapterEnabled == false)
        #expect(d.mode == .discharge(target: 50))
    }

    @Test func returnsToNormalAtTarget() {
        let d = eval(50, adapter: false, mode: .discharge(target: 50))
        #expect(d.mode == .normal)
        #expect(d.notices == [.dischargeCompleted(target: 50)])
        #expect(d.adapterEnabled == true) // 50 <= resumeAt 75
    }

    @Test func staysCutDuringSleep() {
        let d = eval(70, mode: .discharge(target: 50), event: .willSleep)
        #expect(d.adapterEnabled == false)
    }
}

@Suite("MagSafe LED")
struct MagSafeLEDTests {
    @Test func greenWhileHolding() {
        #expect(eval(80, adapter: true).led == .green)
    }

    @Test func systemWhileCharging() {
        #expect(eval(60, adapter: true).led == .system)
    }

    @Test func greenDuringForcedDischarge() {
        #expect(eval(70, mode: .discharge(target: 50)).led == .green)
    }

    @Test func systemWhenOptionOff() {
        #expect(eval(80, adapter: true, settings: Settings(magSafeGreenWhenPaused: false)).led == .system)
    }

    @Test func systemWhenUnplugged() {
        // No cable means no LED to colour: give control back to macOS.
        #expect(eval(90, adapter: false, plugged: false).led == .system)
    }

    @Test func systemWhenDisabled() {
        #expect(eval(95, adapter: false, settings: Settings(enabled: false)).led == .system)
    }

    @Test func legacySettingsDecodeWithDefaults() throws {
        let json = Data(#"{"enabled":true,"limit":70,"gap":5}"#.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: json)
        #expect(settings.limit == 70)
        #expect(settings.resumeAt == 65)
        #expect(settings.magSafeGreenWhenPaused == true)
    }
}

@Suite("Custom resume level")
struct ResumeTests {
    @Test func resumesOnlyAtChosenLevel() {
        let settings = Settings(limit: 80, resumeAt: 50)
        #expect(eval(60, adapter: false, settings: settings).adapterEnabled == false)
        #expect(eval(50, adapter: false, settings: settings).adapterEnabled == true)
    }

    @Test func resumeIsClampedBelowLimit() {
        #expect(Settings(limit: 80, resumeAt: 95).validated().resumeAt == 79)
        #expect(Settings(limit: 80, resumeAt: 5).validated().resumeAt == Settings.minimumResume)
    }

    @Test func roundTripsWithoutGap() throws {
        let data = try JSONEncoder().encode(Settings(limit: 85, resumeAt: 60))
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded == Settings(limit: 85, resumeAt: 60))
        #expect(!String(decoding: data, as: UTF8.self).contains("gap"))
    }
}
