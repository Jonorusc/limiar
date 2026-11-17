import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import LimiarCore

// iokit_common_msg() is a function-like macro and isn't imported into Swift.
private let kMsgCanSystemSleep: UInt32 = 0xE000_0270
private let kMsgSystemWillSleep: UInt32 = 0xE000_0280
private let kMsgSystemHasPoweredOn: UInt32 = 0xE000_0300

/// Delivers sleep/wake and power-source changes on the main run loop.
/// The owner must call `stop()`; callbacks hold an unretained pointer to this object.
@MainActor
final class PowerMonitor {
    enum Event { case willSleep, didWake, powerSourceChanged }

    private let handler: @MainActor (Event) -> Void
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var psSource: CFRunLoopSource?

    init(handler: @escaping @MainActor (Event) -> Void) {
        self.handler = handler
    }

    func start() {
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, messageArgument in
            guard let refcon else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated {
                monitor.handleSystemPower(messageType, messageArgument)
            }
        }, &notifier)
        if let notifyPort {
            CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .defaultMode)
        }

        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.handler(.powerSourceChanged) }
        }, refcon)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            psSource = source
        }
    }

    func stop() {
        if let psSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), psSource, .defaultMode)
            CFRunLoopSourceInvalidate(psSource)
            self.psSource = nil
        }
        if notifier != 0 {
            IODeregisterForSystemPower(&notifier)
            notifier = 0
        }
        if let notifyPort {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .defaultMode)
            IONotificationPortDestroy(notifyPort)
            self.notifyPort = nil
        }
        if rootPort != 0 {
            IOServiceClose(rootPort)
            rootPort = 0
        }
    }

    private func handleSystemPower(_ messageType: UInt32, _ argument: UnsafeMutableRawPointer?) {
        let notificationID = Int(bitPattern: argument)
        switch messageType {
        case kMsgCanSystemSleep:
            IOAllowPowerChange(rootPort, notificationID)
        case kMsgSystemWillSleep:
            // Must act synchronously before acknowledging: once we allow, the system sleeps.
            handler(.willSleep)
            IOAllowPowerChange(rootPort, notificationID)
        case kMsgSystemHasPoweredOn:
            handler(.didWake)
        default:
            break
        }
    }
}

/// Schedules a single RTC wake owned by Limiar, replacing any previous one.
@MainActor
final class WakeScheduler {
    private static let owner = LimiarIDs.logSubsystem as CFString
    private(set) var scheduled: Date?

    func schedule(after minutes: Int) -> Bool {
        cancel()
        let date = Date().addingTimeInterval(TimeInterval(minutes * 60))
        let rc = IOPMSchedulePowerEvent(date as CFDate, Self.owner, kIOPMAutoWake as CFString)
        guard rc == kIOReturnSuccess else { return false }
        scheduled = date
        return true
    }

    func cancel() {
        guard let date = scheduled else { return }
        IOPMCancelScheduledPowerEvent(date as CFDate, Self.owner, kIOPMAutoWake as CFString)
        scheduled = nil
    }
}
