import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// « Personnaliser » : ce qui est propre à l'école et à l'étudiant·e, réglé au
/// même endroit sur l'iPhone et le Mac. Tout a une valeur par défaut qui
/// reproduit l'app d'avant (l'EPFL, GoodNotes, les quatre étapes) : on ne vient
/// ici que pour changer quelque chose.
struct PersonalizeForm: View {
    @Query(sort: \Course.code) private var courses: [Course]

    var body: some View {
        Form {
            SchoolSection()
            NotesSection(courses: courses.filter(\.isTracked))
            SessionFlowSection()
            NotebookLMSection()
            LanguageSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - École

struct SchoolSection: View {
    @State private var school = Institution.current
    @State private var email = SchoolConnect.shared.email ?? ""

    var body: some View {
        Section {
            Picker("École", selection: Binding(get: { school.id }, set: { id in
                school = Institution.builtIn.first { $0.id == id } ?? (id == school.id ? school : .generic)
                save()
            })) {
                ForEach(Institution.builtIn) { Text($0.name).tag($0.id) }
                Text("Autre école").tag(Institution.generic.id)
                if !Institution.builtIn.contains(where: { $0.id == school.id }), school.id != Institution.generic.id {
                    Text(school.name).tag(school.id)
                }
            }
            TextField("Ton adresse de l'école", text: $email)
                .textContentTypeEmail()
                .onSubmit {
                    SchoolConnect.shared.email = email.isEmpty ? nil : email
                    if let found = Institution.detect(email: email) { school = found; save() }
                }
            if !Institution.builtIn.contains(where: { $0.id == school.id }) {
                TextField("Moodle (https://…)", text: Binding(get: { school.moodle?.base ?? "" }, set: { value in
                    school.moodle = value.isEmpty ? nil : .init(base: value.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")), oauthProviderID: nil)
                    save()
                }))
                TextField("Open edX (https://…)", text: Binding(get: { school.openEdX?.base ?? "" }, set: { value in
                    school.openEdX = value.isEmpty ? nil : .init(base: value.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
                                                                  loginBackend: nil, ssoHost: nil, ssoIdP: nil)
                    save()
                }))
                Toggle("Ed Discussion", isOn: Binding(get: { school.ed != nil }, set: { school.ed = $0 ? .init(region: "us") : nil; save() }))
                if let ed = school.ed {
                    Picker("Région d'Ed", selection: Binding(get: { ed.region }, set: { school.ed = .init(region: $0); save() })) {
                        Text("Europe").tag("eu")
                        Text("États-Unis").tag("us")
                        Text("Australie").tag("au")
                    }
                }
            }
        } header: {
            Text("École")
        } footer: {
            Text(school.id == "epfl" ? "Moodle, Courseware, MediaSpace et Ed se connectent tout seuls." : "Les sites de ton école.")
        }
    }

    private func save() {
        if school.id == Institution.generic.id, school.moodle != nil || school.openEdX != nil || school.ed != nil {
            school.id = "custom"
            school.name = "Mon école"
        }
        Institution.save(school)
        school = Institution.current
    }
}

// MARK: - Notes

struct NotesSection: View {
    let courses: [Course]
    @State private var choosing = false
    private var store: NotesStore { .shared }

    var body: some View {
        Section {
            LabeledContent("Dossier") {
                HStack {
                    Text(store.root.map { $0.lastPathComponent } ?? "introuvable")
                        .foregroundStyle(.secondary).lineLimit(1)
                    Button("Choisir…") { choosing = true }
                }
            }
            ForEach(store.notebooks, id: \.self) { notebook in
                Picker(notebook, selection: Binding(get: {
                    store.rules.notebooks[notebook] ?? store.course(forNotebook: notebook, among: courses)?.code ?? ""
                }, set: { code in
                    store.rules.notebooks[notebook] = code
                })) {
                    Text("Aucun cours").tag("")
                    ForEach(courses) { Text($0.displayCode).tag($0.code) }
                }
            }
            TextField("Mots d'une série", text: words(\.seriesWords))
            TextField("Mots d'une semaine", text: words(\.weekWords))
        } header: {
            Text("Mes notes")
        } footer: {
            Text("La sauvegarde de GoodNotes, Notability… Chaque cahier va à un cours.")
        }
        .task { await store.refresh() }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                store.choose(url)
                Task { await store.refresh(force: true) }
            }
        }
    }

    /// Une liste de mots, séparés par des virgules.
    private func words(_ path: WritableKeyPath<NotesLibrary.Rules, [String]>) -> Binding<String> {
        Binding(get: { store.rules[keyPath: path].joined(separator: ", ") }, set: { text in
            let list = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !list.isEmpty { store.rules[keyPath: path] = list }
        })
    }
}

// MARK: - Session

struct SessionFlowSection: View {
    @State private var flow = SessionFlow.load()

    var body: some View {
        Section {
            ForEach(SessionFlow.Step.allCases) { step in
                HStack {
                    Toggle(step.title, isOn: Binding(get: { flow.contains(step) }, set: { _ in flow.toggle(step); flow.save() }))
                    if flow.contains(step) {
                        Button { flow.move(step, by: -1); flow.save() } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless)
                            .disabled(flow.steps.first == step)
                        Button { flow.move(step, by: 1); flow.save() } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(flow.steps.last == step)
                    }
                }
            }
        } header: {
            Text("Ta session")
        } footer: {
            Text("Les étapes du bureau, sur le Mac et l'iPhone.")
        }
    }
}

// MARK: - Langue

/// NotebookLM : allumé, la fiche a un onglet « Écouter » (sources prêtes à déposer, podcast à
/// rapporter). Éteint par défaut : rien ne part de l'appareil, de toute façon — StudyTrack ne parle
/// jamais à Google, il écrit des fichiers et ouvre un lien.
struct NotebookLMSection: View {
    @AppStorage("notebooklm.enabled") private var enabled = false

    var body: some View {
        Section {
            Toggle("NotebookLM", isOn: $enabled)
        } footer: {
            Text("Ajoute l'onglet « Écouter » à la fiche : les sources prêtes pour NotebookLM, et le podcast à écouter ici. StudyTrack ne se connecte jamais à Google.")
        }
    }
}

struct LanguageSection: View {
    @State private var language = AppLanguage.current
    @State private var changed = false

    var body: some View {
        Section {
            Picker("Langue", selection: $language) {
                ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .onChange(of: language) { _, value in
                AppLanguage.choose(value)
                changed = true
            }
        } footer: {
            if changed { Text("Au prochain lancement de l'app.") }
        }
    }
}

extension View {
    @ViewBuilder
    func textContentTypeEmail() -> some View {
        #if os(iOS)
        textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
        #else
        textContentType(.emailAddress)
        #endif
    }
}
