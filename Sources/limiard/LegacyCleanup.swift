import Foundation
import LimiarCore
import os

/// Removes the pre-1.1 install (`com.joaolucas.limiar.daemon`, installed with `sudo make install`).
/// Runs as root on daemon start; a no-op once the files are gone.
enum LegacyCleanup {
    private static let log = Logger(subsystem: LimiarIDs.logSubsystem, category: "legacy")
    private static let label = LimiarIDs.legacyDaemonLabel
    private static let paths = [
        "/Library/LaunchDaemons/\(label).plist",
        "/Library/PrivilegedHelperTools/\(label)",
        "/usr/local/bin/limiard",
    ]

    static func run() {
        let fm = FileManager.default
        guard paths.contains(where: { fm.fileExists(atPath: $0) }) else { return }

        // Stopping it makes the old daemon restore CHIE=0x00; we re-evaluate right after.
        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "system/\(label)"]
        try? bootout.run()
        bootout.waitUntilExit()

        for path in paths {
            // Only remove the CLI symlink if it points at the legacy helper.
            if path == "/usr/local/bin/limiard",
               (try? fm.destinationOfSymbolicLink(atPath: path)) != "/Library/PrivilegedHelperTools/\(label)" {
                continue
            }
            do {
                try fm.removeItem(atPath: path)
                log.info("removed legacy \(path, privacy: .public)")
            } catch {
                log.error("could not remove \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }
}
