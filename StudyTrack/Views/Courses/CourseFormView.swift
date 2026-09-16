import SwiftUI
import SwiftData

/// Création ou modification d'un cours.
///
/// Un seul formulaire pour les deux usages : les champs essentiels d'abord,
/// les heures de cours conditionnées par « ce cours a-t-il un amphi ? ».
struct CourseFormView: View {
    var course: Course?
    var defaultSectionCode: String = ""

    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \AcademicTerm.startDate, order: .reverse) private var terms: [AcademicTerm]

    @State private var code = ""
    @State private var name = ""
    @State private var shortName = ""
    @State private var credits = 4.0
    @State private var hasLectures = true
    @State private var lectureHours = 2.0
    @State private var exerciseHours = 1.0
    @State private var autoSelfStudy = true
    @State private var selfStudyHours = 0.0
    @State private var colorHex = Theme.coursePalette[0]
    @State private var sectionCode = ""
    @State private var lecturer = ""
    @State private var link = ""
    @State private var selectedTermID: UUID?
    @State private var isTracked = true

    private var isEditing: Bool { course != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identification") {
                    TextField("Code (ex : CS-250)", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    TextField("Nom du cours", text: $name)
                    // Le nom complet ne tient pas dans une rangée : l'abréviation
                    // est ce qui s'affiche partout où la place manque.
                    TextField("Abréviation (ex : ALGO)", text: $shortName)
                        .autocorrectionDisabled()
                    TextField("Enseignant (optionnel)", text: $lecturer)
                }

                Section {
                    Toggle("Ce cours a des heures de cours (amphi)", isOn: $hasLectures)
                    if hasLectures {
                        Stepper("Heures d'amphi / semaine : \(fmt(lectureHours)) h",
                                value: $lectureHours, in: 0...20, step: 0.5)
                    }
                    Stepper("Heures d'exercices / semaine : \(fmt(exerciseHours)) h",
                            value: $exerciseHours, in: 0...20, step: 0.5)
                    Stepper("Crédits : \(Int(credits)) ECTS", value: $credits, in: 1...40, step: 1)
                } header: {
                    Text("Charge hebdomadaire")
                } footer: {
                    Text(hasLectures
                         ? "Les heures d'amphi comptent dans le temps prévu par l'EPFL et servent au suivi de présence."
                         : "Aucune heure d'amphi ne sera comptée : seules les heures d'exercices et le travail personnel sont attendus.")
                }

                Section {
                    Toggle("Déduire des ECTS", isOn: $autoSelfStudy)
                    if !autoSelfStudy {
                        Stepper("Travail personnel : \(fmt(selfStudyHours)) h / semaine",
                                value: $selfStudyHours, in: 0...40, step: 0.5)
                    }
                } header: {
                    Text("Travail personnel / semaine")
                } footer: {
                    // L'attendu est hebdomadaire : c'est la seule comparaison qui
                    // se traduise en action, un total semestriel ne dit rien.
                    Text(autoSelfStudy
                         ? "Déduit de la charge ECTS : \(fmt(impliedSelfStudyHours)) h / semaine une fois les heures encadrées retirées. L'écart EPFL est calculé **par semaine**."
                         : "Objectif fixé à la main. L'écart EPFL est calculé **par semaine**.")
                }

                Section("Section EPFL") {
                    Picker("Section", selection: $sectionCode) {
                        Text("Non renseignée").tag("")
                        ForEach(EPFLCatalog.sections) { section in
                            Text("\(section.name) (\(section.code))").tag(section.code)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }

                Section("Couleur") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Theme.coursePalette, id: \.self) { hex in
                                Button {
                                    colorHex = hex
                                    Haptics.soft()
                                } label: {
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 34, height: 34)
                                        .overlay(
                                            Circle().stroke(Color.primary,
                                                            lineWidth: colorHex == hex ? 2.5 : 0)
                                        )
                                        .frame(width: Layout.minTouch, height: Layout.minTouch)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Semestre") {
                    if terms.isEmpty {
                        Text("Un semestre sera créé automatiquement.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Semestre", selection: $selectedTermID) {
                            ForEach(terms) { term in
                                Text(term.displayName).tag(UUID?.some(term.id))
                            }
                        }
                    }
                    Toggle("Suivre ce cours", isOn: $isTracked)
                }

                Section("Lien (optionnel)") {
                    TextField("URL du cours", text: $link)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }
            }
            .navigationTitle(isEditing ? "Modifier le cours" : "Nouveau cours")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Enregistrer" : "Créer") { save() }
                        .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func fmt(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    private func load() {
        guard let course else {
            colorHex = Theme.coursePalette[abs((code + name).hashValue) % Theme.coursePalette.count]
            sectionCode = defaultSectionCode.isEmpty ? app.settings.sectionCode : defaultSectionCode
            selectedTermID = AcademicTerm.resolve(from: terms)?.id ?? terms.first?.id
            return
        }
        code = course.code
        name = course.name
        shortName = course.shortName
        credits = course.credits
        hasLectures = course.hasLectures
        lectureHours = course.weeklyLectureHours
        exerciseHours = course.weeklyExerciseHours
        autoSelfStudy = course.weeklySelfStudyHours == nil
        selfStudyHours = course.weeklySelfStudyHours ?? 0
        colorHex = course.colorHex
        sectionCode = course.sectionCode
        lecturer = course.lecturer
        link = course.moodleURLString
        isTracked = course.isTracked
        selectedTermID = course.term?.id ?? AcademicTerm.resolve(from: terms)?.id
    }

    /// Ce que donnerait la déduction ECTS, pour l'aide sous le champ.
    private var impliedSelfStudyHours: Double {
        let term = terms.first { $0.id == selectedTermID } ?? AcademicTerm.resolve(from: terms)
        let weeks = Double(max(term?.totalWeeks ?? 14, 1))
        let framed = (hasLectures ? lectureHours : 0) + exerciseHours
        return max(0, credits * app.settings.hoursPerCredit / weeks - framed)
    }

    private func save() {
        let trimmedCode = code.trimmingCharacters(in: .whitespaces).uppercased()
        let resolvedName = name.trimmingCharacters(in: .whitespaces)
        let term = terms.first { $0.id == selectedTermID } ?? AcademicTerm.resolve(from: terms)

        if let course {
            course.code = trimmedCode
            course.name = resolvedName.isEmpty ? trimmedCode : resolvedName
            course.shortName = shortName.trimmingCharacters(in: .whitespaces)
            course.credits = credits
            course.hasLectures = hasLectures
            course.weeklyLectureHours = hasLectures ? lectureHours : 0
            course.weeklyExerciseHours = exerciseHours
            course.weeklySelfStudyHours = autoSelfStudy ? nil : selfStudyHours
            course.colorHex = colorHex
            course.sectionCode = sectionCode
            course.lecturer = lecturer
            course.moodleURLString = link
            course.isTracked = isTracked
            if let term { course.term = term }
        } else {
            let created = Course(code: trimmedCode,
                                 name: resolvedName.isEmpty ? trimmedCode : resolvedName,
                                 shortName: shortName.trimmingCharacters(in: .whitespaces),
                                 credits: credits,
                                 colorHex: colorHex,
                                 term: term,
                                 weeklyLectureHours: hasLectures ? lectureHours : 0,
                                 weeklyExerciseHours: exerciseHours,
                                 weeklySelfStudyHours: autoSelfStudy ? nil : selfStudyHours,
                                 hasLectures: hasLectures,
                                 sectionCode: sectionCode,
                                 isTracked: isTracked,
                                 lecturer: lecturer,
                                 moodleURLString: link)
            context.insert(created)
        }

        try? context.save()
        Haptics.success()
        dismiss()
    }
}
