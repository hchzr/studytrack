import SwiftUI
import SwiftData

/// « Moi » : qui, la semaine en trois chiffres, le bilan et les réglages.
/// Une feuille ouverte par l'avatar d'« Aujourd'hui ».
///
/// C'était une feuille « Profil & réglages » ouverte par l'avatar : un sommaire
/// de réglages d'abord, le bilan à un toucher de plus. On ouvre surtout cet
/// onglet pour **voir où on en est** — le bilan vient donc en premier ; les
/// liens (Moodle, calendrier, assistant) disent ensuite s'ils marchent ; les
/// réglages, inchangés, sont au bout d'une ligne.
struct MeView: View {
    var onClose: (() -> Void)? = nil
    @Environment(AppContainer.self) private var app
    @Query(sort: \Course.code) private var courses: [Course]
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]
    @Query(sort: \LinkedTask.dueDate) private var tasks: [LinkedTask]
    /// `-settings` (captures) : ouvre les réglages à l'arrivée.
    @State private var debugSettings = false

    var body: some View {
        NavigationStack {
            CarnetScroll {
                identity
                weekStats
                settingsLinks
            }
            .navigationTitle("Moi")
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: onClose) { Image(systemName: "xmark") }
                            .accessibilityLabel("Fermer")
                    }
                }
            }
            .navigationDestination(isPresented: $debugSettings) { ProfileView(isEmbedded: true) }
            .onAppear {
                #if DEBUG
                if CommandLine.arguments.contains("-settings") { debugSettings = true }
                #endif
            }
        }
    }

    // MARK: Qui

    private var identity: some View {
        let name = app.settings.displayName.trimmingCharacters(in: .whitespaces)
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
        return NavigationLink {
            ProfileView(isEmbedded: true)
        } label: {
            HStack(spacing: 14) {
                Text(initials.isEmpty ? "?" : initials)
                    .font(Carnet.serif(.title3, weight: .semibold))
                    .foregroundStyle(Carnet.ground)
                    .frame(width: 52, height: 52)
                    .background(Carnet.ink, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? "Ton prénom" : name)
                        .font(Carnet.serif(.title3))
                        .foregroundStyle(name.isEmpty ? Carnet.inkTertiary : Carnet.ink)
                    Text(app.settings.section?.name ?? "Section non renseignée")
                        .font(.subheadline)
                        .foregroundStyle(Carnet.inkSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Carnet.inkTertiary)
            }
            .padding(14)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Bilan

    private var tracked: [Course] { courses.filter(\.isTracked) }

    private var weekSessions: [StudySession] {
        let start = DateUtils.startOfWeek(Date())
        return sessions.filter { $0.startedAt >= start }
    }

    private var weekStats: some View {
        let seconds = weekSessions.reduce(0) { $0 + $1.durationSeconds }
        let progress = tracked.map { ProgressEngine.progress(for: $0) }
        let done = progress.reduce(0) { $0 + $1.watchedCount + $1.doneCount }
        let total = progress.reduce(0) { $0 + $1.videoCount + $1.exerciseCount }
        let corrected = tracked.flatMap(\.allExercises).filter { $0.correctness != nil }
        let right = corrected.filter { $0.correctness == .correct }.count
        return VStack(alignment: .leading, spacing: 10) {
            CarnetSectionTitle("Cette semaine") {
                NavigationLink("Bilan complet") { StatsView() }
            }
            HStack(spacing: 8) {
                CarnetStat(label: "Travail", value: DateUtils.hoursLabel(seconds: seconds),
                           detail: "\(weekSessions.count) session\(weekSessions.count > 1 ? "s" : "")")
                CarnetStat(label: "Fait", value: "\(Int((CourseProgress.ratio(done, total) * 100).rounded())) %",
                           detail: "du semestre")
                CarnetStat(label: "Juste", value: corrected.isEmpty ? "—" : "\(Int((Double(right) / Double(corrected.count) * 100).rounded())) %",
                           detail: corrected.isEmpty ? "rien de corrigé" : "\(corrected.count) corrigés")
            }
        }
    }

    // MARK: Réglages

    private var settingsLinks: some View {
        CarnetSheet {
            NavigationLink {
                StatsView()
            } label: {
                CarnetRow(icon: "chart.bar.xaxis", tint: Carnet.inkSecondary, title: "Bilan",
                          subtitle: "Temps, matières, avancement, corrections") {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Carnet.inkTertiary)
                }
            }
            .buttonStyle(.plain)
            CarnetRule()
            NavigationLink {
                ProfileView(isEmbedded: true)
            } label: {
                CarnetRow(icon: "gearshape", tint: Carnet.inkSecondary, title: "Réglages",
                          subtitle: "Études, comptes, outils, rappels, données") {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Carnet.inkTertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }
}
