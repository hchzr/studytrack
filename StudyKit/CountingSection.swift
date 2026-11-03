import SwiftUI

/// Réglages › Chrono › « Ce qui compte » : ce qui entre dans tes heures travaillées
/// (Aujourd'hui, le bilan, la charge, les widgets, les groupes). La même page sur le Mac,
/// l'iPhone et Windows (`StudyTime.Counting`).
struct CountingSection: View {
    @AppStorage(StudyTime.Counting.key) private var raw: Data = Data()

    private var counting: StudyTime.Counting {
        (try? JSONDecoder().decode(StudyTime.Counting.self, from: raw)) ?? .standard
    }

    private func update(_ change: (inout StudyTime.Counting) -> Void) {
        var value = counting
        change(&value)
        raw = (try? JSONEncoder().encode(value)) ?? Data()
    }

    var body: some View {
        Section {
            Picker("Cours en amphi", selection: Binding(get: { counting.lectures }, set: { v in update { $0.lectures = v } })) {
                Text("Tout seuls").tag(StudyTime.Counting.Lectures.automatic)
                Text("Si confirmés").tag(StudyTime.Counting.Lectures.confirmed)
                Text("Jamais").tag(StudyTime.Counting.Lectures.off)
            }
            Toggle("Séances d'exercices de l'horaire", isOn: Binding(get: { counting.exerciseSessions }, set: { v in update { $0.exerciseSessions = v } }))
            Toggle("Chrono", isOn: Binding(get: { counting.timer }, set: { v in update { $0.timer = v } }))
            Toggle("Saisies à la main", isOn: Binding(get: { counting.manual }, set: { v in update { $0.manual = v } }))
            Toggle("Anki", isOn: Binding(get: { counting.anki }, set: { v in update { $0.anki = v } }))
        } header: {
            Text("Ce qui compte")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        switch counting.lectures {
        case .automatic: String(localized: "Un cours compte une fois fini, sauf marqué manqué. Jamais compté deux fois avec un chrono.")
        case .confirmed: String(localized: "Un cours compte quand tu le coches dans l'agenda (« J'y étais »).")
        case .off: String(localized: "Les cours en amphi ne comptent pas, même chronométrés.")
        }
    }
}
