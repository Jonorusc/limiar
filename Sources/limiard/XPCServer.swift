import Foundation
import CSMC
import LimiarCore
import os

/// Accepts connections only from admin users running the Limiar app.
/// Note: with ad-hoc signing the identifier requirement can be spoofed by a local process;
/// acceptable on a single-user Mac, documented in the README.
final class XPCServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let log = Logger(subsystem: LimiarIDs.logSubsystem, category: "xpc")
    private let listener = NSXPCListener(machServiceName: LimiarIDs.daemonMachService)
    private let controller: Controller

    init(controller: Controller) {
        self.controller = controller
        super.init()
        listener.delegate = self
    }

    func resume() { listener.resume() }
    func invalidate() { listener.invalidate() }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let uid = connection.effectiveUserIdentifier
        guard Self.isAdmin(uid: uid) else {
            log.error("rejected connection from non-admin uid \(uid)")
            return false
        }
        connection.setCodeSigningRequirement("identifier \"\(LimiarIDs.appBundleID)\"")

        connection.exportedInterface = NSXPCInterface(with: LimiarDaemonProtocol.self)
        connection.exportedObject = DaemonService(controller: controller, connection: connection)
        connection.remoteObjectInterface = NSXPCInterface(with: LimiarClientProtocol.self)

        let id = ObjectIdentifier(connection)
        let controller = self.controller
        connection.invalidationHandler = {
            Task { @MainActor in controller.remove(clientID: id) }
        }
        connection.interruptionHandler = connection.invalidationHandler
        connection.resume()
        return true
    }

    private static func isAdmin(uid: uid_t) -> Bool {
        limiar_uid_is_admin(uid) != 0
    }
}

/// Exported object; one per connection. Hops every call onto the main actor.
private final class DaemonService: NSObject, LimiarDaemonProtocol, @unchecked Sendable {
    private let controller: Controller
    private weak var connection: NSXPCConnection?

    init(controller: Controller, connection: NSXPCConnection) {
        self.controller = controller
        self.connection = connection
    }

    func subscribe(reply: @escaping @Sendable (Data) -> Void) {
        let connection = self.connection
        Task { @MainActor [controller] in
            if let connection { controller.add(client: connection) }
            reply(Wire.encode(controller.status))
        }
    }

    func updateSettings(_ data: Data, reply: @escaping @Sendable (String?) -> Void) {
        guard let settings = Wire.decode(Settings.self, data) else { return reply("Ajustes inválidos.") }
        Task { @MainActor [controller] in
            controller.apply(settings: settings)
            reply(nil)
        }
    }

    func setMode(_ data: Data, reply: @escaping @Sendable (String?) -> Void) {
        guard let mode = Wire.decode(ChargeMode.self, data) else { return reply("Modo inválido.") }
        Task { @MainActor [controller] in
            reply(controller.apply(mode: mode))
        }
    }
}
