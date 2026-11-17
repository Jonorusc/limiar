import AppKit
import SwiftUI

/// First-run window: explains Limiar in three lines and walks through enabling the service.
struct WelcomeView: View {
    let model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Welcome to Limiar")
                    .font(.largeTitle.weight(.semibold))
                Text("Keep your battery healthy by stopping charging at a level you choose.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "battery.75percent", color: .green,
                        title: String(localized: "Stops at 80% by default"),
                        detail: String(localized: "Change the limit anytime from the menu bar."))
                Feature(symbol: "powerplug.portrait", color: .green,
                        title: String(localized: "The MagSafe light tells you"),
                        detail: String(localized: "Green: paused at the limit. Orange: charging."))
                Feature(symbol: "moon.zzz", color: .indigo,
                        title: String(localized: "Works in the background"),
                        detail: String(localized: "Even while your Mac sleeps or the app is closed."))
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))

            step
        }
        .padding(32)
        .frame(width: 460)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.serviceState)
        .onAppear { model.refreshServiceState() }
    }

    @ViewBuilder
    private var step: some View {
        switch model.serviceState {
        case .enabled:
            VStack(spacing: 12) {
                Label("All set — Limiar is in your menu bar.", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Button(action: close) { Text("Done").frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.extraLarge)
                    .keyboardShortcut(.defaultAction)
            }
        case .requiresApproval:
            VStack(spacing: 12) {
                Text("In System Settings, switch on **Limiar** in the list of background apps.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button { ServiceInstaller.openLoginItemsSettings() } label: {
                    Text("Open Login Items").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
                ProgressView().controlSize(.small)
            }
        case .notInstalled, .notFound:
            VStack(spacing: 10) {
                Button { model.installService() } label: {
                    Text("Turn On Charge Limit").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
                Text("macOS will ask you to allow Limiar once.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct Feature: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
