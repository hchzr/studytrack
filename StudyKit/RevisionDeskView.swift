import SwiftUI
import SwiftData

/// L'accueil du bureau **avant un examen** : par quoi commencer.
///
/// - **L'examen** : quand, où, combien il pèse — le compte à rebours.
/// - **Les annales**, dans l'ordre où les travailler (`RevisionFocus`) :
///   jamais faites d'abord, puis celles qu'on ne sait pas ; le sujet et le
///   corrigé s'ouvrent dans l'onglet Cours.
/// - **Les exercices à refaire** : un toucher, le chrono passe dessus.
/// - **La théorie pas encore vue**, semaine par semaine jusqu'à aujourd'hui.
struct RevisionDeskView: View {
    let course: Course
    var compact = false
    var openCourse: (SiteHub.Request) -> Void
    /// Passe le chrono sur un exercice (sans le couper).
    var work: (Exercise) -> Void

    private var tint: Color { Carnet.tint(course.colorHex) }

    /// Une section seule, pour la poser comme une carte du bureau (Mac) ; sans elle, la
    /// page entière (l'iPhone la garde en colonne).
    enum Part { case exam, sheet, past, redo, theory }
    var only: Part?

    var body: some View {
        if let only {
            part(only)
        } else {
            full
        }
    }

    @ViewBuilder
    private func part(_ part: Part) -> some View {
        switch part {
        case .exam: exam
        case .sheet: sheet
        case .past: pastExams
        case .redo: redo
        case .theory: theory
        }
    }

    private var full: some View {
        ScrollView {
            if compact {
                VStack(alignment: .leading, spacing: 22) {
                    exam
                    sheet
                    pastExams
                    redo
                    theory
                }
                .padding(20)
            } else {
                HStack(alignment: .top, spacing: 36) {
                    VStack(alignment: .leading, spacing: 22) {
                        exam
                        sheet
                        redo
                    }
                    .frame(width: 400)
                    VStack(alignment: .leading, spacing: 22) {
                        pastExams
                        theory
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(36)
            }
        }
    }

    // MARK: La fiche

    /// La fiche de révision du cours : tout ce qu'il faut savoir, sur une page.
    private var sheet: some View {
        let ready = course.revisionSheet
        return Button {
            openCourse(.init(courseID: course.id, source: .sheet, reading: nil))
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "doc.text.magnifyingglass").font(.title2).foregroundStyle(tint).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fiche de révision").font(.headline).foregroundStyle(Carnet.ink)
                    Text(ready.map { "\($0.entries.count) entrées : définitions, théorèmes, méthodes, pièges" }
                         ?? String(localized: "Tout le cours sur une page — à faire une fois"))
                        .font(.caption).foregroundStyle(Carnet.inkSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Carnet.inkTertiary)
            }
            .padding(14)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Carnet.rule))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: L'examen

    @ViewBuilder
    private var exam: some View {
        if let next = course.nextExam {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(tint).frame(width: 8, height: 8)
                    Text(course.displayCode).font(.caption.weight(.semibold)).foregroundStyle(tint)
                    if let weight = next.weightLabel {
                        Text(weight).font(.caption).foregroundStyle(Carnet.inkSecondary)
                    }
                }
                Text(next.title.isEmpty ? next.kind.label : next.title)
                    .font(Carnet.serif(compact ? .title2 : .title)).foregroundStyle(Carnet.ink)
                Text(countdown(next.daysUntil))
                    .font(.title3.weight(.medium)).foregroundStyle(next.daysUntil <= 3 ? Carnet.wrong : Carnet.ink)
                Text([next.date.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()),
                      next.location.isEmpty ? nil : next.location].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout).foregroundStyle(Carnet.inkSecondary)
                progress
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Carnet.rule))
        }
    }

    private func countdown(_ days: Int) -> String {
        switch days {
        case 0: return String(localized: "Aujourd'hui")
        case 1: return String(localized: "Demain")
        default: return String(localized: "Dans \(days) jours")
        }
    }

    /// Où on en est : annales faites, théorie vue, exercices à refaire.
    private var progress: some View {
        let past = course.pastExams
        let theoryItems = course.sortedTheoryItems.filter { $0.plannedWeek <= course.currentWeek }
        return HStack(spacing: 18) {
            stat("\(past.filter { $0.workedAt != nil }.count)/\(past.count)", String(localized: "annales"))
            stat("\(theoryItems.filter(\.isWatched).count)/\(theoryItems.count)", String(localized: "théorie vue"))
            stat("\(redoItems.count)", String(localized: "à refaire"))
        }
        .padding(.top, 4)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title3.monospacedDigit().weight(.semibold)).foregroundStyle(Carnet.ink)
            Text(label).font(.caption).foregroundStyle(Carnet.inkSecondary)
        }
    }

    // MARK: Annales

    @ViewBuilder
    private var pastExams: some View {
        let items = course.pastExams
        VStack(alignment: .leading, spacing: 8) {
            Text("Annales").font(Carnet.serif(.title2)).foregroundStyle(Carnet.ink)
            if items.isEmpty {
                Text("Pas d'annale pour ce cours. Ajoute-les depuis la page du cours.")
                    .font(.callout).foregroundStyle(Carnet.inkSecondary)
            } else {
                let order = RevisionFocus.pastExamOrder(items.map { ($0.id, $0.year, $0.workedAt != nil, $0.confidence) })
                ForEach(order.compactMap { id in items.first { $0.id == id } }) { item in
                    pastExamRow(item)
                }
            }
        }
    }

    private func pastExamRow(_ item: PastExam) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.workedAt == nil ? "circle" : (item.confidence?.icon ?? "circle.fill"))
                .foregroundStyle(item.workedAt == nil ? Carnet.inkTertiary : (item.confidence?.color ?? Carnet.inkSecondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).foregroundStyle(Carnet.ink).lineLimit(1)
                Text(item.workedAt.map { String(localized: "Fait le \($0.formatted(.dateTime.day().month()))") } ?? String(localized: "Pas encore fait"))
                    .font(.caption).foregroundStyle(Carnet.inkSecondary)
            }
            Spacer(minLength: 0)
            if !item.urlString.isEmpty {
                // Question par question, le corrigé de chacune à côté.
                Button("Travailler") {
                    openCourse(SiteHub.Request(courseID: course.id, source: .studytrack, reading: .pastExam(item.id)))
                }
                .buttonStyle(.ink)
                Button("Sujet") { openDocument(item.title, item.urlString) }.buttonStyle(.paper)
            }
            if !item.solutionURLString.isEmpty {
                Button("Corrigé") { openDocument(String(localized: "Corrigé · \(item.title)"), item.solutionURLString) }.buttonStyle(.paper)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func openDocument(_ title: String, _ address: String) {
        openCourse(SiteHub.Request(courseID: course.id, source: .studytrack, reading: .pdf(title: title, address: address)))
    }

    // MARK: À refaire

    private var redoItems: [Exercise] {
        course.sortedSeries.flatMap(\.sortedExercises).filter(\.redoRequired)
    }

    /// La file de reprise du cours, ce qui est dû d'abord.
    private var queue: [Exercise] { SeriesReview.redoQueue([course]) }

    @ViewBuilder
    private var redo: some View {
        let queued = queue
        let items = redoItems.filter { !$0.isQueuedForRedo }
        let mistakes = course.allExercises.flatMap(\.mistakes)
        if !queued.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Kicker("File de reprise")
                    Spacer()
                    let due = queued.filter { ($0.redoDueAt ?? .distantFuture) <= Date() }.count
                    Text(due == 0 ? "rien de dû aujourd'hui" : "\(due) à refaire aujourd'hui · sur papier, sans notes")
                        .font(.caption).foregroundStyle(due == 0 ? Carnet.inkTertiary : Carnet.review)
                }
                ForEach(queued.prefix(6)) { exercise in
                    Button { work(exercise) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.counterclockwise.circle.fill")
                                .foregroundStyle((exercise.redoDueAt ?? .distantFuture) <= Date() ? Carnet.review : Carnet.inkTertiary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(exercise.displayNumber).foregroundStyle(Carnet.ink)
                                if !exercise.redoWhy.isEmpty {
                                    MacMathText(exercise.redoWhy, size: 12).foregroundStyle(Carnet.inkSecondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            Text(exercise.redoDueAt.map { $0 <= Date() ? "aujourd'hui" : $0.formatted(.dateTime.day().month(.abbreviated)) } ?? "avant l'examen")
                                .font(.caption).foregroundStyle(Carnet.inkSecondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if !mistakes.isEmpty {
            // Le carnet d'erreurs du cours : ce qui revient le plus.
            let counts = Dictionary(grouping: mistakes, by: \.kind).mapValues(\.count).sorted { $0.value > $1.value }
            VStack(alignment: .leading, spacing: 8) {
                Kicker("Carnet d'erreurs · \(mistakes.count)")
                FlowLayout(spacing: 6) {
                    ForEach(counts, id: \.key) { kind, count in
                        Label("\(kind.label) · \(count)", systemImage: kind.icon)
                            .font(.caption)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Carnet.sheet, in: Capsule())
                            .foregroundStyle(Carnet.inkSecondary)
                    }
                }
                ForEach(mistakes.sorted { $0.createdAt > $1.createdAt }.prefix(3)) { mistake in
                    HStack(alignment: .top, spacing: 8) {
                        Text(mistake.exercise?.exerciseNumber ?? "").font(.caption.monospacedDigit()).foregroundStyle(Carnet.inkTertiary).frame(width: 36, alignment: .leading)
                        MacMathText(mistake.summary, size: 13).foregroundStyle(Carnet.ink).lineLimit(2)
                    }
                }
            }
        }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Kicker(queued.isEmpty ? "À refaire" : "Aussi à refaire")
                ForEach(items.prefix(8)) { exercise in
                    Button { work(exercise) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.counterclockwise").foregroundStyle(tint).frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(exercise.displayNumber).foregroundStyle(Carnet.ink)
                                if let series = exercise.series {
                                    Text(series.title.isEmpty ? String(localized: "Série \(series.seriesNumber)") : series.title)
                                        .font(.caption).foregroundStyle(Carnet.inkSecondary)
                                }
                            }
                            Spacer(minLength: 0)
                            Text("Travailler").font(.caption).foregroundStyle(Carnet.inkSecondary)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Théorie

    @ViewBuilder
    private var theory: some View {
        let unseen = course.sortedTheoryItems.filter { $0.plannedWeek <= course.currentWeek && !$0.isWatched }
        if !unseen.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Théorie pas encore vue").font(Carnet.serif(.title3)).foregroundStyle(Carnet.ink)
                ForEach(unseen.prefix(12)) { item in
                    Button {
                        openCourse(SiteHub.Request(courseID: course.id, source: .studytrack, reading: .theory(item.id)))
                    } label: {
                        HStack(spacing: 10) {
                            Text("S\(item.plannedWeek)").font(.caption.monospacedDigit()).foregroundStyle(Carnet.inkTertiary)
                                .frame(width: 30, alignment: .leading)
                            Text(item.numberAndTitle).foregroundStyle(Carnet.ink).lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Carnet.inkTertiary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
