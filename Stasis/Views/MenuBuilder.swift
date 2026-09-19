import Defaults
import SwiftUI

/// SwiftUI content shown when the user opens the `MenuBarExtra`. Replaces the
/// former AppKit `NSMenu` so the whole menu bar presence is SwiftUI-managed.
struct MenuContentView: View {
    let viewModel: MenuViewModel
    let settingsWindowController: SettingsWindowController?

    @Default(.showPowerSource) private var showPowerSource
    @Default(.showTimeTillDischarge) private var showTimeTillDischarge
    @Default(.showUptime) private var showUptime
    @Default(.showBatteryMode) private var showBatteryMode
    @Default(.showBatteryTemperature) private var showBatteryTemperature
    @Default(.showInternalPower) private var showInternalPower
    @Default(.showExternalPower) private var showExternalPower
    @Default(.showPowerDistribution) private var showPowerDistribution
    @Default(.showBatteryCycleCount) private var showBatteryCycleCount
    @Default(.showBatteryHealth) private var showBatteryHealth
    @Default(.showWorkWithAC) private var showWorkWithAC
    @Default(.showChargeLimitOverride) private var showChargeLimitOverride
    @Default(.showForceDischarge) private var showForceDischarge
    @Default(.manageCharging) private var manageCharging

    private var infoHasContent: Bool {
        showPowerSource || showTimeTillDischarge || showUptime || showBatteryMode
            || showBatteryTemperature
    }

    private var powerMetricsHasContent: Bool {
        showInternalPower || showExternalPower
    }

    private var hardwareHasContent: Bool {
        showBatteryCycleCount || showBatteryHealth
    }

    private var chargingHasContent: Bool {
        manageCharging && (showWorkWithAC || showChargeLimitOverride || showForceDischarge)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BatteryMainInfo(
                label: String(localized: "Battery"),
                value: viewModel.batteryPercentageText
            )

            if infoHasContent {
                sectionDivider
                if showPowerSource {
                    BatteryAdditionalInfo(
                        label: String(localized: "Power Source"),
                        value: viewModel.powerSourceText
                    )
                }
                if showTimeTillDischarge {
                    BatteryAdditionalInfo(
                        label: String(localized: "Time Remaining"),
                        value: viewModel.timeRemainingText
                    )
                }
                if showUptime {
                    BatteryAdditionalInfo(
                        label: String(localized: "Uptime"),
                        value: viewModel.uptimeText
                    )
                }
                if showBatteryMode {
                    BatteryAdditionalInfo(
                        label: String(localized: "Battery Mode"),
                        value: viewModel.batteryModeText
                    )
                }
                if showBatteryTemperature {
                    BatteryAdditionalInfo(
                        label: String(localized: "Battery Temperature"),
                        value: viewModel.batteryTemperatureText
                    )
                }
            }

            if powerMetricsHasContent {
                sectionDivider
                if showInternalPower {
                    BatteryAdditionalInfo(
                        label: String(localized: "Battery"),
                        value: viewModel.internalInputText
                    )
                }
                if showExternalPower {
                    BatteryAdditionalInfo(
                        label: String(localized: "Adapter"),
                        value: viewModel.externalInputText
                    )
                }
            }

            if showPowerDistribution {
                sectionDivider
                PowerSankeyView(
                    powerSource: viewModel.powerSource,
                    isCharging: viewModel.isCharging,
                    batteryPower: viewModel.batteryPower,
                    adapterPower: viewModel.adapterPower,
                    systemPower: viewModel.systemPower
                )
            }

            if hardwareHasContent {
                sectionDivider
                if showBatteryCycleCount {
                    BatteryAdditionalInfo(
                        label: String(localized: "Cycle Count"),
                        value: viewModel.cycleCountText
                    )
                }
                if showBatteryHealth {
                    BatteryAdditionalInfo(
                        label: String(localized: "Battery Health"),
                        value: viewModel.batteryHealthText
                    )
                }
            }

            if let chargeControlFailure = viewModel.chargeControlFailure {
                sectionDivider
                Text("Charge control failed: \(chargeControlFailure)")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            }

            if chargingHasContent {
                sectionDivider
                if showWorkWithAC {
                    WorkWithACToggleView(viewModel: viewModel)
                }
                if showChargeLimitOverride {
                    ChargeLimitOverrideToggleView(viewModel: viewModel)
                }
                if showForceDischarge {
                    ForceDischargeToggleView(viewModel: viewModel)
                }
            }

            sectionDivider
            MenuActionButton(title: String(localized: "Settings")) {
                settingsWindowController?.showSettings()
            }
            MenuActionButton(title: String(localized: "Quit")) {
                viewModel.quit()
            }
            .padding(.bottom, 4)
        }
        .frame(width: 300)
        .onAppear { viewModel.menuWillOpen() }
        .onDisappear { viewModel.menuDidClose() }
    }

    private var sectionDivider: some View {
        Divider().padding(.vertical, 4)
    }
}

private struct MenuActionButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering ? Color.accentColor.opacity(0.85) : Color.clear)
                    .padding(.horizontal, 5)
            )
            .foregroundStyle(isHovering ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct ChargeLimitOverrideToggleView: View {
    let viewModel: MenuViewModel

    var body: some View {
        HStack {
            Text("Charge Limit Override")
            Spacer(minLength: 20)
            Toggle(
                "Charge Limit Override",
                isOn: Binding(
                    get: { viewModel.chargeLimitOverrideActive },
                    set: { _ in viewModel.toggleChargeLimitOverride() }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(
                !viewModel.adapterConnected
                    || viewModel.forceDischargeActive
                    || viewModel.workWithACActive
            )
        }
        .foregroundColor(.secondary)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

struct ForceDischargeToggleView: View {
    let viewModel: MenuViewModel

    var body: some View {
        HStack {
            Text("Force Discharge")
            Spacer(minLength: 20)
            Toggle(
                "Force Discharge",
                isOn: Binding(
                    get: { viewModel.forceDischargeActive },
                    set: { _ in viewModel.toggleForceDischarge() }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(
                !viewModel.adapterConnected
                    || viewModel.chargeLimitOverrideActive
                    || viewModel.workWithACActive
            )
        }
        .foregroundColor(.secondary)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

struct WorkWithACToggleView: View {
    let viewModel: MenuViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Work with AC")
                Spacer(minLength: 20)
                Toggle(
                    "Work with AC",
                    isOn: Binding(
                        get: { viewModel.workWithACActive },
                        set: { _ in viewModel.toggleWorkWithAC() }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(!viewModel.adapterConnected || viewModel.forceDischargeActive)
            }
            Text(viewModel.workWithACStatusText)
                .font(.caption)
                .foregroundStyle(statusColor)
        }
        .foregroundColor(.secondary)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        if viewModel.workWithACChargingDetected {
            return .red
        }
        if viewModel.workWithACBatteryAssistDetected {
            return .orange
        }
        return .secondary
    }
}
