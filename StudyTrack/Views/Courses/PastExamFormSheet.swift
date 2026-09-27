import SwiftUI
import SwiftData

/// Saisie d'une annale : un sujet d'examen passé, son lien, et où on en est.
struct PastExamFormSheet: View {
    let course: Course
    /// `nil` = création.
    var exam: PastExam?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context

    @State private var title = ""
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var kind: ExamKind = .exam
    @State private var urlString = ""
    @State private var solutionURLString = ""
    @State private var isWorked = false
    @State private var workedAt = Date()
    @State private var confidence: ConfidenceLevel?
    @State private var notes = ""
    @State private var showingDelete = false

    private var isEditing: Bool { exam != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sujet") {
                    TextField("Intitulé (ex : Examen final 2024)", text: $title)
                    Stepper("Année : \(year)", value: $year, in: 2000...2100)
                    Picker("Type", selection: $kind) {
                        ForEach(ExamKind.allCases) { value in
                            Label(value.label, systemImage: value.icon).tag(value)
                        }
                    }
                    TextField("Lien du sujet (PDF, Moodle…)", text: $urlString)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("Lien du corrigé (optionnel)", text: $solutionURLString)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }

                Section {
                    Toggle("Travaillé", isOn: $isWorked)
                    if isWorked {
                        DatePicker("Le", selection: $workedAt, displayedComponents: .date)
                        Picker("Sureté", selection: $confidence) {
                            Text("Non précisée").tag(ConfidenceLevel?.none)
                            ForEach(ConfidenceLevel.allCases, id: \.self) { level in
                                Text(level.label).tag(ConfidenceLevel?.some(level))
                            }
                        }
                    }
                } header: {
                    Text("Où j'en suis")
                } footer: {
                    Text("Pas de note : l'app suit le travail, pas les résultats. La sureté suffit à savoir quoi reprendre.")
                }

                Section("Notes") {
                    TextField("Ce qui est tombé, ce qui a manqué…", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            showingDelete = true
                        } label: {
                            Label("Supprimer cette annale", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Modifier l'annale" : "Nouvelle annale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Enregistrer" : "Ajouter") { save() }
                }
            }
            .confirmationDialog("Supprimer cette annale ?",
                                isPresented: $showingDelete,
                                titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) { delete() }
                Button("Annuler", role: .cancel) {}
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard let exam else { return }
        title = exam.title
        year = exam.year
        kind = exam.kind
        urlString = exam.urlString
        solutionURLString = exam.solutionURLString
        isWorked = exam.isWorked
        workedAt = exam.workedAt ?? Date()
        confidence = exam.confidence
        notes = exam.notes
    }

    private func save() {
        let resolved = title.trimmingCharacters(in: .whitespaces)
        let confidenceValue = isWorked ? confidence : nil
        let workedDate = isWorked ? workedAt : nil

        if let exam {
            exam.title = resolved.isEmpty ? "\(kind.label) \(year)" : resolved
            exam.year = year
            exam.kind = kind
            exam.urlString = urlString.trimmingCharacters(in: .whitespaces)
            exam.solutionURLString = solutionURLString.trimmingCharacters(in: .whitespaces)
            exam.workedAt = workedDate
            exam.confidence = confidenceValue
            exam.notes = notes
        } else {
            let created = PastExam(course: course,
                                   title: resolved,
                                   year: year,
                                   kind: kind,
                                   urlString: urlString.trimmingCharacters(in: .whitespaces),
                                   solutionURLString: solutionURLString.trimmingCharacters(in: .whitespaces),
                                   confidence: confidenceValue,
                                   workedAt: workedDate,
                                   notes: notes)
            context.insert(created)
        }
        try? context.save()
        Haptics.success()
        dismiss()
    }

    private func delete() {
        guard let exam else { return }
        context.delete(exam)
        try? context.save()
        Haptics.removed()
        dismiss()
    }
}
