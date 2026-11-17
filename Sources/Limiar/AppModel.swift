import AppKit
import Foundation
import LimiarCore
import Observation
import ServiceManagement

/// Mirrors what the MagSafe LED is showing, so the menu bar and the cable always agree.
enum StatusTint: Equatable {
    case charging   // orange
    case holding    // green
    case neutral    // unplugged / unknown

    var nsColor: NSColor {
        switch self {
        case .charging: .systemOrange
        case .holding: .systemGreen
        case .neutral: .labelColor
        }
    }
}

/// What the UI shows, derived from daemon status (or a local read when the daemon is down).
struct DisplayState: Equatable {
    var soc: Int
    var title: String
    var tint: StatusTint
    var isCharging: Bool
}

@MainActor
@Observable
final class AppModel {
    private(set) var status: DaemonStatus?
    private(set) var serviceState: ServiceInstaller.State = ServiceInstaller.state
    private(set) var localBattery: BatteryReading?
    private(set) var actionError: String?
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// True while registering/repairing the service, so buttons can show progress.
    private(set) var isWorkingOnService = false
    /// Set after the first failed connection attempt, so we don't flash "not responding" at launch.
    private(set) var connectionAttempted = false

    @ObservationIgnored private let client = DaemonClient()
    @ObservationIgnored private var lastReportedError: DaemonError?
    @ObservationIgnored private var fallbackTimer: Timer?
    @ObservationIgnored private var servicePoll: Task<Void, Never>?
    @ObservationIgnored private var autoRepairAttempted = false

    init() {
        client.onStatus = { [weak self] status in self?.apply(status) }
        client.onNotice = { notice in Notifier.post(notice) }
        client.onUnavailable = { [weak self] in self?.markUnavailable() }
        Notifier.requestAuthorization()
        // Show the real level right away; the daemon's status replaces it once connected.
        startFallback()
        client.connect()
    }

    // MARK: Derived

    var battery: BatteryReading? { status?.battery ?? localBattery }
    var settings: Settings { status?.settings ?? Settings() }
    var mode: ChargeMode { status?.mode ?? .normal }
    var isConnected: Bool { status != nil }

    /// One source of truth for the menu and Settings.
    enum ServiceHealth: Equatable {
        case running
        case connecting
        case notInstalled
        case needsApproval
        /// Registered and allowed, but launchd won't start it. With ad-hoc signing this happens
        /// after an update: the launch constraint is tied to the previous binary's signature.
        case notResponding
    }

    var serviceHealth: ServiceHealth {
        if isConnected { return .running }
        if isWorkingOnService { return .connecting }
        switch serviceState {
        case .enabled: return connectionAttempted ? .notResponding : .connecting
        case .requiresApproval: return .needsApproval
        case .notInstalled, .notFound: return .notInstalled
        }
    }

    var errorMessage: String? {
        if let actionError { return actionError }
        if let error = status?.lastError { return error.localizedMessage }
        return nil
    }

    var display: DisplayState {
        let soc = battery?.soc ?? 0
        guard let status, let battery = status.battery else {
            // No daemon yet: macOS is in charge, so mirror its own LED (orange charging, green full).
            let local = self.battery
            let tint: StatusTint = local?.isCharging == true ? .charging : (local?.chargerConnected == true ? .holding : .neutral)
            return DisplayState(soc: soc, title: String(localized: "Background service not running"),
                                tint: tint, isCharging: local?.isCharging ?? false)
        }
        let settings = status.settings
        let tint = Self.tint(for: status, battery: battery)
        let title: String
        switch status.mode {
        case .discharge(let target):
            title = String(localized: "Using battery until \(target)%")
        case .topUp(let completed):
            title = completed ? String(localized: "Full — limit returns when unplugged")
                              : String(localized: "Charging to 100%")
        case .normal:
            if !settings.enabled {
                title = battery.isCharging ? String(localized: "Charging — limit off") : String(localized: "Limit off")
            } else if !status.adapterEnabled {
                // Power is cut either way; only say "paused" when a cable is actually plugged in.
                title = battery.chargerConnected
                    ? String(localized: "Paused — resumes at \(settings.resumeAt)%")
                    : String(localized: "On battery")
            } else if battery.isCharging {
                title = String(localized: "Charging to \(settings.limit)%")
            } else if battery.chargerConnected {
                title = String(localized: "Plugged in, not charging")
            } else {
                title = String(localized: "On battery")
            }
        }
        return DisplayState(soc: soc, title: title, tint: tint, isCharging: battery.isCharging)
    }

    /// Same rules the daemon uses for the MagSafe LED, plus macOS's own (orange charging, green full).
    private static func tint(for status: DaemonStatus, battery: BatteryReading) -> StatusTint {
        if battery.isCharging { return .charging }
        // No cable: the MagSafe light is off, so the icon goes neutral.
        guard battery.chargerConnected else { return .neutral }
        if status.settings.enabled && !status.adapterEnabled {
            return status.settings.magSafeGreenWhenPaused || !status.hasMagSafeLED ? .holding : .charging
        }
        return .holding
    }

    // MARK: Actions

    func setRange(limit: Int, resumeAt: Int) {
        updateSettings { $0.limit = limit; $0.resumeAt = resumeAt }
    }

    func setEnabled(_ enabled: Bool) { updateSettings { $0.enabled = enabled } }
    func setMagSafeGreen(_ on: Bool) { updateSettings { $0.magSafeGreenWhenPaused = on } }
    func topUp() { send { await self.client.setMode(.topUp(completed: false)) } }
    func discharge(to target: Int) { send { await self.client.setMode(.discharge(target: target)) } }
    func cancelMode() { send { await self.client.setMode(.normal) } }
    func dismissError() { actionError = nil }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            actionError = String(localized: "Couldn't change Open at Login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Service

    /// The single action behind "Set Up…", "Open Login Items" and "Turn On Again".
    func fixService() {
        switch serviceHealth {
        case .running, .connecting:
            return
        case .needsApproval:
            ServiceInstaller.openLoginItemsSettings()
            watchServiceUntilEnabled()
        case .notInstalled:
            Task { await registerService() }
        case .notResponding:
            Task { await repairService() }
        }
    }

    func uninstallService() {
        Task {
            isWorkingOnService = true
            defer { isWorkingOnService = false }
            do {
                try await ServiceInstaller.uninstall()
            } catch {
                actionError = String(localized: "Couldn't remove the background service: \(error.localizedDescription)")
            }
            status = nil
            serviceState = ServiceInstaller.state
            startFallback()
        }
    }

    func refreshServiceState() { serviceState = ServiceInstaller.state }

    private func registerService() async {
        isWorkingOnService = true
        defer { isWorkingOnService = false }
        do {
            serviceState = try ServiceInstaller.install()
        } catch {
            actionError = String(localized: "Couldn't install the background service: \(error.localizedDescription)")
            serviceState = ServiceInstaller.state
            return
        }
        if serviceState == .requiresApproval { ServiceInstaller.openLoginItemsSettings() }
        if serviceState == .enabled { client.connect() }
        watchServiceUntilEnabled()
    }

    /// Unregister + register so launchd records the current binary. Usually keeps the user's approval.
    private func repairService() async {
        isWorkingOnService = true
        try? await ServiceInstaller.uninstall()
        try? await Task.sleep(for: .seconds(1))
        await registerService()
    }

    /// Polls while the user approves the service in System Settings; stops once connected.
    private func watchServiceUntilEnabled() {
        servicePoll?.cancel()
        servicePoll = Task { [weak self] in
            for _ in 0..<300 { // up to ~10 minutes
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, !self.isConnected else { return }
                let previous = self.serviceState
                self.serviceState = ServiceInstaller.state
                if self.serviceState == .enabled, previous != .enabled {
                    // Just approved. If launchd still holds a stale registration, the next failed
                    // connection triggers one more automatic repair (which keeps the approval).
                    self.autoRepairAttempted = false
                    self.client.connect()
                }
            }
        }
    }

    // MARK: Private

    private func updateSettings(_ change: (inout Settings) -> Void) {
        var next = settings
        change(&next)
        next = next.validated()
        guard next != settings else { return }
        send { await self.client.updateSettings(next) }
    }

    private func send(_ operation: @escaping @MainActor () async -> String?) {
        Task { actionError = await operation() }
    }

    private func apply(_ status: DaemonStatus) {
        self.status = status
        serviceState = .enabled
        servicePoll?.cancel()
        stopFallback()
        if let error = status.lastError, error != lastReportedError { Notifier.postError(error.localizedMessage) }
        lastReportedError = status.lastError

        // No app-side restart: unregister/register can drop the user's approval. The daemon
        // restarts itself when its executable is replaced (see Controller.executableWasReplaced).
    }

    private func markUnavailable() {
        status = nil
        connectionAttempted = true
        serviceState = ServiceInstaller.state
        startFallback()
        // Registered but not answering (typically right after an update): repair once, automatically.
        if serviceState == .enabled, !autoRepairAttempted, !isWorkingOnService {
            autoRepairAttempted = true
            Task { await repairService() }
        }
    }

    /// While the daemon is unreachable, still show the battery level (read-only, no root needed).
    private func startFallback() {
        guard fallbackTimer == nil else { return }
        localBattery = try? BatteryReader.read()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.localBattery = try? BatteryReader.read() }
        }
    }

    private func stopFallback() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }
}

extension DaemonError {
    var localizedMessage: String {
        switch self {
        case .batteryReadFailed: String(localized: "Couldn't read the battery.")
        case .smcWriteFailed(let key): String(localized: "Couldn't write SMC key \(key).")
        }
    }
}
