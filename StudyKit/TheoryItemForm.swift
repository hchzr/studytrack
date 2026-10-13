import SwiftUI
import SwiftData

/// Un élément de théorie (vidéo, lecture, chapitre, transparents) : l'ajouter,
/// ou le corriger — numéro, titre, semaine, lien — et le supprimer. Le même
/// formulaire sur l'iPhone et le Mac. On ne pouvait qu'en **ajouter** : un
/// numéro mal lu à l'import restait faux.
struct TheoryItemForm: View {
    let course: Course
    var item: TheoryItem? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var kind: TheoryKind = .video
    @State private var number = ""
    @State private var title = ""
    @State private var minutes = 45
    @State private var week = 1
    @State private var section = 1
    @State private var useAutoSection = true
    @State private var link = ""
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Support", selection: $kind) {
                        ForEach(TheoryKind.allCases) { value in
                            Label(value.label, systemImage: value.icon).tag(value)
                        }
                    }
                    TextField("Numéro (ex : 1.4)", text: $number)
                    TextField("Titre", text: $title)
                    if kind.hasDuration {
                        Stepper("Durée : \(minutes) min", value: $minutes, in: 1...300, step: 5)
                    }
                    TextField("Lien (facultatif)", text: $link)
                        .urlField()
                } header: {
                    Text("Support")
                }
                Section {
                    Stepper("Semaine : \(week)", value: $week, in: 1...30)
                    Toggle("Déduire la section du numéro", isOn: $useAutoSection)
                    if !useAutoSection {
                        Stepper("Section : \(section)", value: $section, in: 1...40)
                    }
                } header: {
                    Text("Planification")
                }
                if item != nil {
                    Section {
                        Button("Supprimer", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .formStyle(.grouped)
            .carnetBackground()
            .navigationTitle(item == nil ? "Ajouter de la théorie" : "Modifier la théorie")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(item == nil ? "Ajouter" : "Enregistrer") { save() }
                        .disabled(number.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Supprimer « \(item?.numberAndTitle ?? "") » ?", isPresented: $confirmingDelete,
                                titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) { delete() }
            } message: {
                Text("Le temps déjà passé dessus reste, sans cible.")
            }
            .onAppear(perform: load)
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }

    private func load() {
        guard let item else {
            week = course.currentWeek
            return
        }
        kind = item.kind
        number = item.number
        title = item.title
        minutes = max(1, item.durationSeconds / 60)
        week = max(1, item.plannedWeek)
        section = item.sectionNumber
        useAutoSection = (Int(item.number.split(separator: ".").first ?? "") ?? -1) == item.sectionNumber
        link = item.urlString
    }

    private func save() {
        let value = number.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        let resolvedSection = useAutoSection ? (Int(value.split(separator: ".").first ?? "1") ?? 1) : section
        // Un support sans durée n'en invente pas une.
        let duration = kind.hasDuration ? minutes * 60 : 0
        if let item {
            item.kindRaw = kind.rawValue
            item.number = value
            item.title = title
            item.durationSeconds = duration
            item.plannedWeek = week
            item.sectionNumber = resolvedSection
            item.urlString = link.trimmingCharacters(in: .whitespaces)
        } else {
            context.insert(TheoryItem(course: course, sectionNumber: resolvedSection, number: value, title: title,
                                      kind: kind, durationSeconds: duration, plannedWeek: week,
                                      sortOrder: course.theoryItems.count,
                                      urlString: link.trimmingCharacters(in: .whitespaces)))
        }
        try? context.save()
        Haptics.success()
        dismiss()
    }

    private func delete() {
        guard let item else { return }
        context.delete(item)
        try? context.save()
        Haptics.removed()
        dismiss()
    }
}
