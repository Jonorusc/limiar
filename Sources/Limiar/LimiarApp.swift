import AppKit
import LimiarCore
import SwiftUI

@main
struct LimiarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Headless service management, handy for scripts and debugging:
        //   Limiar.app/Contents/MacOS/Limiar --service status|install|uninstall
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--service"), i + 1 < args.count {
            Self.runServiceCommand(args[i + 1])
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: appDelegate.model)
        } label: {
            MenuBarLabel(display: appDelegate.model.display)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }

    @MainActor
    private static func runServiceCommand(_ command: String) -> Never {
        switch command {
        case "install":
            do { print("state:", try ServiceInstaller.install()) } catch { print("error:", error); exit(1) }
        case "uninstall":
            var finished = false
            Task { @MainActor in
                do { try await ServiceInstaller.uninstall(); print("uninstalled") } catch { print("error:", error) }
                finished = true
            }
            while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        case "probe":
            // Connects exactly like the app does and prints the daemon's answer or the XPC error.
            let conn = NSXPCConnection(machServiceName: LimiarIDs.daemonMachService, options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: LimiarDaemonProtocol.self)
            conn.invalidationHandler = { @Sendable in print("connection invalidated") }
            conn.interruptionHandler = { @Sendable in print("connection interrupted") }
            conn.resume()
            let proxy = conn.remoteObjectProxyWithErrorHandler { @Sendable error in
                print("xpc error:", error)
                exit(1)
            } as? LimiarDaemonProtocol
            proxy?.subscribe { data in
                print(String(decoding: data, as: UTF8.self))
                exit(0)
            }
            RunLoop.main.run(until: Date().addingTimeInterval(5))
            print("timeout: no reply in 5 s")
            exit(1)
        case "mode":
            // Sends a mode exactly like the menu buttons do, then prints the resulting status.
            //   --service mode discharge 50   |   --service mode topup   |   --service mode normal
            let args = CommandLine.arguments
            let kind = args.last ?? ""
            let mode: ChargeMode
            if let target = Int(kind) { mode = .discharge(target: target) }
            else if kind == "topup" { mode = .topUp(completed: false) }
            else { mode = .normal }
            let conn = NSXPCConnection(machServiceName: LimiarIDs.daemonMachService, options: .privileged)
            conn.remoteObjectInterface = NSXPCInterface(with: LimiarDaemonProtocol.self)
            conn.resume()
            let proxy = conn.remoteObjectProxyWithErrorHandler { @Sendable error in
                print("xpc error:", error)
                exit(1)
            } as? LimiarDaemonProtocol
            nonisolated(unsafe) let sameProxy = proxy // debug command: single-threaded use
            proxy?.setMode(Wire.encode(mode)) { error in
                print("setMode(\(mode)) ->", error ?? "ok")
                sameProxy?.subscribe { data in
                    let status = Wire.decode(DaemonStatus.self, data)
                    print("mode now:", status.map { "\($0.mode)" } ?? "?", "| adapter:", status?.adapterEnabled ?? false)
                    exit(0)
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(5))
            print("timeout: no reply in 5 s")
            exit(1)
        default:
            print("state:", ServiceInstaller.state)
        }
        exit(0)
    }
}

/// Owns the model and shows the welcome window on first run (before the menu is ever opened).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var welcomeWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ServiceInstaller.state != .enabled { showWelcome() }
    }

    func showWelcome() {
        if let welcomeWindow {
            welcomeWindow.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView:
            WelcomeView(model: model) { [weak window] in window?.close() }
                .background(.regularMaterial)
        )
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        welcomeWindow = window
    }

    // MARK: Quit confirmation

    private static let skipQuitConfirmationKey = "skipQuitConfirmation"

    /// Quitting only removes the menu bar icon: the background service keeps enforcing the limit.
    /// Say so once, so people don't think they turned the limit off (or that they must keep the app open).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if UserDefaults.standard.bool(forKey: Self.skipQuitConfirmationKey) { return .terminateNow }
        // Logout, restart and shutdown carry a quit reason: never block those.
        if NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: kAEQuitReason) != nil {
            return .terminateNow
        }
        // Nothing to explain if the limit isn't active.
        guard model.isConnected, model.settings.enabled else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = String(localized: "Quit Limiar?")
        alert.informativeText = String(localized: "Your charge limit stays on in the background. You'll just stop seeing Limiar in the menu bar until you open it again.")
        alert.addButton(withTitle: String(localized: "Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don't ask again")
        NSApp.activate()
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: Self.skipQuitConfirmationKey)
        }
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}
