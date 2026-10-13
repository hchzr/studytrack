import SwiftUI
import SwiftData

/// L'accueil du bureau **en cours** : ce qu'il faut pendant un cours, et rien
/// d'autre.
///
/// - **L'horloge du cours** : ce qui reste, la pause (2 × 45 min à l'EPFL),
///   la suite de la journée et sa salle.
/// - **Repère** : un toucher quand on décroche. Pas de texte — les notes
///   restent dans GoodNotes ; le soir, l'enregistrement s'ouvre à la minute.
/// - **La semaine sur Moodle**, dépliée : diapositives et documents d'abord,
///   dossiers, liens, pages, enregistrements, devoirs — chacun s'ouvre dans
///   l'onglet Cours, sans navigateur.
/// - **Les sondages** (SpeakUp, Wooclap) si le cours en cite, **GoodNotes**
///   d'un toucher, **Ed** pour les questions du cours.
/// - **La théorie de la semaine** à cocher au fil du cours.
///
/// Le même écran sur le Mac (deux colonnes) et l'iPhone (une).
struct LectureDeskView: View {
    @Bindable var course: Course
    var klass: ScheduledClass?
    var next: ScheduledClass?
    var hub: SiteHub
    var compact = false
    /// Ouvre l'onglet Cours sur une source, une lecture.
    var openCourse: (SiteHub.Request) -> Void
    /// Ouvre une app permise (GoodNotes).
    var openApp: (_ bundleID: String, _ scheme: String) -> Void
    var openWeb: (URL, String) -> Void

    private var marks: LectureMarkStore { LectureMarkStore.shared }
    private var tint: Color { Carnet.tint(course.colorHex) }

    private var moodleID: Int? { MoodleCourseMatcher.linkedID(in: course.contentSources + [course.moodleURLString]) }
    private var page: MoodleCoursePage? { moodleID.flatMap { hub.moodlePages[$0] } }
    private var section: MoodleCoursePage.Section? { page?.currentSection() }

    var body: some View {
        ScrollView {
            if compact {
                VStack(alignment: .leading, spacing: 22) {
                    clock
                    markButton
                    tools
                    week
                    theory
                    earlierMarks
                }
                .padding(20)
            } else {
                HStack(alignment: .top, spacing: 36) {
                    VStack(alignment: .leading, spacing: 22) {
                        clock
                        markButton
                        tools
                        earlierMarks
                    }
                    .frame(width: 400)
                    VStack(alignment: .leading, spacing: 22) {
                        week
                        theory
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(36)
            }
        }
        .task(id: moodleID) {
            if let moodleID, hub.moodlePages[moodleID] == nil { await hub.loadMoodlePage(moodleID, title: course.name) }
        }
        .background {
            // ⌘R : un repère, sans lâcher le clavier.
            Button("") { addMark() }
                .keyboardShortcut("r", modifiers: [.command])
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    // MARK: L'horloge du cours

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Circle().fill(tint).frame(width: 8, height: 8)
                    Text(course.displayCode).font(.caption.weight(.semibold)).foregroundStyle(tint)
                    if let klass {
                        Text(klass.kindLabel).font(.caption).foregroundStyle(Carnet.inkSecondary)
                        if !klass.location.isEmpty {
                            Label(klass.location, systemImage: "mappin").font(.caption).foregroundStyle(Carnet.inkSecondary)
                        }
                    }
                }
                Text(course.name)
                    .font(Carnet.serif(compact ? .title2 : .title))
                    .foregroundStyle(Carnet.ink)
                    .lineLimit(2)
                if let klass {
                    Text(phaseLabel(klass, at: context.date))
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Carnet.ink)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Carnet.sheetRaised)
                            Capsule().fill(tint).frame(width: max(6, proxy.size.width * LectureClock.progress(of: klass.slot, at: context.date)))
                            if let pause = LectureClock.breakWindow(of: klass.slot) {
                                let total = klass.slot.end.timeIntervalSince(klass.slot.start)
                                Rectangle().fill(Carnet.ground.opacity(0.8))
                                    .frame(width: max(2, proxy.size.width * pause.duration / total))
                                    .offset(x: proxy.size.width * pause.start.timeIntervalSince(klass.slot.start) / total)
                            }
                        }
                    }
                    .frame(height: 6)
                    HStack {
                        Text(DateUtils.time.string(from: klass.slot.start))
                        Spacer()
                        Text(DateUtils.time.string(from: klass.slot.end))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Carnet.inkTertiary)
                } else {
                    Text("Pas de créneau à l'horaire maintenant.")
                        .font(.callout).foregroundStyle(Carnet.inkSecondary)
                }
                if let next {
                    Divider().overlay(Carnet.rule)
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Carnet.tint(next.colorHex)).frame(width: 3, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Ensuite · \(DateUtils.time.string(from: next.slot.start))")
                                .font(.caption2.weight(.semibold)).foregroundStyle(Carnet.inkSecondary)
                            Text([next.slot.courseCode, next.kindLabel, next.location.isEmpty ? nil : next.location]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.callout).foregroundStyle(Carnet.ink).lineLimit(1)
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Carnet.rule))
        }
    }

    private func phaseLabel(_ klass: ScheduledClass, at now: Date) -> String {
        switch LectureClock.phase(of: klass.slot, at: now) {
        case .before(let minutes):
            return String(localized: "Commence dans \(minutes) min")
        case .running:
            let left = Int((klass.slot.end.timeIntervalSince(now) / 60).rounded(.up))
            if let pause = LectureClock.breakWindow(of: klass.slot), now < pause.start {
                return String(localized: "Encore \(left) min · pause à \(DateUtils.time.string(from: pause.start))")
            }
            return String(localized: "Encore \(left) min")
        case .pause(let minutes):
            return String(localized: "Pause · reprise dans \(minutes) min")
        case .over:
            return String(localized: "Le cours est fini")
        }
    }

    // MARK: Repère

    private var classStart: Date? { klass?.slot.start }

    private var markButton: some View {
        let today = classStart.map { marks.of(courseID: course.id, classStart: $0) } ?? []
        return VStack(alignment: .leading, spacing: 8) {
            Button { addMark() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "bookmark.fill").font(.title3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Repère").font(.headline)
                        Text("Une minute à revoir dans l'enregistrement").font(.caption).opacity(0.75)
                    }
                    Spacer(minLength: 0)
                    if !today.isEmpty {
                        Text("\(today.count)").font(.headline.monospacedDigit())
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Carnet.ground.opacity(0.25), in: Capsule())
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(Carnet.ground)
                .background(tint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .disabled(classStart == nil)
            .accessibilityHint("Retient cet instant du cours")
            if !today.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(today) { mark in
                        Text(mark.offsetLabel)
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Carnet.sheetRaised, in: Capsule())
                            .foregroundStyle(Carnet.ink)
                            .contextMenu {
                                Button("Retirer", systemImage: "trash", role: .destructive) { marks.remove(mark) }
                            }
                    }
                }
            }
        }
    }

    private func addMark() {
        guard let classStart else { return }
        if marks.mark(courseID: course.id, classStart: classStart) { Haptics.success() } else { Haptics.tap() }
    }

    // MARK: Outils du cours

    @ViewBuilder
    private var tools: some View {
        let polls = pollLinks
        VStack(alignment: .leading, spacing: 8) {
            Kicker("Pendant le cours")
            toolRow("GoodNotes", detail: String(localized: "Tes notes"), icon: "pencil.and.scribble") {
                openApp("com.goodnotesapp.x", "goodnotes://")
            }
            ForEach(polls, id: \.url) { poll in
                toolRow(poll.title, detail: String(localized: "Sondage du cours"), icon: "chart.bar.doc.horizontal") {
                    openWeb(poll.url, poll.title)
                }
            }
            toolRow("Ed", detail: String(localized: "Les questions du cours"), icon: "bubble.left.and.text.bubble.right") {
                openCourse(SiteHub.Request(courseID: course.id, source: .ed, reading: nil))
            }
            toolRow(String(localized: "Tout le cours"), detail: "Moodle, Botafogo, Courseware", icon: "books.vertical") {
                openCourse(SiteHub.Request(courseID: course.id, source: moodleID != nil ? .moodle : .studytrack, reading: nil))
            }
        }
    }

    /// Les sondages cités par le cours (sa page Moodle, ses sources).
    private var pollLinks: [(title: String, url: URL)] {
        var addresses = course.contentSources
        if let page { addresses += page.sections.flatMap(\.activities).map(\.url) }
        var seen = Set<String>()
        return addresses.compactMap { address -> (String, URL)? in
            guard let url = URL(string: address), let host = url.host?.lowercased() else { return nil }
            let title: String
            if host.contains("speakup") { title = "SpeakUp" } else if host.contains("wooclap") { title = "Wooclap" } else { return nil }
            guard seen.insert(url.absoluteString).inserted else { return nil }
            return (title, url)
        }
    }

    private func toolRow(_ title: String, detail: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body.weight(.medium))
                    .frame(width: 36, height: 36)
                    .background(Carnet.sheetRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(Carnet.ink)
                    Text(detail).font(.caption).foregroundStyle(Carnet.inkSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Carnet.inkTertiary)
            }
            .padding(10)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Carnet.ink)
    }

    // MARK: La semaine sur Moodle

    @ViewBuilder
    private var week: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Cette semaine").font(Carnet.serif(.title2)).foregroundStyle(Carnet.ink)
                Spacer()
                if let section {
                    Button("Toute la section") {
                        openCourse(SiteHub.Request(courseID: course.id, source: .moodle, reading: .moodleSection(section.number)))
                    }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(tint)
                }
            }
            if let section {
                if !section.title.isEmpty {
                    Text(section.title).font(.callout).foregroundStyle(Carnet.inkSecondary)
                }
                let groups = Self.groups(of: section.activities)
                if groups.isEmpty {
                    Text("Rien de publié pour cette semaine.").font(.callout).foregroundStyle(Carnet.inkSecondary)
                }
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Kicker(group.title)
                        ForEach(group.items) { activity in
                            activityRow(activity)
                        }
                    }
                }
            } else if let moodleID, let error = hub.moodleError[moodleID] {
                HStack {
                    Text(error).font(.callout).foregroundStyle(Carnet.inkSecondary)
                    Button("Se connecter") { hub.signIn = .moodle }.buttonStyle(.paper)
                    Button("Réessayer") { Task { await hub.loadMoodlePage(moodleID, title: course.name) } }.buttonStyle(.paper)
                }
            } else if moodleID != nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Text("Ce cours n'a pas de page Moodle liée.").font(.callout).foregroundStyle(Carnet.inkSecondary)
            }
        }
    }

    /// Les activités d'une section, rangées pour le cours : ce qu'on ouvre en
    /// amphi d'abord (diapositives), le reste ensuite.
    static func groups(of activities: [MoodleCoursePage.Activity]) -> [(title: String, items: [MoodleCoursePage.Activity])] {
        let visible = activities.filter { $0.module != "label" && !$0.url.isEmpty }
        let videos = visible.filter(\.isVideo)
        let rest = visible.filter { !$0.isVideo }
        let order: [(String, (MoodleCoursePage.Activity) -> Bool)] = [
            (String(localized: "Diapositives et documents"), { $0.module == "resource" && !$0.isSeries }),
            (String(localized: "Dossiers"), { $0.module == "folder" }),
            (String(localized: "Séries"), { $0.isSeries && ["resource", "assign"].contains($0.module) }),
            (String(localized: "Pages et liens"), { ["page", "url", "book"].contains($0.module) }),
            (String(localized: "À rendre"), { $0.module == "assign" && !$0.isSeries }),
        ]
        var used = Set<Int>()
        var result: [(String, [MoodleCoursePage.Activity])] = []
        for (title, test) in order {
            let items = rest.filter { !used.contains($0.id) && test($0) }
            used.formUnion(items.map(\.id))
            if !items.isEmpty { result.append((title, items)) }
        }
        if !videos.isEmpty { result.append((String(localized: "Enregistrements"), videos)) }
        let others = rest.filter { !used.contains($0.id) }
        if !others.isEmpty { result.append((String(localized: "Autres"), others)) }
        return result
    }

    private func activityRow(_ activity: MoodleCoursePage.Activity) -> some View {
        Button {
            openCourse(SiteHub.Request(courseID: course.id, source: .moodle, reading: Self.reading(for: activity)))
        } label: {
            HStack(spacing: 10) {
                Image(systemName: MoodleCourseList.icon(activity))
                    .frame(width: 22)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(activity.name).foregroundStyle(Carnet.ink).lineLimit(2)
                    if let date = activity.dates.first {
                        Text(date).font(.caption).foregroundStyle(Carnet.inkSecondary)
                    }
                }
                Spacer(minLength: 0)
                if activity.completed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Carnet.correct)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static func reading(for activity: MoodleCoursePage.Activity) -> CoursePane.Reading {
        if activity.isVideo { return .video(title: activity.name, address: activity.url) }
        if activity.module == "resource" { return .pdf(title: activity.name, address: activity.url) }
        return .moodle(module: activity.module, id: activity.id, title: activity.name)
    }

    // MARK: La théorie de la semaine

    @ViewBuilder
    private var theory: some View {
        let items = course.sortedTheoryItems.filter { $0.plannedWeek == course.currentWeek }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Vu en cours").font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink)
                ForEach(items) { item in
                    TheoryTick(item: item, tint: tint)
                }
            }
        }
    }

    // MARK: Les repères d'avant

    @ViewBuilder
    private var earlierMarks: some View {
        let starts = LectureMarks.classes(of: course.id, in: marks.marks).filter { $0 != classStart }.prefix(3)
        if !starts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Kicker("Tes repères")
                ForEach(Array(starts), id: \.self) { start in
                    let list = marks.of(courseID: course.id, classStart: start)
                    let recording = recording(for: start)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(start.formatted(.dateTime.weekday(.wide).day().month()))
                            .font(.callout.weight(.medium)).foregroundStyle(Carnet.ink)
                        FlowLayout(spacing: 6) {
                            ForEach(list) { mark in
                                Button {
                                    guard let recording else { return }
                                    let address = URL(string: recording.url).map { LectureMarks.seekURL($0, offset: mark.offset).absoluteString } ?? recording.url
                                    openCourse(SiteHub.Request(courseID: course.id, source: .moodle,
                                                               reading: .video(title: recording.name, address: address)))
                                } label: {
                                    Label(mark.offsetLabel, systemImage: recording == nil ? "bookmark" : "play.fill")
                                        .font(.caption.monospacedDigit())
                                        .padding(.horizontal, 9).padding(.vertical, 4)
                                        .background(Carnet.sheetRaised, in: Capsule())
                                        .foregroundStyle(Carnet.ink)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("Retirer", systemImage: "trash", role: .destructive) { marks.remove(mark) }
                                }
                            }
                        }
                        if recording == nil {
                            Text("L'enregistrement n'est pas encore sur Moodle.").font(.caption).foregroundStyle(Carnet.inkTertiary)
                        }
                    }
                }
            }
        }
    }

    /// L'enregistrement d'un cours : la vidéo de la section de cette semaine-là.
    private func recording(for start: Date) -> MoodleCoursePage.Activity? {
        guard let page else { return nil }
        let year = Calendar.current.component(.year, from: start)
        let section = page.sections.first { MoodleCoursePage.range(of: $0.title, year: year)?.contains(start) == true } ?? page.currentSection()
        return section?.activities.last(where: \.isVideo)
    }
}

/// Une ligne de théorie à cocher pendant le cours.
private struct TheoryTick: View {
    @Bindable var item: TheoryItem
    var tint: Color

    var body: some View {
        Button {
            item.watchedAt = item.isWatched ? nil : Date()
            Haptics.tap()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.isWatched ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isWatched ? Carnet.correct : Carnet.inkTertiary)
                    .font(.title3)
                Text(item.numberAndTitle).foregroundStyle(Carnet.ink).lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// À la fin du cours : la suite, sans repasser par l'accueil.
struct LectureAfterClass: View {
    let course: Course?
    let markCount: Int
    var compact = false
    var startSeries: () -> Void
    var extend: () -> Void
    var finish: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.seal").font(.system(size: 44, weight: .light)).foregroundStyle(Carnet.correct)
            Text("Le cours est fini.").font(Carnet.serif(compact ? 40 : 56)).foregroundStyle(Carnet.ink)
                .multilineTextAlignment(.center)
            if markCount > 0 {
                // Les repères attendent l'enregistrement dans l'accueil du cours.
                Text("\(markCount) repère(s) t'attendent : ils ouvriront l'enregistrement à la bonne minute dès qu'il sera sur Moodle.")
                    .foregroundStyle(Carnet.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            VStack(spacing: 10) {
                if course?.sortedSeries.contains(where: { !$0.isComplete }) == true {
                    Button(action: startSeries) {
                        Label("Enchaîner sur la série", systemImage: "doc.text").frame(maxWidth: compact ? .infinity : 320)
                    }
                    .buttonStyle(InkButtonStyle(large: true))
                }
                HStack(spacing: 10) {
                    Button(action: extend) { Label("Encore 25 min", systemImage: "plus") }
                        .buttonStyle(PaperButtonStyle(large: true))
                    Button(action: finish) { Label("Terminer", systemImage: "checkmark") }
                        .buttonStyle(PaperButtonStyle(large: true))
                }
            }
        }
        .padding(compact ? 28 : 60)
    }
}
