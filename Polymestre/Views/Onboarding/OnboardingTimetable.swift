import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// L'accueil › « Ton horaire » : une seule chose à faire, dite en étapes numérotées.
/// Trois chemins, du plus simple au plus rare : coller le lien de l'horaire, choisir un
/// fichier `.ics`, ou lire le calendrier de l'iPhone (si l'horaire y est déjà abonné).
/// L'horaire fait les heures d'amphi, l'agenda et le cours à suivre — facultatif.
struct TimetableStepScreen: View {
    var proceed: () -> Void

    @Environment(AppContainer.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var link = ""
    @State private var working = false
    @State private var result: String?
    @State private var failure: String?
    @State private var picking = false
    @State private var appeared = false

    private var isEPFL: Bool { Institution.current.id == Institution.epfl.id }
    private var done: Bool { result != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ton horaire")
                        .font(Carnet.serif(.largeTitle, weight: .semibold))
                        .foregroundStyle(Carnet.ink)
                    Text("Pour l'agenda et tes heures d'amphi. Facultatif.")
                        .font(.subheadline)
                        .foregroundStyle(Carnet.inkSecondary)
                }
                .rise(appeared, delay: 0.05)

                VStack(alignment: .leading, spacing: 14) {
                    step(1, isEPFL ? "Ouvre ton horaire sur IS-Academia." : "Ouvre ton horaire sur le site de ton école.") {
                        if isEPFL {
                            Button("Ouvrir IS-Academia") { openURL(URL(string: "https://isa.epfl.ch/")!) }
                                .buttonStyle(.carnetSecondary)
                        }
                    }
                    step(2, "Copie le lien d'export « iCal » (.ics) de l'horaire.") { EmptyView() }
                    step(3, "Colle-le ici.") {
                        HStack {
                            TextField("https://…", text: $link)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                if let pasted = UIPasteboard.general.string { link = pasted }
                            } label: { Image(systemName: "doc.on.clipboard") }
                                .accessibilityLabel("Coller")
                        }
                        Button {
                            Task { await importLink() }
                        } label: {
                            if working { ProgressView() } else { Text("Importer") }
                        }
                        .buttonStyle(.carnetPrimary)
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || working)
                    }
                }
                .padding(16)
                .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .rise(appeared, delay: 0.12)

                if let result {
                    Label(result, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Carnet.correct)
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Carnet.review)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Autrement").font(.footnote.weight(.semibold)).foregroundStyle(Carnet.inkSecondary)
                    Button { picking = true } label: {
                        Label("Choisir un fichier .ics", systemImage: "doc")
                    }
                    Button {
                        Task {
                            if await app.calendar.requestAccess() {
                                result = String(localized: "Calendrier de l'iPhone relié : l'horaire qui y est abonné sera lu.")
                                failure = nil
                                Haptics.success()
                            }
                        }
                    } label: {
                        Label("Lire le calendrier de l'iPhone", systemImage: "calendar")
                    }
                }
                .font(.subheadline.weight(.medium))
                .tint(Carnet.ink)
                .rise(appeared, delay: 0.2)
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 110)
            .frame(maxWidth: Layout.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom) {
            Button(action: proceed) {
                Label(done ? "Continuer" : "Plus tard", systemImage: "arrow.right")
            }
            .buttonStyle(.carnetPrimaryWide)
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.calendarEvent, .plainText]) { picked in
            guard case .success(let url) = picked else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                failure = String(localized: "Ce fichier ne se lit pas.")
                return
            }
            apply(text)
        }
        .onAppear {
            link = app.settings.timetableURLString
            appeared = true
        }
    }

    private func step<Content: View>(_ number: Int, _ text: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote.weight(.bold).monospacedDigit())
                .foregroundStyle(Carnet.ground)
                .frame(width: 22, height: 22)
                .background(Carnet.ink, in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(text).font(.subheadline).foregroundStyle(Carnet.ink)
                    .fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    private func importLink() async {
        working = true
        defer { working = false }
        do {
            let text = try await TimetableImport.fetch(urlString: link)
            app.settings.timetableURLString = link.trimmingCharacters(in: .whitespacesAndNewlines)
            apply(text)
        } catch {
            failure = String(localized: "Ce lien ne donne pas d'horaire. Vérifie que c'est bien le lien d'export iCal (.ics), pas celui de la page.")
            result = nil
            Haptics.error()
        }
    }

    private func apply(_ text: String) {
        let imported = TimetableImport.import(text, into: context, sectionCode: app.settings.sectionCode)
        if imported.eventsCreated == 0 && imported.eventsSkipped == 0 {
            failure = String(localized: "Aucune séance trouvée dans cet horaire.")
            result = nil
            Haptics.error()
        } else {
            result = imported.message
            failure = nil
            Haptics.success()
        }
    }
}
