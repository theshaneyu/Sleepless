// BatteryReader.swift. The internal battery as IOKit reports it, for the phone dashboard.
import Foundation
import IOKit
import IOKit.ps

struct BatterySnapshot: Encodable {
    let percent: Int
    let onBattery: Bool
    let charging: Bool
    let minutesRemaining: Int?   // to empty on battery, to full while charging; nil while macOS estimates
}

func readBattery() -> BatterySnapshot? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
    for source in sources {
        guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
              description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let current = description[kIOPSCurrentCapacityKey] as? Int,
              let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
        let onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
        let charging = description[kIOPSIsChargingKey] as? Bool ?? false
        let minutes = description[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
        return BatterySnapshot(percent: current * 100 / max, onBattery: onBattery, charging: charging,
                               minutesRemaining: minutes.flatMap { $0 > 0 ? $0 : nil })
    }
    return nil
}

// The whole Mac's draw from the battery, in watts. Nil on power, where the battery isn't the
// source. IOPS doesn't report voltage, so this reads the battery's own registry entry.
func readDischargeWatts() -> Double? {
    let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard battery != 0 else { return nil }
    defer { IOObjectRelease(battery) }
    func number(_ key: String) -> NSNumber? {
        IORegistryEntryCreateCFProperty(battery, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
    }
    guard number("ExternalConnected")?.boolValue == false,
          let milliamps = number("InstantAmperage")?.int64Value ?? number("Amperage")?.int64Value, milliamps < 0,
          let millivolts = number("Voltage")?.int64Value, millivolts > 0 else { return nil }
    return Double(-milliamps) * Double(millivolts) / 1_000_000
}
