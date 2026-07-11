import Foundation
import IOKit

/// Reads charge state from the AppleSmartBattery gas gauge.
///
/// The SMC battery channel (PPBR) only reports power drawn *from* the
/// battery, so while charging it sits near zero and the panel can't explain
/// why the adapter delivers far more than the system consumes. The gauge's
/// signed amperage exposes the inflow.
final class BatteryInfo {
    struct State {
        let isCharging: Bool
        /// Power flowing into the battery, in watts. Zero unless charging.
        let chargeWatts: Double
    }

    private let service: io_service_t

    init?() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        self.service = service
    }

    deinit {
        IOObjectRelease(service)
    }

    func read() -> State? {
        guard let charging = property("IsCharging") as? Bool,
              let amperage = (property("Amperage") as? NSNumber)?.int64Value,
              let voltage = (property("Voltage") as? NSNumber)?.int64Value
        else { return nil }
        // Amperage is signed milliamps, positive while charging; Voltage is
        // millivolts.
        let watts = Double(amperage) * Double(voltage) / 1_000_000
        return State(isCharging: charging, chargeWatts: charging ? max(0, watts) : 0)
    }

    private func property(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }
}
