import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Réglages › Général › « Horaire » : le lien d'export iCal de l'horaire, en étapes numérotées
/// (les mêmes que l'accueil de l'iPhone et Windows) ; un fichier `.ics` marche aussi.
struct TimetableSettingsSection: View {
    @Bindable var settings: SettingsStore
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var working = false
    @State private var note: String?
    @State private var picking = false

    private var isEPFL: Bool { Institution.current.id == Institution.epfl.id }

    var body: some View {
        Section {
            HStack {
                Text(isEPFL ? "1. Ouvre ton horaire sur IS-Academia." : "1. Ouvre ton horaire sur le site de ton école.")
                Spacer()
                if isEPFL { Button("Ouvrir IS-Academia") { openURL(URL(string: "https://isa.epfl.ch/")!) } }
            }
            Text("2. Copie le lien d'export « iCal » (.ics) de l'horaire.")
            HStack {
                TextField("3. Colle-le ici", text: $settings.timetableURLString, prompt: Text("https://…"))
                    .onSubmit { Task { await importLink() } }
                Button(working ? "Lecture…" : "Importer") { Task { await importLink() } }
                    .disabled(working || settings.timetableURLString.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Fichier .ics…") { picking = true }
            }
            if let note { Text(note).font(.caption).foregroundStyle(Carnet.inkSecondary) }
        } header: {
            Text("Horaire")
        } footer: {
            Text("Les cours, les séances d'exercices et leurs salles arrivent seuls.")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.calendarEvent, .plainText]) { picked in
            guard case .success(let url) = picked else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            if let text = try? String(contentsOf: url, encoding: .utf8) { apply(text) } else { note = String(localized: "Ce fichier ne se lit pas.") }
        }
    }

    private func importLink() async {
        working = true
        defer { working = false }
        do {
            apply(try await TimetableImport.fetch(urlString: settings.timetableURLString.trimmingCharacters(in: .whitespacesAndNewlines)))
        } catch {
            note = String(localized: "Ce lien ne donne pas d'horaire : il faut le lien d'export iCal (.ics), pas celui de la page.")
        }
    }

    private func apply(_ text: String) {
        let result = TimetableImport.import(text, into: context, sectionCode: settings.sectionCode)
        note = result.eventsCreated == 0 && result.eventsSkipped == 0 ? String(localized: "Aucune séance trouvée dans cet horaire.") : result.message
    }
}
