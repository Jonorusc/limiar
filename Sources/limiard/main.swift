import Foundation
import LimiarCore

/// limiard — root daemon that enforces the charge limit through the SMC `CHIE` key.
///   limiard           run the daemon (launchd)
///   limiard status    print battery + adapter state (no root needed)
///   limiard restore   re-enable wall power immediately (root) — emergency escape hatch
///   limiard diag      dump adapter-related SMC keys and battery registry fields
///   limiard led X     set the MagSafe LED: system|green|orange|off (root) — for testing

func printStatus() throws {
    let smc = try SMCClient()
    let battery = try BatteryReader.read()
    let adapter = try smc.isAdapterEnabled()
    let persisted = Store.load()
    print("""
    Battery:       \(battery.soc)% \(battery.isCharging ? "(charging)" : "")
    Wall power:    \(adapter ? "allowed" : "CUT by Limiar") (CHIE)
    External:      \(battery.externalConnected)
    Current:       \(battery.amperage) mA
    Limit:         \(persisted.settings.limit)% (resumes at \(persisted.settings.resumeAt)%) \(persisted.settings.enabled ? "" : "[disabled]")
    Mode:          \(persisted.mode)
    MagSafe LED:   \((try? smc.magSafeLED()).flatMap { $0.map { "\($0)" } } ?? "n/a")
    Charger:       raw=\(battery.rawExternalConnected) · \(battery.adapterWatts) W
    Health:        \(battery.healthPercent)% · \(battery.cycleCount) cycles
    """)
}

func restore() throws {
    guard geteuid() == 0 else {
        FileHandle.standardError.write(Data("restore requires root: sudo limiard restore\n".utf8))
        exit(1)
    }
    let smc = try SMCClient()
    try smc.setAdapter(enabled: true)
    if smc.hasMagSafeLED { try smc.setMagSafeLED(.system) }
    print("Wall power restored (CHIE=0x00), MagSafe LED back to system control.")
}

func diag() throws {
    let smc = try SMCClient()
    let battery = try BatteryReader.read()
    print("AdapterDetails.Watts", battery.adapterWatts)
    for key in ["CHIE", "AC-W", "AC-N", "AC-I", "AC-S", "AC-B", "AC-C", "ACLC", "CHTE", "CH0B", "CH0C", "bfD0"] {
        if let bytes = try? smc.read(key) {
            print(key, bytes.map { String(format: "%02x", $0) }.joined())
        } else {
            print(key, smc.keyExists(key) ? "(protected)" : "(absent)")
        }
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    task.arguments = ["-rn", "AppleSmartBattery"]
    let pipe = Pipe()
    task.standardOutput = pipe
    try task.run()
    task.waitUntilExit()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    for line in text.split(separator: "\n") where line.contains("\"ExternalConnected\"") || line.contains("\"AppleRawExternalConnected\"")
        || line.contains("\"IsCharging\"") || line.contains("\"AdapterInfo\"") {
        print(line.trimmingCharacters(in: .whitespaces))
    }
}

func setLED(_ name: String?) throws {
    guard geteuid() == 0 else {
        FileHandle.standardError.write(Data("led requires root: sudo limiard led green\n".utf8))
        exit(1)
    }
    let names: [String: MagSafeLED] = ["system": .system, "green": .green, "orange": .orange, "off": .off]
    guard let name, let led = names[name] else {
        print("usage: sudo limiard led system|green|orange|off")
        exit(2)
    }
    let smc = try SMCClient()
    guard smc.hasMagSafeLED else { print("This Mac has no MagSafe LED key (ACLC)."); exit(1) }
    try smc.setMagSafeLED(led)
    print("ACLC=0x\(String(format: "%02x", led.rawValue)) (\(name))")
}

@MainActor
func runDaemon() -> Never {
    guard geteuid() == 0 else {
        FileHandle.standardError.write(Data("limiard must run as root (launchd).\n".utf8))
        exit(1)
    }
    let smc: SMCClient
    do { smc = try SMCClient() } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(1)
    }

    LegacyCleanup.run()
    let controller = Controller(smc: smc)
    let server = XPCServer(controller: controller)

    // Always give wall power back when launchd stops us (uninstall, update, shutdown).
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    var signalSources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT] {
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                server.invalidate()
                controller.shutdown()
            }
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }
    controller.onReplaced = {
        server.invalidate()
        controller.shutdown()
        exit(0)
    }
    controller.start()
    server.resume()
    // Keep the signal sources alive for the process lifetime.
    _ = Unmanaged.passRetained(signalSources as NSArray)
    // Run the main CFRunLoop, not dispatchMain(): sleep/wake (IORegisterForSystemPower) and
    // power-source change (IOPSNotificationCreateRunLoopSource) callbacks are run-loop sources
    // on the main run loop. dispatchMain() exits the main thread, so they never fired.
    // The main dispatch queue (timers, XPC hops, signals) is drained by this run loop too.
    while true { CFRunLoopRun() }
}

let arguments = CommandLine.arguments.dropFirst()
do {
    switch arguments.first {
    case nil: MainActor.assumeIsolated { runDaemon() }
    case "status": try printStatus()
    case "restore": try restore()
    case "diag": try diag()
    case "led": try setLED(arguments.dropFirst().first)
    default:
        print("usage: limiard [status|restore|diag|led system|green|orange|off]")
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
