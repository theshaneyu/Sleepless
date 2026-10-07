// BatteryReader.swift. The internal battery as IOKit reports it, for the phone dashboard.
import Foundation
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
