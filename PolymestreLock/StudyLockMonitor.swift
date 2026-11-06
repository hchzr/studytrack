import DeviceActivity
import ManagedSettings

/// Lève le bouclier du mode étude à l'échéance, **même app fermée**.
///
/// L'app pose le bouclier et planifie une activité qui court jusqu'à la fin
/// du mode étude (`StudyLock.scheduleRelease`). Si l'app dort à ce moment-là
/// (iPhone en poche, aucun push reçu), le système réveille cette extension :
/// l'iPhone ne reste jamais fermé au-delà de l'heure prévue.
final class StudyLockMonitor: DeviceActivityMonitor {
    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        guard activity.rawValue == "studytrack.studyMode" else { return }
        ManagedSettingsStore(named: ManagedSettingsStore.Name("studytrack.studyMode")).clearAllSettings()
    }
}
