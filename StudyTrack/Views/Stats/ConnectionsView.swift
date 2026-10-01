import SwiftUI

/// Une connexion à faire : la feuille qui la fait.
enum ConnectionSheet: String, Identifiable {
    case moodle, courseware, explique, mediaspace, groups, ankiweb
    var id: String { rawValue }
}

/// La feuille de connexion d'un compte, qui se ferme seule une fois connecté·e.
struct ConnectionSheetContent: View {
    let sheet: ConnectionSheet
    @Environment(AppContainer.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch sheet {
        case .moodle:
            SiteLoginSheet(source: .moodle) { dismiss() }
        case .courseware:
            SiteLoginSheet(source: .courseware) { dismiss() }
        case .explique:
            SiteLoginSheet(site: .explique) { dismiss() }
        case .mediaspace:
            SiteLoginSheet(site: .mediaspace) { dismiss() }
        case .groups:
            NavigationStack {
                GroupsSignInView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Fermer") { dismiss() } }
                    }
            }
            .onChange(of: app.social.isSignedIn) { _, signedIn in
                if signedIn { dismiss() }
            }
        case .ankiweb:
            NavigationStack {
                AnkiSettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
                    }
            }
        }
    }
}

/// Les comptes de l'app, leur état, et le bouton qui connecte.
///
/// La même liste dans l'accueil guidé et dans le profil : tout se relie au même
/// endroit, et chaque ligne dit à quoi sert le compte.
struct ConnectionsList: View {
    @Environment(AppContainer.self) private var app
    @State private var sheet: ConnectionSheet?
    @State private var checkingMoodle = false
    @State private var calendarGranted = false

    private var center: ConnectionCenter { .shared }

    var body: some View {
        CarnetSheet {
            row(icon: "graduationcap", title: "Moodle",
                purpose: "Séries, énoncés et théorie des cours, mis à jour tout seuls",
                status: moodleStatus, connected: center.state(of: .moodle) == .connected,
                action: checkingMoodle ? nil : { sheet = .moodle })
            CarnetRule()
            row(icon: "play.rectangle", title: "Courseware",
                purpose: "Vidéos des MOOC (classe inversée) — facultatif",
                status: "Se connecter si un cours y renvoie", connected: false,
                action: { sheet = .courseware })
            CarnetRule()
            row(icon: "sparkles.tv", title: "Explique",
                purpose: "Cours en replay et exercices d'AICC (CS-101), semaine par semaine",
                status: "Se connecter une fois, avec le compte EPFL", connected: false,
                action: { sheet = .explique })
            CarnetRule()
            row(icon: "video", title: "MediaSpace",
                purpose: "Enregistrements des cours, ouverts directement depuis la théorie",
                status: "Se connecter une fois, avec Switch edu-ID", connected: false,
                action: { sheet = .mediaspace })
            CarnetRule()
            row(icon: "person.2", title: "Compte StudyTrack",
                purpose: "Groupes, entraide, progression partagée",
                status: app.social.isSignedIn ? "Connecté·e" : (center.state(of: .groups) == .expired ? "Session expirée" : "Pas de compte"),
                connected: app.social.isSignedIn,
                action: app.social.isSignedIn ? nil : { sheet = .groups })
            CarnetRule()
            row(icon: "rectangle.stack", title: "AnkiWeb",
                purpose: "Cartes créées depuis les exercices, temps de révision",
                status: ankiStatus,
                connected: AnkiWebSync.shared.isSignedIn && center.state(of: .ankiweb) != .expired,
                action: { sheet = .ankiweb })
            CarnetRule()
            row(icon: "calendar", title: "Calendrier de l'iPhone",
                purpose: "Ton horaire et tes sessions dans l'agenda",
                status: calendarGranted ? "Accès accordé" : "Accès à autoriser",
                connected: calendarGranted,
                action: calendarGranted ? nil : {
                    Task { calendarGranted = await app.calendar.requestAccess() }
                })
        }
        .sheet(item: $sheet) { ConnectionSheetContent(sheet: $0) }
        .task {
            calendarGranted = app.calendar.hasAccess
            await checkMoodle()
        }
        .onChange(of: sheet) { _, value in
            if value == nil { Task { await checkMoodle() } }
        }
    }

    private var moodleStatus: String {
        if checkingMoodle { return "Vérification…" }
        switch center.state(of: .moodle) {
        case .connected: return "Connecté·e"
        case .expired: return "Reconnexion nécessaire"
        case .unknown: return "Pas encore connecté·e"
        }
    }

    private var ankiStatus: String {
        guard AnkiWebSync.shared.isSignedIn else { return "Facultatif" }
        return center.state(of: .ankiweb) == .expired ? "Reconnexion nécessaire" : "Connecté·e (\(AnkiWebSync.shared.username))"
    }

    /// Une vérification réelle (et une reconnexion silencieuse si besoin) :
    /// l'état retenu peut dater.
    private func checkMoodle() async {
        guard !checkingMoodle else { return }
        checkingMoodle = true
        _ = await MoodleClient().ensureSignedIn()
        checkingMoodle = false
    }

    private func row(icon: String, title: String, purpose: String, status: String,
                     connected: Bool, action: (() -> Void)?) -> some View {
        HStack(spacing: 12) {
            CarnetIconTile(systemName: icon, tint: connected ? Carnet.correct : Carnet.inkSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(Carnet.ink)
                Text(purpose).font(.footnote).foregroundStyle(Carnet.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(status, systemImage: connected ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(connected ? Carnet.correct : Carnet.inkTertiary)
            }
            Spacer(minLength: 8)
            if let action {
                Button(connected ? "Gérer" : "Connecter", action: action)
                    .buttonStyle(.carnetSecondary)
            }
        }
        .padding(.horizontal, Carnet.rowInset)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// Profil › Comptes et connexions.
struct ConnectionsView: View {
    var body: some View {
        CarnetScroll(spacing: 18) {
            Text("L'app se reconnecte seule quand elle le peut. Elle ne te le demande que si un compte a vraiment expiré.")
                .font(.subheadline)
                .foregroundStyle(Carnet.inkSecondary)
                .padding(.horizontal, 6)
            ConnectionsList()
        }
        .navigationTitle("Comptes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// La bannière de l'accueil : un compte a expiré et la reconnexion silencieuse
/// a échoué. Une seule à la fois, « Plus tard » la fait taire un jour.
struct ConnectionBanner: View {
    @State private var sheet: ConnectionSheet?
    private var center: ConnectionCenter { .shared }

    var body: some View {
        if let account = center.needingAttention().first {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(Carnet.review)
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(account.label) : reconnecte-toi")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Carnet.ink)
                    Text(account.consequence.capitalizedFirst + ".")
                        .font(.footnote)
                        .foregroundStyle(Carnet.inkSecondary)
                    HStack(spacing: 10) {
                        Button("Se reconnecter") {
                            sheet = switch account {
                            case .moodle: .moodle
                            case .groups: .groups
                            case .ankiweb: .ankiweb
                            }
                        }
                        .buttonStyle(.carnetSecondary)
                        Button("Plus tard") {
                            withAnimation(Motion.snappy) { center.snooze(account) }
                        }
                        .font(.subheadline)
                        .foregroundStyle(Carnet.inkSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Carnet.sheet, in: RoundedRectangle(cornerRadius: Carnet.sheetCorner, style: .continuous))
            .sheet(item: $sheet) { ConnectionSheetContent(sheet: $0) }
        }
    }
}
