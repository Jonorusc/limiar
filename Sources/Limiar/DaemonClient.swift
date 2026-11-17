import Foundation
import LimiarCore

/// Receives pushes from the daemon on XPC's queue and forwards them to the main actor.
private final class ClientSink: NSObject, LimiarClientProtocol, @unchecked Sendable {
    let onStatus: @Sendable (DaemonStatus) -> Void
    let onNotice: @Sendable (PolicyNotice) -> Void

    init(onStatus: @escaping @Sendable (DaemonStatus) -> Void, onNotice: @escaping @Sendable (PolicyNotice) -> Void) {
        self.onStatus = onStatus
        self.onNotice = onNotice
    }

    func statusDidChange(_ status: Data) {
        if let decoded = Wire.decode(DaemonStatus.self, status) { onStatus(decoded) }
    }

    func didEmit(_ notice: Data) {
        if let decoded = Wire.decode(PolicyNotice.self, notice) { onNotice(decoded) }
    }
}

/// Owns the privileged XPC connection, reconnecting with backoff when the daemon goes away.
@MainActor
final class DaemonClient {
    var onStatus: ((DaemonStatus) -> Void)?
    var onNotice: ((PolicyNotice) -> Void)?
    var onUnavailable: (() -> Void)?

    private var connection: NSXPCConnection?
    private var reconnectTask: Task<Void, Never>?
    private var retryDelay: Duration = .seconds(2)

    func connect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.invalidate()

        let conn = NSXPCConnection(machServiceName: LimiarIDs.daemonMachService, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: LimiarDaemonProtocol.self)
        conn.exportedInterface = NSXPCInterface(with: LimiarClientProtocol.self)
        conn.exportedObject = ClientSink(
            onStatus: { [weak self] status in Task { @MainActor in self?.received(status) } },
            onNotice: { [weak self] notice in Task { @MainActor in self?.onNotice?(notice) } }
        )
        // Daemon restarted (KeepAlive): the same connection can be reused, just re-subscribe.
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.subscribe() }
        }
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.handleInvalidation() }
        }
        conn.resume()
        connection = conn
        subscribe()
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.invalidationHandler = nil
        connection?.interruptionHandler = nil
        connection?.invalidate()
        connection = nil
    }

    func updateSettings(_ settings: Settings) async -> String? {
        await call { proxy, done in proxy.updateSettings(Wire.encode(settings), reply: done) }
    }

    func setMode(_ mode: ChargeMode) async -> String? {
        await call { proxy, done in proxy.setMode(Wire.encode(mode), reply: done) }
    }

    // MARK: Private

    private func received(_ status: DaemonStatus) {
        retryDelay = .seconds(2)
        onStatus?(status)
    }

    private func subscribe() {
        guard let proxy = proxy(onError: { [weak self] _ in
            Task { @MainActor in self?.onUnavailable?() }
        }) else { return }
        proxy.subscribe { [weak self] data in
            guard let status = Wire.decode(DaemonStatus.self, data) else { return }
            Task { @MainActor in self?.received(status) }
        }
    }

    private func handleInvalidation() {
        connection = nil
        onUnavailable?()
        reconnectTask?.cancel()
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, .seconds(60))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func proxy(onError: @escaping @Sendable (String) -> Void) -> LimiarDaemonProtocol? {
        connection?.remoteObjectProxyWithErrorHandler { error in
            onError(error.localizedDescription)
        } as? LimiarDaemonProtocol
    }

    private func call(_ body: (LimiarDaemonProtocol, @escaping @Sendable (String?) -> Void) -> Void) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            // XPC guarantees exactly one of reply / error handler runs.
            let once = OnceFlag()
            let finish: @Sendable (String?) -> Void = { message in
                if once.claim() { continuation.resume(returning: message) }
            }
            guard let proxy = proxy(onError: { finish($0) }) else {
                return finish(String(localized: "Background service not running"))
            }
            body(proxy, finish)
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
