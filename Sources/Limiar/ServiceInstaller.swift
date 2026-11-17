import Foundation
import LimiarCore
import ServiceManagement

/// Installs the privileged daemon that lives inside the app bundle
/// (`Contents/Library/LaunchDaemons/app.limiar.daemon.plist`) via `SMAppService`.
/// macOS lists it in System Settings › General › Login Items as "Limiar" with the app icon.
@MainActor
enum ServiceInstaller {
    enum State: Equatable {
        case notInstalled
        case requiresApproval
        case enabled
        case notFound
    }

    private static var service: SMAppService { .daemon(plistName: LimiarIDs.daemonPlistName) }

    static var state: State {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notInstalled
        @unknown default: .notInstalled
        }
    }

    /// Registers the daemon. Usually ends in `.requiresApproval` the first time.
    static func install() throws -> State {
        do {
            try service.register()
        } catch {
            // The first registration throws "Operation not permitted" while it awaits the user's
            // approval in Login Items; that, or "already registered", is not a failure.
            let current = state
            if current == .requiresApproval || current == .enabled { return current }
            throw error
        }
        return state
    }

    /// Unregistering stops the daemon; launchd sends SIGTERM and the daemon restores wall power.
    static func uninstall() async throws {
        try await service.unregister()
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
