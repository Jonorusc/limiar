import AppKit
import LimiarCore
import SwiftUI

enum Tokens {
    static let width: CGFloat = 320
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 12
    static let cardRadius: CGFloat = 18
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let dischargeTargets = [20, 30, 40, 50, 60, 70]
}

extension StatusTint {
    var color: Color {
        switch self {
        case .charging: .orange
        case .holding: .green
        case .neutral: .secondary
        }
    }
}

struct MenuView: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var showDischargeTargets = false

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.spacing) {
            header
            if let error = model.errorMessage { ErrorBanner(message: error, dismiss: model.dismissError) }
            if model.isConnected {
                modeBanner
                limitCard
                actions
            } else {
                ServiceSetupCard(model: model)
            }
            footer
        }
        .padding(Tokens.padding)
        .frame(width: Tokens.width)
        .animation(Tokens.spring, value: model.display)
        .animation(Tokens.spring, value: model.mode)
        .animation(Tokens.spring, value: model.isConnected)
    }

    // MARK: Header

    private var header: some View {
        let display = model.display
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(display.soc)%")
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(display.soc)))
            Label {
                Text(display.title)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: display.isCharging ? "bolt.fill" : "circle.fill")
                    .imageScale(display.isCharging ? .medium : .small)
                    .foregroundStyle(display.tint.color)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Mode banner

    @ViewBuilder
    private var modeBanner: some View {
        if model.mode != .normal {
            HStack(spacing: 10) {
                Image(systemName: isDischarging ? "arrow.down.circle.fill" : "bolt.circle.fill")
                    .font(.title3)
                    .foregroundStyle(isDischarging ? .green : .orange)
                Text(modeText).font(.callout)
                Spacer(minLength: 0)
                Button("Cancel") { model.cancelMode() }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            .padding(10)
            .background(.fill.quinary, in: .rect(cornerRadius: Tokens.cardRadius, style: .continuous))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var isDischarging: Bool {
        if case .discharge = model.mode { return true }
        return false
    }

    private var modeText: String {
        switch model.mode {
        case .discharge(let target): String(localized: "Discharging to \(target)%")
        case .topUp(let completed): completed ? String(localized: "Holding at 100%") : String(localized: "Charging to 100% once")
        case .normal: ""
        }
    }

    // MARK: Limit card

    private var limitCard: some View {
        let settings = model.settings
        return VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(get: { settings.enabled }, set: { model.setEnabled($0) })) {
                Text("Charge Limit").font(.headline)
            }
            .toggleStyle(.switch)

            ChargeRangeControl(
                level: model.display.soc,
                limit: settings.limit,
                resumeAt: settings.resumeAt,
                isEnabled: settings.enabled
            ) { limit, resume in
                model.setRange(limit: limit, resumeAt: resume)
            }
        }
        .padding(14)
        .background(.fill.quinary, in: .rect(cornerRadius: Tokens.cardRadius, style: .continuous))
    }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button { model.topUp() } label: {
                        Label("Charge to 100%", systemImage: "bolt.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(isTopUp || !model.settings.enabled)
                    .help(Text("Charges to 100% once. The limit comes back when you unplug."))

                    Button {
                        withAnimation(Tokens.spring) { showDischargeTargets.toggle() }
                    } label: {
                        Label("Discharge…", systemImage: "arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(dischargeTargets.isEmpty || !model.settings.enabled)
                    .help(Text("Runs on battery while plugged in, down to the level you pick."))
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .labelStyle(.titleAndIcon)
            }

            if showDischargeTargets && !dischargeTargets.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Use battery until")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    GlassEffectContainer(spacing: 6) {
                        HStack(spacing: 6) {
                            ForEach(dischargeTargets, id: \.self) { target in
                                Button("\(target)%") {
                                    model.discharge(to: target)
                                    withAnimation(Tokens.spring) { showDischargeTargets = false }
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var dischargeTargets: [Int] {
        Tokens.dischargeTargets.filter { $0 < model.display.soc }
    }

    private var isTopUp: Bool {
        if case .topUp = model.mode { return true }
        return false
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let battery = model.battery {
                Text(healthLine(battery))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            Button {
                openSettings()
                NSApp.activate()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help(Text("Settings…"))
            .keyboardShortcut(",")

            Button { NSApplication.shared.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help(Text("Quit Limiar"))
            .keyboardShortcut("q")
        }
        .padding(.top, 2)
    }

    private func healthLine(_ battery: BatteryReading) -> String {
        String(localized: "Health \(battery.healthPercent)% · \(battery.cycleCount) cycles")
    }
}

// MARK: - Components

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Dismiss"))
        }
        .padding(10)
        .background(.yellow.opacity(0.12), in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// Shown when the background service isn't running yet.
struct ServiceSetupCard: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(title).font(.headline)
            } icon: {
                Image(systemName: "lock.shield").foregroundStyle(.green)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: primaryAction) {
                Text(buttonTitle).frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .padding(14)
        .background(.fill.quinary, in: .rect(cornerRadius: Tokens.cardRadius, style: .continuous))
        .onAppear { model.refreshServiceState() }
    }

    private var needsApproval: Bool { model.serviceState == .requiresApproval }

    private var title: String {
        if model.needsReapproval { return String(localized: "Limiar was updated") }
        return needsApproval ? String(localized: "Allow Limiar in Login Items") : String(localized: "Turn on the charge limit")
    }

    private var message: String {
        if model.needsReapproval {
            return String(localized: "macOS needs you to allow the new version once. Charging works normally until then.")
        }
        return needsApproval
            ? String(localized: "Switch on Limiar in the list of background apps. This lets it pause charging even when the app is closed.")
            : String(localized: "Limiar uses a small background service to pause charging. macOS will ask you to allow it once.")
    }

    private var buttonTitle: String {
        if model.needsReapproval { return String(localized: "Allow Again…") }
        return needsApproval ? String(localized: "Open Login Items") : String(localized: "Set Up…")
    }

    private func primaryAction() {
        if model.needsReapproval {
            model.reapproveService()
        } else if needsApproval {
            ServiceInstaller.openLoginItemsSettings()
        } else {
            model.installService()
        }
    }
}
