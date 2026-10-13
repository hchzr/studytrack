import SwiftUI
import SwiftData

/// Le cours, dans le bureau, en natif : ce que StudyTrack en sait (semaine
/// par semaine, avec ce qui est vu et fait), le plan Moodle en direct (pages,
/// dossiers, devoirs, liens, annonces lus ici), Courseware (vidéos et textes)
/// et le site Botafogo lu comme un livre. PDF (PDFKit), autres fichiers
/// (Aperçu), vidéos MediaSpace (AVKit) : tout s'ouvre ici. Seuls GeoGebra et
/// les sites inconnus passent par l'onglet Web.
struct CoursePane: View {
    let course: Course?
    var desk: SiteHub
    var openWeb: (URL, String) -> Void
    /// Demander à Claude (le bureau du Mac ; l'app Claude sur l'iPhone).
    var ask: (String) -> Void = { _ in }
    /// L'iPhone : la liste, puis la lecture par-dessus (pas deux colonnes).
    var compact = false

    enum Source: String, CaseIterable, Identifiable {
        case studytrack, notes, moodle, courseware, botafogo, ed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .studytrack: return "Le cours"
            case .notes: return "Mes notes"
            case .moodle: return "Moodle"
            case .courseware: return "Courseware"
            case .botafogo: return "Botafogo"
            case .ed: return "Ed"
            }
        }
    }

    @State private var source: Source = .studytrack
    @Query private var allCourses: [Course]
    @State private var coursewareFailed = false
    @State private var composingEd = false
    @State private var edLessonsShown = false
    @State private var edCategory: String?
    @State private var edReload = 0
    /// Ce qu'on lit à droite.
    @State private var reading: Reading?
    @State private var book = BotafogoBook()

    enum Reading: Equatable {
        case pdf(title: String, address: String)
        case botafogo(title: String, url: String)
        case theory(UUID)
        case moodle(module: String, id: Int, title: String)
        case video(title: String, address: String)
        case file(title: String, address: String)
        case edx(EdXOutline.Unit)
        case edThread(id: Int, title: String)
        case moodleSection(Int)
        case edLesson(EdDiscussion.Lesson)
    }

    /// Le cours Ed de ce cours (par son code), une fois les cours Ed lus.
    private var edCourse: EdDiscussion.Course? {
        guard let course, let courses = desk.edCourses else { return nil }
        return EdDiscussion.match(code: course.code, in: courses)
    }

    private var moodleID: Int? {
        guard let course else { return nil }
        return MoodleCourseMatcher.linkedID(in: course.contentSources + [course.moodleURLString])
    }

    private var botafogoURL: URL? {
        course?.contentSources.compactMap(URL.init(string:)).first { ContentSource.detect(host: $0.host) == .botafogo }
    }

    /// Le MOOC Courseware du cours, s'il en cite un.
    private var coursewareKey: String? {
        guard let course else { return nil }
        return (course.contentSources + course.theoryItems.map(\.urlString)).lazy.compactMap(MoocReference.courseKey(in:)).first
    }

    private var sources: [Source] {
        Source.allCases.filter {
            $0 == .studytrack || ($0 == .notes && !notes.isEmpty) || ($0 == .moodle && moodleID != nil) || ($0 == .courseware && coursewareKey != nil)
                || ($0 == .botafogo && botafogoURL != nil)
                || ($0 == .ed && (edCourse != nil || desk.edNeedsLogin))
        }
    }

    var body: some View {
        if let course, compact {
            // L'iPhone : la même liste, la lecture poussée par-dessus.
            NavigationStack {
                sourceColumn(course)
                    .navigationTitle(course.displayCode)
                    .navigationBarTitleDisplayModeInline()
                    .navigationDestination(isPresented: Binding(get: { reading != nil }, set: { if !$0 { reading = nil } })) {
                        reader(course)
                            .background(Carnet.ground)
                    }
            }
            .task { await desk.loadEdCourses() }
            .onAppear { consumeRequest() }
            .onChange(of: desk.request) { _, _ in consumeRequest() }
            .task { await NotesStore.shared.refresh() }
        } else if let course {
            HStack(spacing: 0) {
                sourceColumn(course)
                .frame(width: 320)
                .clipped()
                #if DEBUG
                .onAppear {
                    if CommandLine.arguments.contains("-botafogo") { source = .botafogo }
                    if let index = CommandLine.arguments.firstIndex(of: "-courseSource"), index + 1 < CommandLine.arguments.count,
                       let chosen = Source(rawValue: CommandLine.arguments[index + 1]) { source = chosen }
                }
                .onChange(of: book.ready) { _, ready in
                    // `-botafogo` : ouvrir la première série du programme.
                    guard ready, CommandLine.arguments.contains("-botafogo"), case .ready(let weeks) = book.state else { return }
                    let node = weeks.flatMap { $0.children ?? [] }.first { $0.type == "series" && $0.url != nil }
                    if let node, let url = node.url { reading = .botafogo(title: node.displayName, url: url) }
                }
                #endif
                Rectangle().fill(Carnet.rule).frame(width: 1)
                reader(course)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // Les cours Ed, une fois : la source « Ed » n'apparaît que pour un
            // cours qui y est (ou pour se connecter).
            .task { await desk.loadEdCourses() }
            .onAppear { consumeRequest() }
            .onChange(of: desk.request) { _, _ in consumeRequest() }
            .task { await NotesStore.shared.refresh() }
        } else {
            ContentUnavailableView("Pas de cours", systemImage: "books.vertical",
                                   description: Text("Choisis-en un pour la session."))
        }
    }

    /// Les sources du cours (le cours, mes notes, Moodle…) et la liste choisie.
    @ViewBuilder
    private func sourceColumn(_ course: Course) -> some View {
        VStack(spacing: 0) {
            if sources.count > 1 {
                if compact {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Picker("Source", selection: $source) {
                            ForEach(sources) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .padding(.horizontal, 12)
                    }
                    .padding(.vertical, 8)
                } else {
                    // Les onglets quand ils tiennent ; sinon un menu (la colonne
                    // est étroite à côté de la série) — un contrôle segmenté du
                    // Mac ne rétrécit pas et débordait sur la barre latérale.
                    ViewThatFits(in: .horizontal) {
                        Picker("Source", selection: $source) {
                            ForEach(sources) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Picker("Source", selection: $source) {
                            ForEach(sources) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(12)
                }
            }
            switch source {
            case .studytrack: studyTrackList(course)
            case .moodle: moodleList(course)
            case .courseware: coursewareList
            case .botafogo: botafogoList
            case .ed: edList
            case .notes: notesList
            }
        }
    }

    // MARK: StudyTrack

    private func studyTrackList(_ course: Course) -> some View {
        let tint = Carnet.tint(course.colorHex)
        let weeks = Array(Set(course.sortedTheoryItems.map(\.plannedWeek) + course.sortedSeries.map(\.plannedWeek))).sorted {
            ($0 == 0 ? Int.max : $0) < ($1 == 0 ? Int.max : $1)
        }
        return ScrollViewReader { proxy in
            List {
                ForEach(weeks, id: \.self) { week in
                    Section {
                        ForEach(course.sortedTheoryItems.filter { $0.plannedWeek == week }) { item in
                            TheoryLine(item: item, tint: tint, selected: reading == .theory(item.id)) { open(item) }
                        }
                        ForEach(course.sortedSeries.filter { $0.plannedWeek == week && !$0.exercises.isEmpty }) { series in
                            Button {
                                if !series.urlString.isEmpty {
                                    reading = .pdf(title: series.title.isEmpty ? "Série \(series.seriesNumber)" : series.title, address: series.urlString)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "list.number").foregroundStyle(tint).frame(width: 18)
                                    Text(series.title.isEmpty ? "Série \(series.seriesNumber)" : series.title).foregroundStyle(Carnet.ink)
                                    Spacer()
                                    Text("\(series.doneCount)/\(series.requiredExercises.count)").font(.caption.monospacedDigit())
                                        .foregroundStyle(Carnet.inkSecondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text(week > 0 ? "Semaine \(week)" : "Documents").font(Carnet.serif(.headline)).foregroundStyle(Carnet.ink)
                            if week == course.currentWeek { Kicker("en cours", color: tint) }
                        }
                        .id(week)
                    }
                }
                if !course.documents.isEmpty {
                    Section("Documents") {
                        ForEach(course.documents) { document in
                            Button { openLink(document.url, title: document.title, kind: document.kind) } label: {
                                Label(document.title, systemImage: document.kind.icon).foregroundStyle(Carnet.ink)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .onAppear { proxy.scrollTo(course.currentWeek, anchor: .top) }
        }
    }

    private func open(_ item: TheoryItem) {
        reading = .theory(item.id)
    }

    /// Un lien du cours, ouvert en natif selon où il mène (`SiteRouter`) ;
    /// l'onglet Web seulement pour GeoGebra et les sites qu'on ne sait pas lire.
    private func openLink(_ address: String, title: String, kind: ContentLink.Kind? = nil) {
        guard let url = URL(string: address), url.scheme?.hasPrefix("http") == true else { return }
        if kind == .pdf || kind == .slides || kind == .notes || kind == .solution { reading = .pdf(title: title, address: address); return }
        switch SiteRouter.route(address) {
        case .pdf:
            reading = .pdf(title: title, address: address)
        case .file:
            reading = .file(title: title, address: address)
        case .moodle(let module, let id):
            reading = .moodle(module: module, id: id, title: title)
        case .mediaspace, .youtube, .video:
            reading = .video(title: title, address: address)
        case .courseware:
            source = .courseware
        case .botafogo:
            source = .botafogo
        case .geogebra, .web:
            if Self.isDocument(url) { reading = .pdf(title: title, address: address) } else { openWeb(url, title) }
        }
    }

    static func isDocument(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.hasSuffix(".pdf") || path.contains("/pluginfile.php/") || path.contains("/mod/resource/")
    }

    // MARK: Moodle

    @ViewBuilder
    private func moodleList(_ course: Course) -> some View {
        if let id = moodleID {
            if let page = desk.moodlePages[id] {
                MoodleCourseList(page: page, tint: Carnet.tint(course.colorHex),
                                 selectedSection: { if case .moodleSection(let n)? = reading { return n }; return nil }(),
                                 selectedActivity: { if case .moodle(_, let a, _)? = reading { return a }; return nil }(),
                                 openSection: { reading = .moodleSection($0.number) },
                                 openActivity: { openMoodle($0) })
                    .onAppear {
                        if !compact, reading == nil, let current = page.currentSection() { reading = .moodleSection(current.number) }
                    }
            } else if let error = desk.moodleError[id] {
                VStack(spacing: 12) {
                    Text(error).foregroundStyle(Carnet.inkSecondary).multilineTextAlignment(.center)
                    Button("Se connecter") { desk.signIn = .moodle }.buttonStyle(.ink)
                    Button("Réessayer") { loadMoodle(id, course: course) }.buttonStyle(.paper)
                }
                .padding(20)
                .frame(maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxHeight: .infinity)
                    .onAppear { loadMoodle(id, course: course) }
            }
        }
    }

    /// Une demande venue d'ailleurs (l'accueil « En cours ») : la source, la lecture.
    private func consumeRequest() {
        guard let request = desk.request, request.courseID == course?.id else { return }
        desk.request = nil
        source = request.source
        if let wanted = request.reading { reading = wanted }
    }

    private func loadMoodle(_ id: Int, course: Course) {
        Task { await desk.loadMoodlePage(id, title: course.name) }
    }

    /// Une activité de la page du cours, ouverte au bon endroit.
    private func openMoodle(_ activity: MoodleCoursePage.Activity) {
        switch activity.module {
        case "resource":
            reading = .pdf(title: activity.name, address: activity.url)
        case "lti" where activity.name.lowercased().contains("ed"):
            source = .ed
        default:
            reading = .moodle(module: activity.module, id: activity.id, title: activity.name)
        }
    }

    private func openActivity(_ activity: MoodleActivity) {
        if activity.module == "resource" {
            reading = .pdf(title: activity.name, address: activity.link)
        } else if let id = Int(activity.id) ?? URLComponents(string: activity.link)?.queryItems?.first(where: { $0.name == "id" })?.value.flatMap(Int.init) {
            reading = .moodle(module: activity.module, id: id, title: activity.name)
        } else {
            openLink(activity.link, title: activity.name)
        }
    }

    // MARK: Mes notes

    /// Tes cahiers de ce cours (GoodNotes → Google Drive…), par semaine.
    private var notes: [NotesLibrary.Document] {
        guard let course else { return [] }
        return NotesStore.shared.documents(for: course, among: allCourses)
    }

    private var notesList: some View {
        let documents = notes
        let weeks = Array(Set(documents.map { $0.week ?? 0 })).sorted { ($0 == 0 ? -1 : $0) > ($1 == 0 ? -1 : $1) }
        return List {
            ForEach(weeks, id: \.self) { week in
                Section {
                    ForEach(documents.filter { ($0.week ?? 0) == week }.sorted { $0.modified > $1.modified }) { document in
                        Button {
                            if let url = NotesStore.shared.url(document) { reading = .pdf(title: document.title, address: url.absoluteString) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: document.isSolution ? "checkmark.seal" : (document.seriesNumber != nil ? "list.number" : "pencil.and.scribble"))
                                    .foregroundStyle(Carnet.tint(course?.colorHex ?? "")).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(document.title).foregroundStyle(Carnet.ink).lineLimit(2)
                                    Text(document.modified.formatted(.relative(presentation: .named).locale(Locale(identifier: "fr_CH"))))
                                        .font(.caption2).foregroundStyle(Carnet.inkTertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(week > 0 ? "Semaine \(week)" : "Autres").font(Carnet.serif(.headline)).foregroundStyle(Carnet.ink)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    // MARK: Ed

    @ViewBuilder
    private var edList: some View {
        if let ed = edCourse {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    if !(desk.edLessons[ed.id] ?? []).isEmpty {
                        Picker("Ed", selection: $edLessonsShown) {
                            Text("Fils").tag(false)
                            Text("Leçons").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    Menu {
                        Button("Toutes") { edCategory = nil }
                        ForEach(Array(Set((desk.edThreads[ed.id] ?? []).compactMap(\.category))).sorted(), id: \.self) { name in
                            Button(name) { edCategory = name }
                        }
                    } label: {
                        Label(edCategory ?? "Toutes", systemImage: "line.3.horizontal.decrease")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    Spacer()
                    Button { composingEd = true } label: { Label("Question", systemImage: "square.and.pencil") }
                        .buttonStyle(.paper)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                if edLessonsShown, let lessons = desk.edLessons[ed.id] {
                    List(lessons) { lesson in
                        Button { reading = .edLesson(lesson) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lesson.title).foregroundStyle(Carnet.ink).lineLimit(2)
                                if let module = lesson.module { Text(module).font(.caption).foregroundStyle(Carnet.inkTertiary) }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                } else if let threads = desk.edThreads[ed.id] {
                    List {
                        ForEach(threads.filter { edCategory == nil || $0.category == edCategory }) { thread in
                            Button { reading = .edThread(id: thread.id, title: thread.title) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: thread.isPinned == true ? "pin.fill"
                                          : (thread.type == "announcement" ? "megaphone" : (thread.isAnswered == true ? "checkmark.bubble" : "bubble.left")))
                                        .foregroundStyle(Carnet.tint(course?.colorHex ?? "")).frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(thread.title).foregroundStyle(Carnet.ink).lineLimit(2)
                                        Text([thread.category, thread.replyCount.map { "\($0) rép." }].compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(Carnet.inkTertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground({ if case .edThread(let id, _)? = reading, id == thread.id { return Carnet.tint(course?.colorHex ?? "").opacity(0.12) }; return Color.clear }())
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                } else {
                    ProgressView().frame(maxHeight: .infinity)
                }
            }
            .task(id: "\(ed.id)|\(desk.signInRevision)|\(edReload)") {
                await SchoolConnect.shared.ensure(.ed)
                do { desk.edThreads[ed.id] = try await desk.ed.threads(course: ed.id) }
                catch HiddenSiteSession.SiteError.notSignedIn { desk.edNeedsLogin = true }
                catch {}
                if desk.edLessons[ed.id] == nil { desk.edLessons[ed.id] = (try? await desk.ed.lessons(course: ed.id)) ?? [] }
            }
            .sheet(isPresented: $composingEd) {
                EdComposeSheet(courseID: ed.id, desk: desk) { id in
                    edReload += 1
                    if let id { reading = .edThread(id: id, title: "Ta question") }
                }
            }
        } else {
            VStack(spacing: 12) {
                Text("Connecte-toi à Ed.").foregroundStyle(Carnet.inkSecondary)
                Button("Se connecter") { desk.signIn = .ed }.buttonStyle(.ink)
            }
            .frame(maxHeight: .infinity)
        }
    }

    // MARK: Courseware

    @ViewBuilder
    private var coursewareList: some View {
        if let key = coursewareKey {
            if let outline = desk.edxOutlines[key] {
                CoursewareList(outline: outline, tint: Carnet.tint(course?.colorHex ?? ""),
                               selected: { if case .edx(let unit)? = reading { return unit.id }; return nil }(),
                               open: { reading = .edx($0) })
                    .onAppear { if !compact, reading == nil, let resume = outline.resumeUnit { reading = .edx(resume) } }
            } else if coursewareFailed {
                VStack(spacing: 12) {
                    Text("Connecte-toi à Courseware.").foregroundStyle(Carnet.inkSecondary)
                    Button("Se connecter") { desk.signIn = .courseware }.buttonStyle(.ink)
                }
                .frame(maxHeight: .infinity)
                .onChange(of: desk.signInRevision) { _, _ in coursewareFailed = false }
            } else {
                ProgressView()
                    .frame(maxHeight: .infinity)
                    .task(id: desk.signInRevision) {
                        await SchoolConnect.shared.ensure(.courseware)
                        do { desk.edxOutlines[key] = try await desk.courseware.outline(of: key) } catch { coursewareFailed = true }
                    }
            }
        }
    }

    static func botafogoIcon(_ type: String) -> String {
        switch type {
        case "series": return "list.number"
        case "session": return "person.2"
        case "weekContent": return "calendar"
        default: return "book.pages"
        }
    }

    static func icon(for module: String) -> String {
        switch module {
        case "resource": return "doc.richtext"
        case "folder": return "folder"
        case "url": return "link"
        case "page": return "doc.text"
        case "assign": return "tray.and.arrow.up"
        case "forum": return "bubble.left.and.bubble.right"
        case "quiz": return "checklist"
        default: return "square.grid.2x2"
        }
    }

    // MARK: Botafogo

    @ViewBuilder
    private var botafogoList: some View {
        if let url = botafogoURL {
            switch book.state {
            case .ready(let weeks):
                List {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                        Section {
                            ForEach(Array((week.children ?? []).enumerated()), id: \.offset) { _, node in
                                if let address = node.url {
                                    Button { reading = .botafogo(title: node.displayName, url: address) } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: Self.botafogoIcon(node.type))
                                                .foregroundStyle(Carnet.tint(course?.colorHex ?? "")).frame(width: 18)
                                            MacMathText(node.displayName, size: 13).foregroundStyle(Carnet.ink).lineLimit(2)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } header: {
                            MacMathText(week.name ?? "Semaine", size: 14, design: .serif).foregroundStyle(Carnet.ink)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            case .failed(let message):
                VStack(spacing: 10) {
                    Text(message).foregroundStyle(Carnet.inkSecondary)
                    Button("Réessayer") { book.reset(); Task { await book.load(url) } }.buttonStyle(.paper)
                }
                .frame(maxHeight: .infinity)
            case .idle, .loading:
                ProgressView()
                    .frame(maxHeight: .infinity)
                    .task { await book.load(url) }
            }
        }
    }

    // MARK: Lecture

    @ViewBuilder
    private func reader(_ course: Course) -> some View {
        switch reading {
        case .pdf(let title, let address)?:
            VStack(spacing: 0) {
                readerHeader(title, address: address)
                switch desk.document(address) {
                case .ready(let file)?:
                    PDFPane(url: file)
                case .needsLogin?:
                    VStack(spacing: 10) {
                        Text("Connecte-toi à Moodle.").foregroundStyle(Carnet.inkSecondary)
                        HStack {
                            Button("Se connecter") { desk.signIn = .moodle }.buttonStyle(.ink)
                            Button("Réessayer") { desk.retry(address) }.buttonStyle(.paper)
                        }
                    }
                    .frame(maxHeight: .infinity)
                case .failed(let message)?:
                    VStack(spacing: 10) {
                        Text(message).foregroundStyle(Carnet.inkSecondary)
                        Button("Réessayer") { desk.retry(address) }.buttonStyle(.paper)
                    }
                    .frame(maxHeight: .infinity)
                case .loading?, nil:
                    ProgressView().frame(maxHeight: .infinity).onAppear { desk.loadPDF(address) }
                }
            }
            .id(address)
        case .botafogo(let title, let url)?:
            BotafogoReader(book: book, title: title, url: url, desk: desk, ask: ask, openWeb: openWeb)
                .id(url)
        case .moodle(let module, let id, let title)?:
            VStack(spacing: 0) {
                plainHeader(title)
                MoodleActivityReader(module: module, id: id, title: title, desk: desk,
                                     open: { openLink($0, title: $1) }, openWeb: openWeb)
            }
            .id("\(module)\(id)")
        case .video(let title, let address)?:
            VStack(spacing: 0) {
                plainHeader(title)
                ScrollView {
                    NativeVideo(title: title, address: address, desk: desk, openWeb: openWeb)
                        .padding(32)
                        .frame(maxWidth: 960)
                        .frame(maxWidth: .infinity)
                }
            }
            .id(address)
        case .file(let title, let address)?:
            VStack(spacing: 0) {
                plainHeader(title)
                FileReader(title: title, address: address, desk: desk)
            }
            .id(address)
        case .moodleSection(let number)?:
            if let id = moodleID, let section = desk.moodlePages[id]?.sections.first(where: { $0.number == number }) {
                MoodleSectionPage(section: section, tint: Carnet.tint(course.colorHex), desk: desk,
                                  openActivity: { openMoodle($0) }, openLink: { openLink($0, title: $1) }, openWeb: openWeb)
                    .id("section\(number)")
            }
        case .edLesson(let lesson)?:
            VStack(spacing: 0) {
                plainHeader(lesson.title)
                EdLessonReader(lesson: lesson, desk: desk, open: { openLink($0, title: $1) }, openWeb: openWeb)
            }
            .id("lesson\(lesson.id)")
        case .edThread(let id, let title)?:
            VStack(spacing: 0) {
                plainHeader(title)
                EdThreadReader(id: id, title: title, desk: desk, open: { openLink($0, title: $1) }, openWeb: openWeb)
            }
            .id("ed\(id)")
        case .edx(let unit)?:
            if let key = coursewareKey, let outline = desk.edxOutlines[key] {
                CoursewareUnitPage(outline: outline, unit: unit, tint: Carnet.tint(course.colorHex), desk: desk,
                                   go: { reading = .edx($0) }, open: { openLink($0, title: $1) }, openWeb: openWeb)
                    .id(unit.id)
            }
        case .theory(let id)?:
            if let item = course.theoryItems.first(where: { $0.id == id }) {
                TheoryDetail(item: item, tint: Carnet.tint(course.colorHex), openLink: { openLink($0, title: $1, kind: $2) })
            }
        case nil:
            ContentUnavailableView {
                Label(course.name, systemImage: "books.vertical")
            } description: {
                Text("Choisis à gauche.")
            }
        }
    }

    private func readerHeader(_ title: String, address: String) -> some View {
        HStack {
            Text(title).font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink).lineLimit(1)
            Spacer()
            Button { ask("J'ai une question sur ce document (« \(title) »).") } label: {
                Label("Claude", systemImage: "sparkle")
            }
            .buttonStyle(.paper)
        }
        .padding(12)
    }

    private func plainHeader(_ title: String) -> some View {
        HStack {
            Text(title).font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink).lineLimit(1)
            Spacer()
            Button { ask("J'ai une question sur « \(title) ».") } label: {
                Label("Claude", systemImage: "sparkle")
            }
            .buttonStyle(.paper)
        }
        .padding(12)
    }
}

private struct TheoryLine: View {
    @Bindable var item: TheoryItem
    let tint: Color
    let selected: Bool
    var open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                item.watchedAt = item.isWatched ? nil : Date()
            } label: {
                Image(systemName: item.isWatched ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isWatched ? tint : Carnet.inkTertiary)
            }
            .buttonStyle(.plain)
            Button(action: open) {
                HStack(spacing: 6) {
                    Image(systemName: item.kind.icon).foregroundStyle(tint).frame(width: 16)
                    Text(item.title.isEmpty ? item.kind.label : item.numberAndTitle)
                        .foregroundStyle(item.isWatched ? Carnet.inkSecondary : Carnet.ink)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .listRowBackground(selected ? tint.opacity(0.12) : Color.clear)
    }
}

/// Une vidéo, une section : ses liens, son résumé, le cocher.
private struct TheoryDetail: View {
    @Bindable var item: TheoryItem
    let tint: Color
    var openLink: (String, String, ContentLink.Kind?) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Kicker([item.kind.label, item.plannedWeek > 0 ? "semaine \(item.plannedWeek)" : nil].compactMap { $0 }.joined(separator: " · "), color: tint)
                Text(item.title.isEmpty ? item.kind.label : item.numberAndTitle).font(Carnet.serif(30)).foregroundStyle(Carnet.ink)
                Toggle("Vu", isOn: Binding(get: { item.isWatched }, set: { item.watchedAt = $0 ? (item.watchedAt ?? Date()) : nil }))
                    .studyCheckbox()
                if let summary = item.summaryText, !summary.isEmpty {
                    RichTextView(text: summary, size: 15)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if !item.urlString.isEmpty {
                        Button { openLink(item.urlString, item.title, nil) } label: {
                            Label("Ouvrir", systemImage: item.kind.icon)
                        }
                        .buttonStyle(.ink)
                    }
                    ForEach(item.links, id: \.url) { link in
                        Button { openLink(link.url, link.title, link.kind) } label: { Label(link.title, systemImage: link.kind.icon) }
                            .buttonStyle(.paper)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Botafogo

/// Le site Botafogo d'un cours, lu en natif : le programme (semaines, cours,
/// séries) et chaque document (`/api/content/node`).
@MainActor
@Observable
final class BotafogoBook {
    enum State {
        case idle, loading
        case ready([BotafogoNode])
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet { if case .ready = state { ready = true } }
    }
    private(set) var ready = false
    private(set) var root: URL?
    private var nodes: [String: [String: Any]] = [:]

    func reset() { state = .idle }

    func load(_ url: URL) async {
        if case .ready = state { return }
        state = .loading
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let html = String(decoding: data, as: UTF8.self)
            let root = BotafogoParser.siteRoot(html: html, pageURL: url)
            self.root = root
            if let program = await BotafogoClient.program(html: html, root: root, session: .shared), !program.isEmpty {
                state = .ready(program.filter { $0.type == "week" })
            } else {
                state = .failed("Programme introuvable.")
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Le corps d'un document du site.
    func body(of url: String) async -> [String: Any]? {
        if let cached = nodes[url] { return cached }
        guard let root else { return nil }
        let path = BotafogoProgram.contentPath(url).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
        guard let address = URL(string: root.absoluteString + "api/content/node?collection=content&path=" + path),
              let (data, _) = try? await URLSession.shared.data(from: address),
              let body = BotafogoDocument.body(fromNodeJSON: data) else { return nil }
        nodes[url] = body
        return body
    }

    func pageURL(_ url: String) -> URL? {
        root.flatMap { URL(string: BotafogoProgram.pageURL(root: $0, url: url)) }
    }

    func assetURL(_ source: String) -> URL? {
        if source.hasPrefix("http") { return URL(string: source) }
        guard let root else { return nil }
        // « /media/… » est relatif au **site** du cours (`…/analyse-1-GM/`) : les
        // images y sont aussi, les figures seulement là (vérifié).
        return URL(string: root.absoluteString + (source.hasPrefix("/") ? String(source.dropFirst()) : source))
    }
}

/// Un document Botafogo rendu nativement : titres, paragraphes et formules,
/// listes, figures, vidéos, environnements (théorème, définition…), et pour
/// une série chaque exercice avec son indication et sa solution repliées.
private struct BotafogoReader: View {
    var book: BotafogoBook
    let title: String
    let url: String
    var desk: SiteHub
    var ask: (String) -> Void = { _ in }
    var openWeb: (URL, String) -> Void

    @State private var blocks: [ReaderBlock]?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink).lineLimit(1)
                Spacer()
                Button { ask("J'ai une question sur « \(title) » (Botafogo).") } label: {
                    Label("Claude", systemImage: "sparkle")
                }
                .buttonStyle(.paper)
            }
            .padding(12)
            if let blocks {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(title).font(Carnet.serif(30)).foregroundStyle(Carnet.ink)
                        ReaderBlocks(blocks: blocks, book: book, desk: desk, openWeb: openWeb)
                    }
                    .padding(32)
                    .frame(maxWidth: 780, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .task {
            guard let body = await book.body(of: url) else { blocks = []; return }
            blocks = ReaderBlock.parse(body)
        }
    }
}

/// Un morceau de document Botafogo (Nuxt Content, « minimark »).
indirect enum ReaderBlock: Equatable {
    case text(String)
    case image(String)
    case video(id: String, title: String)
    /// Une figure interactive (JSXGraph) : son image fixe, si le site en a une.
    case figure(String)
    case box(title: String, [ReaderBlock])
    case folded(title: String, [ReaderBlock])

    /// L'arbre → des blocs. Le texte devient du Markdown léger, les formules
    /// gardent leur LaTeX entre `$…$` (`RichTextView` les met en forme).
    static func parse(_ node: [String: Any]) -> [ReaderBlock] {
        var blocks: [ReaderBlock] = []
        var paragraph = ""
        func flush() {
            let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.text(text)) }
            paragraph = ""
        }
        for child in children(node) {
            let tag = child["tagName"] as? String ?? ""
            let properties = child["properties"] as? [String: Any] ?? [:]
            if (child["type"] as? String) == "text" {
                paragraph += child["value"] as? String ?? ""
                continue
            }
            switch tag {
            case "h1", "h2", "h3", "h4":
                flush()
                let level = Int(tag.dropFirst()) ?? 2
                blocks.append(.text(String(repeating: "#", count: min(level + 1, 4)) + " " + BotafogoDocument.text(of: child).trimmingCharacters(in: .whitespaces)))
            case "p":
                flush()
                blocks.append(.text(inline(child)))
            case "ul", "ol":
                flush()
                let items = children(child).filter { ($0["tagName"] as? String) == "li" }
                let lines = items.enumerated().map { index, item in
                    (tag == "ol" ? "\(index + 1). " : "- ") + inline(item)
                }
                blocks.append(.text(lines.joined(separator: "\n")))
            case "katex-renderer":
                let content = BotafogoDocument.simplifyMath(properties["content"] as? String ?? "")
                if (properties["displayMode"] as? Bool) == true || (properties["display"] as? Bool) == true {
                    flush()
                    blocks.append(.text("$$" + content + "$$"))
                } else {
                    paragraph += "$" + content + "$"
                }
            case "img":
                flush()
                if let source = properties["src"] as? String { blocks.append(.image(source)) }
            case "videokaltura":
                flush()
                if let id = properties["entryId"] as? String {
                    blocks.append(.video(id: id, title: (properties["title"] as? String) ?? "Vidéo"))
                }
            case "solution", "indication", "proof", "preuve":
                flush()
                let title = ["solution": "Solution", "indication": "Indication", "proof": "Preuve", "preuve": "Preuve"][tag] ?? tag
                blocks.append(.folded(title: title, parse(content(child))))
            case "exercise":
                flush()
                blocks.append(.box(title: "Exercice", parse(content(child))))
            case "theorem", "theoreme", "definition", "proposition", "lemma", "lemme", "corollary", "corollaire", "remark", "remarque", "example", "exemple":
                flush()
                let names = ["theorem": "Théorème", "theoreme": "Théorème", "definition": "Définition", "proposition": "Proposition",
                             "lemma": "Lemme", "lemme": "Lemme", "corollary": "Corollaire", "corollaire": "Corollaire",
                             "remark": "Remarque", "remarque": "Remarque", "example": "Exemple", "exemple": "Exemple"]
                blocks.append(.box(title: (properties["title"] as? String).map { "\(names[tag] ?? tag) — \($0)" } ?? (names[tag] ?? tag),
                                   parse(content(child))))
            case "br":
                paragraph += "\n"
            case "b", "strong":
                paragraph += "**" + BotafogoDocument.text(of: child).trimmingCharacters(in: .whitespaces) + "** "
            case "jsxgraph":
                flush()
                if let script = properties["url"] as? String { blocks.append(.figure(script)) }
            default:
                // Un conteneur (div, template, multicols…) : on lit dedans.
                let inner = parse(content(child))
                if inner.isEmpty {
                    paragraph += BotafogoDocument.text(of: child)
                } else {
                    flush()
                    blocks += inner
                }
            }
        }
        flush()
        return blocks
    }

    private static func children(_ node: [String: Any]) -> [[String: Any]] {
        (node["children"] as? [[String: Any]]) ?? []
    }

    /// Le contenu d'un élément à gabarit (`template` → `content`), sinon l'élément.
    private static func content(_ element: [String: Any]) -> [String: Any] {
        if let content = element["content"] as? [String: Any] { return content }
        for child in children(element) where (child["tagName"] as? String) == "template" {
            if let content = child["content"] as? [String: Any] { return content }
        }
        return element
    }

    /// Une ligne : texte, gras, formules en ligne.
    private static func inline(_ node: [String: Any]) -> String {
        var text = ""
        for child in children(node) {
            if (child["type"] as? String) == "text" { text += child["value"] as? String ?? ""; continue }
            switch child["tagName"] as? String {
            case "b", "strong": text += "**" + inline(child).trimmingCharacters(in: .whitespaces) + "**"
            case "em", "i": text += "*" + inline(child).trimmingCharacters(in: .whitespaces) + "*"
            case "br": text += " "
            default: text += BotafogoDocument.text(of: child)
            }
        }
        return text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

private struct ReaderBlocks: View {
    let blocks: [ReaderBlock]
    var book: BotafogoBook
    var desk: SiteHub
    var openWeb: (URL, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
    }

    @ViewBuilder
    private func view(_ block: ReaderBlock) -> some View {
        switch block {
        case .text(let markdown):
            RichTextView(text: markdown, size: 15)
        case .image(let source):
            if let url = book.assetURL(source) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit().frame(maxHeight: 360)
                } placeholder: {
                    ProgressView()
                }
                .frame(maxWidth: .infinity)
            }
        case .video(let id, let title):
            NativeVideo(title: title, address: "https://\(Institution.current.videoHostName)/media/t/\(id)", desk: desk, openWeb: openWeb)
        case .figure(let script):
            // Botafogo publie l'image fixe de chaque figure à côté de son script
            // (`…/jsx_suite.js` → `…/jsx_suite.png`, vérifié) ; sinon, un repère.
            AsyncImage(url: book.assetURL(BotafogoFigure.imagePath(script: script))) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit().frame(maxHeight: 320)
                } else if case .failure = phase {
                    Label("Graphique interactif", systemImage: "chart.xyaxis.line")
                        .font(.callout).foregroundStyle(Carnet.inkSecondary)
                        .frame(maxWidth: .infinity).padding(18)
                        .background(Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity)
        case .box(let title, let inner):
            VStack(alignment: .leading, spacing: 8) {
                Kicker(title)
                ReaderBlocks(blocks: inner, book: book, desk: desk, openWeb: openWeb)
            }
            .paperSheet(padding: 16)
        case .folded(let title, let inner):
            DisclosureGroup {
                ReaderBlocks(blocks: inner, book: book, desk: desk, openWeb: openWeb).padding(.top, 6)
            } label: {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(Carnet.inkSecondary)
            }
            .padding(12)
            .background(Carnet.sheetRaised.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
