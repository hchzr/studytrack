import SwiftUI
import SwiftData

/// Ce que montrent les autres écrans pendant un blocage : le bureau d'étude est
/// sur l'écran principal, le reste est au repos — le cours, ce qu'on y fait et
/// l'heure de fin. Sans cela, un second écran resterait un bureau ordinaire
/// (Finder, fenêtres ouvertes) à côté d'une session verrouillée.
struct StudyCalmView: View {
    @Environment(MacTimer.self) private var timer
    @Query(sort: \Course.code) private var courses: [Course]

    var body: some View {
        let course = courses.first { $0.id == timer.courseID }
        let tint = MacTargets.tint(course)
        ZStack {
            StudyPalette.ground
            RadialGradient(colors: [tint.opacity(0.12), .clear], center: .center, startRadius: 40, endRadius: 700)
            VStack(spacing: 14) {
                if let course { CourseTag(code: course.displayCode, tint: tint) }
                Text(MacTargets.headline(course: course, taskType: timer.taskType, targetID: timer.targetID))
                    .font(Carnet.serif(.title))
                    .foregroundStyle(StudyPalette.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                StudyTimeline(interval: 1) { date in
                    Text(StudyMode.clock(timer.state, at: date).clockLabel)
                        .font(Carnet.serif(.largeTitle))
                        .monospacedDigit()
                        .foregroundStyle(StudyPalette.inkSecondary)
                }
            }
            .padding(60)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}
