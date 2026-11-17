import Foundation
import LimiarCore
import os

/// Owns the SMC, applies `ChargePolicy` and pushes state to connected apps. Main-actor only.
@MainActor
final class Controller {
    private let log = Logger(subsystem: LimiarIDs.logSubsystem, category: "controller")
    /// After a CHIE change, ioreg's ExternalConnected can lag a few seconds.
    private static let adapterSettleInterval: TimeInterval = 10
    private static let pollInterval: TimeInterval = 60
    /// While wall power is cut, macOS sends no power-source events when the cable is plugged or
    /// pulled, so poll faster to notice it (an SMC + registry read every 5 s is negligible).
    private static let fastPollInterval: TimeInterval = 5
    private var currentPollInterval: TimeInterval = 0
    /// Captured at launch: if the bundle is replaced later, the app sees a different stamp on disk.
    private static let executableStamp = DaemonStatus.stamp(of: Bundle.main.executableURL)

    private let smc: SMCClient
    private var state: PersistedState
    private var adapterEnabled: Bool
    private var adapterChangedAt = Date.distantPast
    private var lastError: DaemonError?
    private var hasMagSafeLED = false
    private var lastLED: MagSafeLED?
    private var lastBattery: BatteryReading?
    private var lastPushed: DaemonStatus?

    private var clients: [ObjectIdentifier: NSXPCConnection] = [:]
    private var pollTimer: DispatchSourceTimer?
    private var settleWork: DispatchWorkItem?
    private lazy var power = PowerMonitor { [weak self] event in self?.handle(event) }
    private let wake = WakeScheduler()

    /// Called when the daemon binary on disk changed (app updated); main.swift shuts down and exits
    /// so launchd's KeepAlive relaunches the new binary without asking the user to re-approve.
    var onReplaced: (() -> Void)?

    private func executableWasReplaced() -> Bool {
        guard let launched = Self.executableStamp,
              let onDisk = DaemonStatus.stamp(of: Bundle.main.executableURL) else { return false }
        return launched != onDisk
    }

    init(smc: SMCClient) {
        self.smc = smc
        self.state = Store.load()
        self.adapterEnabled = (try? smc.isAdapterEnabled()) ?? true
        self.hasMagSafeLED = smc.hasMagSafeLED
    }

    func start() {
        log.info("starting: limit=\(self.state.settings.limit) adapterEnabled=\(self.adapterEnabled)")
        power.start()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        currentPollInterval = Self.pollInterval
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.executableWasReplaced() {
                    self.log.info("executable replaced by an app update; restarting")
                    self.onReplaced?()
                    return
                }
                self.evaluate(.tick)
            }
        }
        timer.resume()
        pollTimer = timer

        evaluate(.tick)
    }

    /// Restores wall power and tears everything down. Safe to call more than once.
    func shutdown() {
        pollTimer?.cancel()
        pollTimer = nil
        settleWork?.cancel()
        power.stop()
        wake.cancel()
        do {
            try smc.setAdapter(enabled: true)
            adapterEnabled = true
            log.info("adapter restored on shutdown")
        } catch {
            log.error("failed to restore adapter: \(String(describing: error), privacy: .public)")
        }
        if hasMagSafeLED { try? smc.setMagSafeLED(.system) }
        for connection in clients.values { connection.invalidate() }
        clients.removeAll()
    }

    // MARK: Events

    private func handle(_ event: PowerMonitor.Event) {
        switch event {
        case .willSleep:
            evaluate(.willSleep)
        case .didWake:
            wake.cancel()
            evaluate(.tick)
        case .powerSourceChanged:
            evaluate(.tick)
        }
    }

    private func evaluate(_ event: PolicyEvent) {
        var reading: BatteryReading
        do {
            reading = try BatteryReader.read()
        } catch {
            fail(.batteryReadFailed, detail: String(describing: error))
            return
        }
        // ExternalConnected goes false while we cut power; AC-W still knows if a cable is there.
        if let plugged = smc.isChargerPlugged() {
            reading.chargerConnected = plugged || reading.externalConnected
        }
        lastBattery = reading

        // Trust the hardware over our cache (e.g. another tool or a reboot changed CHIE).
        if let actual = try? smc.isAdapterEnabled(), actual != adapterEnabled {
            adapterEnabled = actual
            adapterChangedAt = Date()
        }

        let decision = ChargePolicy.evaluate(
            settings: state.settings,
            mode: state.mode,
            adapterEnabled: adapterEnabled,
            adapterSettled: Date().timeIntervalSince(adapterChangedAt) > Self.adapterSettleInterval,
            reading: reading,
            event: event
        )

        if decision.adapterEnabled != adapterEnabled {
            do {
                try smc.setAdapter(enabled: decision.adapterEnabled)
                adapterEnabled = decision.adapterEnabled
                adapterChangedAt = Date()
                lastError = nil
                log.info("adapter -> \(decision.adapterEnabled ? "enabled" : "cut") at \(reading.soc)% (\(String(describing: event)))")
                if event != .willSleep { scheduleSettleCheck() }
            } catch {
                fail(.smcWriteFailed(key: SMCClient.adapterKey), detail: String(describing: error))
            }
        }

        applyLED(decision.led)

        if decision.mode != state.mode {
            state.mode = decision.mode
            persist()
        }

        if event == .willSleep, let minutes = decision.wakeAfterMinutes {
            if wake.schedule(after: minutes) {
                log.info("wake scheduled in \(minutes) min")
            } else {
                log.error("failed to schedule wake")
            }
        }

        updatePollInterval()
        for notice in decision.notices { emit(notice) }
        pushStatusIfChanged()
    }

    private func updatePollInterval() {
        let wanted = adapterEnabled ? Self.pollInterval : Self.fastPollInterval
        guard wanted != currentPollInterval, let pollTimer else { return }
        currentPollInterval = wanted
        pollTimer.schedule(deadline: .now() + wanted, repeating: wanted, leeway: .seconds(wanted > 10 ? 5 : 1))
    }

    /// Re-evaluate once the adapter state has settled so unplug detection is reliable.
    private func scheduleSettleCheck() {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.evaluate(.tick) }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.adapterSettleInterval + 2, execute: work)
    }

    /// Re-asserts the LED every evaluation: the SMC resets it on power events.
    private func applyLED(_ desired: MagSafeLED) {
        guard hasMagSafeLED else { return }
        let current = try? smc.magSafeLED()
        // `.system` reads back as whatever macOS chose, so hand control back once per change
        // (and once after a restart, when we can't know who set the current colour).
        if desired == .system {
            guard lastLED != .system else { return }
        } else if current == desired {
            lastLED = desired
            return
        }
        do {
            try smc.setMagSafeLED(desired)
            lastLED = desired
        } catch {
            log.error("LED write failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func fail(_ error: DaemonError, detail: String) {
        log.error("\(String(describing: error), privacy: .public): \(detail, privacy: .public)")
        if lastError != error {
            lastError = error
            pushStatusIfChanged()
        }
    }

    private func persist() {
        do { try Store.save(state) } catch { log.error("persist failed: \(String(describing: error), privacy: .public)") }
    }

    // MARK: Commands from the app

    var status: DaemonStatus {
        DaemonStatus(battery: lastBattery, adapterEnabled: adapterEnabled, settings: state.settings,
                     mode: state.mode, scheduledWake: wake.scheduled, lastError: lastError,
                     hasMagSafeLED: hasMagSafeLED, executableStamp: Self.executableStamp)
    }

    func apply(settings: Settings) {
        state.settings = settings.validated()
        persist()
        evaluate(.tick)
    }

    func apply(mode: ChargeMode) -> String? {
        if case .discharge(let target) = mode, !ChargeMode.dischargeRange.contains(target) {
            return "Alvo de descarga deve ficar entre \(ChargeMode.dischargeRange.lowerBound)% e \(ChargeMode.dischargeRange.upperBound)%."
        }
        state.mode = mode
        persist()
        evaluate(.tick)
        return nil
    }

    // MARK: Clients

    func add(client connection: NSXPCConnection) {
        let id = ObjectIdentifier(connection)
        clients[id] = connection
    }

    func remove(clientID id: ObjectIdentifier) {
        clients.removeValue(forKey: id)
    }

    private func pushStatusIfChanged() {
        let current = status
        guard current != lastPushed else { return }
        lastPushed = current
        let data = Wire.encode(current)
        for connection in clients.values {
            (connection.remoteObjectProxy as? LimiarClientProtocol)?.statusDidChange(data)
        }
    }

    private func emit(_ notice: PolicyNotice) {
        log.info("notice: \(String(describing: notice), privacy: .public)")
        let data = Wire.encode(notice)
        for connection in clients.values {
            (connection.remoteObjectProxy as? LimiarClientProtocol)?.didEmit(data)
        }
    }
}
