import SwiftUI

/// Les sites d'un cours en pastilles — Moodle, Courseware, Botafogo, vidéos,
/// Explique — à un toucher, au même endroit sur l'iPhone et le Mac. Ils
/// étaient éparpillés (un lien dans un menu, les autres dans le mode étude).
struct CourseSitesRow: View {
    let course: Course
    /// L'iPhone ouvre dans son navigateur (la session EPFL y est) ; le Mac, dans le sien.
    var open: (URL, String) -> Void

    var body: some View {
        let sites = StudyMode.courseSites(course)
        if !sites.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sites) { site in
                        if case .web(let url) = site.kind {
                            Button { open(url, site.title) } label: {
                                Label(site.title, systemImage: site.icon)
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(Carnet.ink)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(Carnet.sheet, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}
