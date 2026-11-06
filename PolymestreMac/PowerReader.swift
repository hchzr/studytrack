import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// La lecture de l'alimentation (secteur ou batterie, niveau, charge), **une seule** :
/// la garde d'éveil (`MacKeepAwake`) et la barre d'état du bureau (`DeskStatus`)
/// lisaient chacune les sources d'énergie à leur manière.
enum PowerReader {
    struct Snapshot: Equatable {
        var onBattery = false
        /// 0…1, `nil` sans batterie (Mac de bureau).
        var level: Double?
        var charging = false
    }

    static func read() -> Snapshot {
        var snapshot = Snapshot()
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return snapshot }
        if let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            snapshot.onBattery = providing == kIOPMBatteryPowerKey
        }
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            snapshot.level = Double(current) / Double(max)
            snapshot.charging = (description[kIOPSIsChargingKey] as? Bool) ?? false
        }
        return snapshot
    }

    /// Ce que la garde d'éveil décide à partir de cette lecture.
    static func keepAwakePower() -> KeepAwakePolicy.Power {
        let snapshot = read()
        var power = KeepAwakePolicy.Power(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        power.onBattery = snapshot.onBattery
        power.batteryLevel = snapshot.level
        return power
    }
}
