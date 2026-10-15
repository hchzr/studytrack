import SwiftUI
import SwiftData

/// Ce que montrent les autres écrans pendant un blocage : le bureau d'étude est
/// sur l'écran principal, le reste est au repos — le cours, ce qu'on y fait et
/// l'heure de fin. Sans cela, un second écran resterait un bureau ordinaire
/// (Finder, fenêtres ouvertes) à côté d'une session verrouillée.
struct StudyCalmView: View {
    /// L'écran que ce bureau calme occupe (pour y amener une app).
    var screenFrame: CGRect
    @Environment(MacTimer.self) private var timer
    @Environment(MacSettings.self) private var settings
    @Query(sort: \Course.code) private var courses: [Course]

    var body: some View {
        let course = courses.first { $0.id == timer.courseID }
        let tint = MacTargets.tint(course)
        ZStack {
            StudyPalette.ground
            if let image = DeskGround.shared.image(for: NSScreen.screens.first { $0.frame == screenFrame }) {
                Color.clear
                    .overlay { Image(nsImage: image).resizable().scaledToFill() }
                    .clipped()
                    .overlay(StudyPalette.ground.opacity(0.86))
            }
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
                // Une app permise sur cet écran : GoodNotes ici, le reste sur l'autre.
                HStack(spacing: 14) {
                    ForEach(settings.studyApps.filter { $0 != StudyMode.finderBundleID && StudyModeController.isInstalled($0) }, id: \.self) { bundleID in
                        Button { bring(bundleID) } label: {
                            VStack(spacing: 4) {
                                if let icon = StudyModeController.icon(for: bundleID) { Image(nsImage: icon).resizable().frame(width: 32, height: 32) }
                                Text(StudyModeController.name(for: bundleID)).font(.caption2).foregroundStyle(StudyPalette.inkTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Amener ici")
                    }
                }
                .padding(.top, 18)
            }
            .padding(60)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .onAppear { DeskGround.shared.load() }
    }

    /// Ouvre l'app et pose sa fenêtre sur cet écran.
    private func bring(_ bundleID: String) {
        StudyModeController.shared.openApp(bundleID: bundleID)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
                  let screen = NSScreen.screens.first(where: { $0.frame == screenFrame }) else { return }
            AppPlacement.shared.bringFrontWindow(of: app, to: screen)
        }
    }
}
