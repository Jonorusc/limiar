import LimiarCore
import SwiftUI

struct SettingsView: View {
    static let repositoryURL = URL(string: "https://github.com/Jonorusc/limiar")!
    let model: AppModel
    @AppStorage("showPercentage") private var showPercentage = true
    @State private var confirmUninstall = false

    var body: some View {
        Form {
            Section("Charging") {
                Toggle("Charge limit", isOn: Binding(get: { model.settings.enabled }, set: { model.setEnabled($0) }))
                if model.isConnected {
                    ChargeRangeControl(
                        level: model.display.soc,
                        limit: model.settings.limit,
                        resumeAt: model.settings.resumeAt,
                        isEnabled: model.settings.enabled
                    ) { limit, resume in model.setRange(limit: limit, resumeAt: resume) }
                    .padding(.vertical, 4)
                }
            }

            Section {
                Toggle("Green MagSafe light while paused", isOn: Binding(
                    get: { model.settings.magSafeGreenWhenPaused },
                    set: { model.setMagSafeGreen($0) }
                ))
                .disabled(!(model.status?.hasMagSafeLED ?? false))
                Toggle("Show percentage inside the battery", isOn: $showPercentage)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Green means plugged in but deliberately not charging. Orange means charging.")
            }

            Section("General") {
                Toggle("Open at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                LabeledContent("Background service") {
                    HStack(spacing: 8) {
                        Text(serviceText).foregroundStyle(.secondary)
                        switch model.serviceState {
                        case .enabled:
                            Button("Remove…", role: .destructive) { confirmUninstall = true }
                        case .requiresApproval:
                            Button("Open Login Items") { ServiceInstaller.openLoginItemsSettings() }
                        case .notInstalled, .notFound:
                            Button("Set Up…") { model.installService() }
                        }
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: LimiarIDs.version)
                Link(destination: Self.repositoryURL) {
                    Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Text("Free and open source under the MIT License.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.refreshServiceState() }
        .confirmationDialog("Remove the background service?", isPresented: $confirmUninstall) {
            Button("Remove", role: .destructive) { model.uninstallService() }
        } message: {
            Text("Charging goes back to normal and the MagSafe light returns to macOS control.")
        }
    }

    private var serviceText: String {
        switch model.serviceState {
        case .enabled: String(localized: "Running")
        case .requiresApproval: String(localized: "Waiting for approval")
        case .notInstalled, .notFound: String(localized: "Not installed")
        }
    }
}
