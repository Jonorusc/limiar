import Foundation
import LimiarCore

/// Persists settings and the active mode so a restart (or crash + KeepAlive) resumes correctly.
struct PersistedState: Codable, Equatable {
    var settings = Settings()
    var mode: ChargeMode = .normal
}

enum Store {
    static let directory = URL(fileURLWithPath: "/Library/Application Support/Limiar", isDirectory: true)
    static let file = directory.appendingPathComponent("state.json")

    static func load() -> PersistedState {
        guard let data = try? Data(contentsOf: file),
              var state = try? JSONDecoder().decode(PersistedState.self, from: data)
        else { return PersistedState() }
        state.settings = state.settings.validated()
        return state
    }

    static func save(_ state: PersistedState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: file, options: .atomic)
    }
}
