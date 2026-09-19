import AppKit
import IOKit
import SwiftUI
import UserNotifications

@MainActor
@Observable
final class AppState {
    let viewModel: MenuViewModel
    private(set) var settingsWindowController: SettingsWindowController?

    private let batteryService: BatteryService
    private let chargeManager: ChargeManager

    init() {
        batteryService = BatteryService()
        chargeManager = ChargeManager(batteryService: batteryService)
        viewModel = MenuViewModel(
            batteryService: batteryService,
            chargeManager: chargeManager
        )

        Task { [weak self] in
            guard let self else { return }
            await self.batteryService.loadCapabilities()
            self.settingsWindowController = SettingsWindowController(
                capabilities: self.batteryService.deviceCapabilities
            )
        }

        requestNotificationPermissions()
    }

    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }
}

/// Returns false when the machine has no internal battery, so the app can exit.
@MainActor
private func deviceHasBattery() -> Bool {
    let service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching("AppleSmartBattery")
    )
    guard service != 0 else { return false }
    IOObjectRelease(service)
    return true
}

@main
struct StasisApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(
                viewModel: appState.viewModel,
                settingsWindowController: appState.settingsWindowController
            )
            .onAppear {
                if !deviceHasBattery() {
                    NSApplication.shared.terminate(nil)
                }
            }
        } label: {
            BatteryLabelView(viewModel: appState.viewModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            EmptyView()
        }
    }
}
