import Foundation
import os.log

enum SmartChargeError: LocalizedError {
    case unavailable
    case levelRejected(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "The system charge limit service is unavailable"
        case .levelRejected(let level):
            "The system refused a charge limit of \(level)%"
        }
    }
}

/*
 * macOS 27 no longer lets an app pause charging through the SMC, and moved charge
 * policy into the system service that System Settings drives to hold the battery
 * at a level. That service answers an ordinary user process, so holding a level
 * here means asking it for a manual charge limit, which is what running from the
 * adapter without charging needs. It only accepts the levels it advertises, so a
 * level is always chosen from availableLimits.
 */
@MainActor
final class SmartChargeService {
    static let shared = SmartChargeService()

    private let client: AnyObject?
    private let logger = Logger(
        subsystem: "com.srimanachanta.stasis",
        category: "SmartChargeService"
    )

    private typealias AllocFunction = @convention(c) (AnyClass, Selector) -> AnyObject?
    private typealias InitFunction = @convention(c) (AnyObject, Selector, NSString) -> AnyObject?
    private typealias ReadFunction = @convention(c) (
        AnyObject, Selector, UnsafeMutablePointer<NSError?>?
    ) -> UInt8
    private typealias WriteFunction = @convention(c) (
        AnyObject, Selector, UInt8, UnsafeMutablePointer<NSError?>?
    ) -> Bool
    private typealias ListFunction = @convention(c) (
        AnyObject, Selector, UnsafeMutablePointer<NSError?>?
    ) -> NSArray?

    private static let messageSend = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2),
        "objc_msgSend"
    )

    private init() {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil,
              let clientClass = NSClassFromString("PowerUISmartChargeClient"),
              let messageSend = Self.messageSend
        else {
            client = nil
            return
        }

        let allocate = unsafeBitCast(messageSend, to: AllocFunction.self)
        let initialize = unsafeBitCast(messageSend, to: InitFunction.self)

        guard let allocated = allocate(clientClass, NSSelectorFromString("alloc")) else {
            client = nil
            return
        }
        client = initialize(
            allocated,
            NSSelectorFromString("initWithClientName:"),
            Bundle.main.bundleIdentifier as NSString? ?? "Stasis"
        )
    }

    var isSupported: Bool {
        guard let client, let messageSend = Self.messageSend else { return false }
        let supported = unsafeBitCast(
            messageSend,
            to: (@convention(c) (AnyObject, Selector) -> Bool).self
        )
        return supported(client, NSSelectorFromString("isMCLSupported"))
    }

    var availableLimits: [Int] {
        guard let client, let messageSend = Self.messageSend else { return [] }
        let list = unsafeBitCast(messageSend, to: ListFunction.self)
        var error: NSError?
        let limits = list(
            client,
            NSSelectorFromString("availableChargeLimitsWithError:"),
            &error
        )
        return (limits as? [NSNumber])?.map(\.intValue).sorted() ?? []
    }

    var currentLimit: Int? {
        guard let client, let messageSend = Self.messageSend else { return nil }
        let read = unsafeBitCast(messageSend, to: ReadFunction.self)
        var error: NSError?
        let limit = read(client, NSSelectorFromString("getMCLLimitWithError:"), &error)
        if let error {
            logger.error("Reading the system charge limit failed: \(error.localizedDescription)")
            return nil
        }
        return Int(limit)
    }

    /// The highest level the system offers that the battery has already reached, so
    /// applying it holds the charge where it is instead of topping it up first.
    func holdingLevel(forBatteryPercentage percentage: Int) -> Int? {
        availableLimits.filter { $0 <= percentage }.max()
    }

    func setLimit(_ level: Int) throws {
        guard let client, let messageSend = Self.messageSend, let value = UInt8(exactly: level) else {
            throw SmartChargeError.unavailable
        }

        let write = unsafeBitCast(messageSend, to: WriteFunction.self)
        var error: NSError?
        let succeeded = write(
            client,
            NSSelectorFromString("setMCLLimit:error:"),
            value,
            &error
        )

        guard succeeded else {
            logger.error(
                "Setting the system charge limit to \(level)% failed: \(error?.localizedDescription ?? "unknown")"
            )
            throw SmartChargeError.levelRejected(level)
        }
        logger.info("System charge limit set to \(level)%")
    }
}
