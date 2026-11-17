import LimiarCore
import SwiftUI

struct SettingsView: View {
    static let repositoryURL = URL(string: "https://github.com/Jonorusc/limiar")!
    let model: AppModel
    @AppStorage("showPercentage") private var showPercentage = true
    @State private var confirmUninstall = false

    var body: some View {
        Form {
            if let error = model.errorMessage {
                ErrorBanner(message: error, dismiss: model.dismissError)
                    .listRowBackground(Color.clear)
            }

            Section {
                Toggle("Charge limit", isOn: Binding(get: { model.settings.enabled }, set: { model.setEnabled($0) }))
                    .disabled(!model.isConnected)
                if model.isConnected {
                    ChargeRangeControl(
                        level: model.display.soc,
                        limit: model.settings.limit,
                        resumeAt: model.settings.resumeAt,
                        isEnabled: model.settings.enabled
                    ) { limit, resume in model.setRange(limit: limit, resumeAt: resume) }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Charging")
            } footer: {
                if !model.isConnected {
                    Text("Turn on the background service below to change these.")
                }
            }

            Section {
                Toggle("Green MagSafe light while paused", isOn: Binding(
                    get: { model.settings.magSafeGreenWhenPaused },
                    set: { model.setMagSafeGreen($0) }
                ))
                .disabled(!model.isConnected || !(model.status?.hasMagSafeLED ?? false))
                Toggle("Show percentage inside the battery", isOn: $showPercentage)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Green means plugged in but deliberately not charging. Orange means charging.")
            }

            Section("General") {
                Toggle("Open at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                LabeledContent("Background service") {
                    let health = model.serviceHealth
                    let copy = ServiceCopy(health: health)
                    HStack(spacing: 8) {
                        if health == .connecting { ProgressView().controlSize(.small) }
                        Text(copy.short).foregroundStyle(health == .running ? Color.secondary : Color.orange)
                        switch health {
                        case .running:
                            Button("Remove…", role: .destructive) { confirmUninstall = true }
                        case .connecting:
                            EmptyView()
                        case .notInstalled, .needsApproval, .notResponding:
                            Button(copy.button ?? "") { model.fixService() }
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
}
