import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import os.log

@MainActor
class IOKitService {
    private var notificationPort: IONotificationPortRef?
    private var interestNotification: io_object_t = 0
    private var batteryService: io_service_t = 0
    private var batteryPackService: io_service_t = 0

    private var continuation: AsyncStream<(BatteryMetrics, AdapterMetrics)>.Continuation?

    private let logger = Logger(
        subsystem: "com.srimanachanta.stasis",
        category: "IOKitService"
    )

    func metricsStream() -> AsyncStream<(BatteryMetrics, AdapterMetrics)> {
        AsyncStream { continuation in
            self.continuation = continuation

            continuation.onTermination = { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.stop()
                }
            }

            self.startNotifications()
        }
    }

    private func startNotifications() {
        logger.info("Starting IOKit monitoring")

        batteryService = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        if batteryService == 0 {
            logger.error("Failed to get AppleSmartBattery service")
        }

        guard batteryService != 0 else { return }

        batteryPackService = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBatteryPack")
        )
        if batteryPackService == 0 {
            logger.error("Failed to get AppleSmartBatteryPack service")
        }

        notificationPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notificationPort else {
            logger.error("Failed to create IONotificationPort")
            return
        }

        let notificationSource = IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), notificationSource, .commonModes)

        let context = UnsafeMutableRawPointer(
            Unmanaged.passUnretained(self).toOpaque()
        )

        let callback: IOServiceInterestCallback = { refcon, _, _, _ in
            guard let refcon else { return }
            let monitor = Unmanaged<IOKitService>.fromOpaque(refcon)
                .takeUnretainedValue()
            MainActor.assumeIsolated {
                monitor.emitMetrics()
            }
        }

        let result = IOServiceAddInterestNotification(
            notificationPort,
            batteryService,
            kIOGeneralInterest,
            callback,
            context,
            &interestNotification
        )

        if result == KERN_SUCCESS {
            logger.info("IORegistry interest notification registered for AppleSmartBattery")
        } else {
            logger.error("Failed to register interest notification: \(result)")
        }

        emitMetrics()
    }

    private func stop() {
        if interestNotification != 0 {
            IOObjectRelease(interestNotification)
            interestNotification = 0
        }
        if let notificationPort {
            let source = IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue()
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        if batteryService != 0 {
            IOObjectRelease(batteryService)
            batteryService = 0
        }
        if batteryPackService != 0 {
            IOObjectRelease(batteryPackService)
            batteryPackService = 0
        }
        continuation = nil
    }

    private func emitMetrics() {
        logger.debug("IOKit notification triggered")

        let powerInfo = getPowerSourceInfo() as? [String: Any]
        var batteryMetrics = BatteryMetrics()
        var adapterMetrics = AdapterMetrics()

        let percentages = getBatteryPercentages(powerInfo: powerInfo)
        batteryMetrics.batteryPercentage = percentages.displayed
        batteryMetrics.hardwareBatteryPercentage = percentages.hardware

        batteryMetrics.isCharging = powerInfo?[kIOPSIsChargingKey] as? Bool ?? false
        if batteryMetrics.isCharging {
            batteryMetrics.timeRemaining = getTimeToFull(powerInfo: powerInfo) ?? -1
        } else {
            batteryMetrics.timeRemaining = getTimeRemaining(powerInfo: powerInfo) ?? -1
        }

        let capacities = getBatteryCapacities()
        batteryMetrics.batteryHealth =
            capacities.design > 0
            ? (capacities.max * 100) / capacities.design
            : 100

        batteryMetrics.externalConnected =
            getPropertyValue(batteryService, key: "ExternalConnected")
            ?? getPropertyValue(batteryService, key: "AppleRawExternalConnected")
            ?? false

        adapterMetrics.adapterConnected = isAdapterConnected()

        if let temp = getBatteryTemperature() {
            batteryMetrics.batteryTemperature = temp
        }

        batteryMetrics.cycleCount = gaugeValue("CycleCount") ?? 0

        logger.debug(
            "IOKit metrics: battery=\(batteryMetrics.batteryPercentage)%, hardwareBattery=\(batteryMetrics.hardwareBatteryPercentage)%, health=\(batteryMetrics.batteryHealth)%, charging=\(batteryMetrics.isCharging), temp=\(batteryMetrics.batteryTemperature)°C, cycles=\(batteryMetrics.cycleCount), timeRemaining=\(batteryMetrics.timeRemaining), externalConnected=\(batteryMetrics.externalConnected), adapterConnected=\(adapterMetrics.adapterConnected)"
        )

        continuation?.yield((batteryMetrics, adapterMetrics))
    }

    private nonisolated func getPowerSourceInfo() -> CFDictionary? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources =
            IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        guard let source = sources.first else { return nil }
        return IOPSGetPowerSourceDescription(snapshot, source)
            .takeUnretainedValue()
    }

    private nonisolated func getPropertyValue<T>(_ service: io_service_t, key: String) -> T? {
        guard
            let prop = IORegistryEntryCreateCFProperty(
                service,
                key as CFString,
                kCFAllocatorDefault,
                0
            )
        else {
            return nil
        }
        return prop.takeRetainedValue() as? T
    }

    /// macOS 27 removed the detailed gauge properties from AppleSmartBattery and
    /// publishes them inside the BatteryData dictionary of the battery itself or
    /// of its AppleSmartBatteryPack child, so every location is tried in turn.
    private func gaugeValue<T>(_ key: String) -> T? {
        if let value: T = getPropertyValue(batteryService, key: key) {
            return value
        }
        for service in [batteryService, batteryPackService] where service != 0 {
            if let batteryData: [String: Any] = getPropertyValue(service, key: "BatteryData"),
               let value = batteryData[key] as? T {
                return value
            }
        }
        return nil
    }

    private func getBatteryPercentages(powerInfo: [String: Any]?) -> (
        displayed: Int, hardware: Int
    ) {
        let displayedPercent = powerInfo?[kIOPSCurrentCapacityKey] as? Int ?? 0

        let rawCurrentCapacity: Int = gaugeValue("AppleRawCurrentCapacity") ?? 0
        let rawMaxCapacity: Int = gaugeValue("AppleRawMaxCapacity") ?? 0

        let hardwarePercent: Int
        if rawMaxCapacity > 0 {
            hardwarePercent = (rawCurrentCapacity * 100) / rawMaxCapacity
        } else {
            let currentCapacity: Int =
                gaugeValue("CurrentCapacity") ?? displayedPercent
            hardwarePercent = currentCapacity
        }

        return (displayedPercent, hardwarePercent)
    }

    private func getTimeRemaining(powerInfo: [String: Any]?) -> Int? {
        guard let timeToEmpty = powerInfo?[kIOPSTimeToEmptyKey] as? Int,
              timeToEmpty > 0,
              timeToEmpty != Int(kIOPSTimeRemainingUnknown) else {
            return nil
        }

        return timeToEmpty
    }

    private func getTimeToFull(powerInfo: [String: Any]?) -> Int? {
        guard let timeToFull = powerInfo?[kIOPSTimeToFullChargeKey] as? Int,
              timeToFull > 0,
              timeToFull != Int(kIOPSTimeRemainingUnknown) else {
            return nil
        }

        return timeToFull
    }

    private func isAdapterConnected() -> Bool {
        guard let adapterDetails: [String: Any] = getPropertyValue(batteryService, key: "AdapterDetails"),
              let watts = adapterDetails["Watts"] as? Int else {
            return false
        }

        return watts > 0
    }

    /// The gauge reports temperature in hundredths of a degree Celsius, under
    /// "Temperature" or, when the pack only exposes the modelled value, under
    /// "VirtualTemperature".
    private func getBatteryTemperature() -> Double? {
        guard let raw: Int = gaugeValue("Temperature") ?? gaugeValue("VirtualTemperature"),
              raw > 0
        else {
            return nil
        }

        let celsius = Double(raw) / 100.0
        return (0...80).contains(celsius) ? celsius : nil
    }

    private func getBatteryCapacities() -> (current: Int, max: Int, design: Int) {
        let currentCapacity: Int = gaugeValue("AppleRawCurrentCapacity") ?? 0
        let maxCapacity: Int = gaugeValue("AppleRawMaxCapacity") ?? 0
        let designCapacity: Int = gaugeValue("DesignCapacity") ?? 0

        return (currentCapacity, maxCapacity, designCapacity)
    }
}
