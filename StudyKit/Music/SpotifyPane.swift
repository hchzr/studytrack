import SwiftUI

/// L'onglet Musique, côté Spotify : ton compte piloté comme Music (si tu t'es connecté·e), sinon
/// l'app Spotify de l'appareil (`SpotifyLocalView`) et, en haut, de quoi connecter ton compte.
struct SpotifyPane: View {
    var compact = false
    @State private var account = SpotifyAccount.shared
    @State private var signingIn = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch account.state {
                case .ready:
                    SpotifyPlayerCard(compact: compact)
                    SpotifyPlaylists()
                    SpotifyLinkField()
                    accountFooter
                case .unknown, .checking:
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                case .signedOut, .failed:
                    connectCard
                    SpotifyLocalView()
                }
            }
            .padding(compact ? 16 : 28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(StudyPalette.ground)
        // Volet ouvert : on écoute Spotify ; fermé : plus rien ne tourne.
        .onAppear { account.startWatching() }
        .onDisappear { account.stopWatching() }
        .sheet(isPresented: $signingIn) {
            SpotifySignInSheet {
                signingIn = false
                Task {
                    await account.refresh()
                    account.stopWatching(); account.startWatching()
                }
            }
        }
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ton compte Spotify, piloté d'ici").font(Carnet.serif(18)).foregroundStyle(StudyPalette.ink)
            Text("Connecte-toi une fois : ce qui joue sur ton ordinateur ou ton téléphone, les commandes, le volume, tes playlists — gratuit ou Premium. StudyTrack ne voit jamais ton mot de passe.")
                .font(.callout).foregroundStyle(StudyPalette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if case .failed(let message) = account.state {
                Text(message).font(.caption).foregroundStyle(Carnet.review).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Se connecter à Spotify") { signingIn = true }.buttonStyle(.ink)
                if case .failed = account.state {
                    Button("Réessayer") { Task { await account.refresh() } }.buttonStyle(.paper)
                }
            }
            Text("Non officiel : StudyTrack parle à Spotify comme son lecteur web. Si Spotify change, le pilotage local ci-dessous reste là.")
                .font(.caption).foregroundStyle(StudyPalette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(StudyPalette.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var accountFooter: some View {
        HStack {
            Text("Connecté·e à Spotify (non officiel : StudyTrack parle à Spotify comme son lecteur web).")
                .font(.caption).foregroundStyle(StudyPalette.inkTertiary)
            Spacer()
            Button("Se déconnecter") { Task { await account.signOut() } }
                .buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(StudyPalette.inkSecondary)
        }
    }
}

/// Le morceau en cours, comme le lecteur de Music.
struct SpotifyPlayerCard: View {
    var compact = false
    @State private var account = SpotifyAccount.shared

    private var now: SpotifyWire.Now { account.now }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 18) {
                AsyncImage(url: now.track?.artwork) { image in image.resizable().scaledToFill() } placeholder: {
                    RoundedRectangle(cornerRadius: 10).fill(StudyPalette.raised)
                        .overlay(Image(systemName: "music.note").font(.title).foregroundStyle(StudyPalette.inkTertiary))
                }
                .frame(width: compact ? 72 : 132, height: compact ? 72 : 132)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: .black.opacity(now.isPlaying ? 0.35 : 0.15), radius: now.isPlaying ? 16 : 8, y: 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text(now.track?.title ?? String(localized: "Rien ne joue"))
                        .font(.title3.weight(.semibold)).foregroundStyle(StudyPalette.ink).lineLimit(2)
                    if let artist = now.track?.artist, !artist.isEmpty {
                        Text(artist).foregroundStyle(StudyPalette.inkSecondary).lineLimit(1)
                    }
                    if now.track == nil {
                        Text(now.devices.isEmpty
                             ? "Ouvre Spotify sur un appareil (ordinateur, téléphone…) : il se pilote ici."
                             : "Choisis une playlist ci-dessous, ou lance la lecture.")
                            .font(.callout).foregroundStyle(StudyPalette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    SpotifyDeviceMenu().padding(.top, 6)
                }
            }
            if now.track != nil {
                SpotifyProgress()
                HStack(spacing: 0) {
                    MusicGlyphButton(icon: "shuffle", size: 13, label: "Aléatoire", active: now.shuffle) { account.setShuffle(!now.shuffle) }
                    Spacer()
                    MusicGlyphButton(icon: "backward.fill", size: 20, label: "Précédent") { account.previous() }
                    Spacer()
                    MusicGlyphButton(icon: now.isPlaying ? "pause.fill" : "play.fill", size: 30, label: now.isPlaying ? "Pause" : "Lecture") { account.togglePlayPause() }
                    Spacer()
                    MusicGlyphButton(icon: "forward.fill", size: 20, label: "Suivant") { account.next() }
                    Spacer()
                    MusicGlyphButton(icon: now.repeatTrack ? "repeat.1" : "repeat", size: 13, label: "Répéter",
                                     active: now.repeatContext || now.repeatTrack) { account.cycleRepeat() }
                }
                .frame(maxWidth: 420)
                if let volume = now.volume {
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.fill")
                        MusicSlider(value: volume, onChange: { account.setVolume($0) }, onCommit: { account.setVolume($0) })
                        Image(systemName: "speaker.wave.3.fill")
                    }
                    .font(.caption2).foregroundStyle(StudyPalette.inkTertiary)
                    .frame(maxWidth: 420)
                }
                if !compact, !now.upNext.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("À suivre").font(.caption.weight(.semibold)).foregroundStyle(StudyPalette.inkSecondary)
                        ForEach(now.upNext.prefix(5), id: \.uri) { track in
                            Text(track.artist.isEmpty ? track.title : "\(track.title) · \(track.artist)")
                                .font(.callout).foregroundStyle(StudyPalette.ink).lineLimit(1)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            if let error = account.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Carnet.review)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.smooth(duration: 0.25), value: now.track?.uri)
    }
}

private struct SpotifyProgress: View {
    @State private var account = SpotifyAccount.shared
    @State private var scrubbing: TimeInterval?

    var body: some View {
        let now = account.now
        TimelineView(.animation(minimumInterval: 1, paused: !now.isPlaying || scrubbing != nil)) { context in
            let duration = max(now.duration, 1)
            let elapsed = min(scrubbing ?? now.elapsed(at: context.date), duration)
            VStack(spacing: 5) {
                MusicSlider(value: elapsed / duration, onChange: { scrubbing = $0 * duration },
                            onCommit: { account.seek(to: $0 * duration); scrubbing = nil })
                HStack {
                    Text(MusicNowPlayingCard.time(elapsed))
                    Spacer()
                    Text("−" + MusicNowPlayingCard.time(max(0, now.duration - elapsed)))
                }
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(StudyPalette.inkTertiary)
            }
        }
        .frame(maxWidth: 420)
    }
}

/// Où joue Spotify, et le faire passer à un autre appareil.
private struct SpotifyDeviceMenu: View {
    @State private var account = SpotifyAccount.shared

    var body: some View {
        let now = account.now
        if !now.devices.isEmpty {
            Menu {
                Section("Écouter sur") {
                    ForEach(now.devices) { device in
                        Button { account.move(to: device.id) } label: {
                            Label(device.name, systemImage: device.id == now.activeDevice ? "checkmark" : device.icon)
                        }
                    }
                }
            } label: {
                let active = now.devices.first { $0.id == now.activeDevice }
                HStack(spacing: 6) {
                    Image(systemName: active?.icon ?? "hifispeaker")
                    Text(active.map { "Sur \($0.name)" } ?? String(localized: "Choisir un appareil"))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(StudyPalette.inkSecondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(StudyPalette.raisedMore.opacity(0.7), in: Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
    }
}

/// Tes playlists : un geste pour lancer.
private struct SpotifyPlaylists: View {
    @State private var account = SpotifyAccount.shared

    var body: some View {
        if !account.playlists.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Tes playlists").font(Carnet.serif(16)).foregroundStyle(StudyPalette.ink)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(account.playlists) { list in
                        Button { account.play(uri: list.uri) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                AsyncImage(url: list.image) { image in image.resizable().scaledToFill() } placeholder: {
                                    RoundedRectangle(cornerRadius: 8).fill(StudyPalette.raised)
                                        .overlay(Image(systemName: "music.note.list").foregroundStyle(StudyPalette.inkTertiary))
                                }
                                .frame(width: 120, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(alignment: .bottomTrailing) {
                                    if account.now.contextURI == list.uri {
                                        Image(systemName: "speaker.wave.2.fill").font(.caption)
                                            .padding(6).background(.ultraThinMaterial, in: Circle()).padding(6)
                                    }
                                }
                                Text(list.name).font(.caption.weight(.medium)).foregroundStyle(StudyPalette.ink).lineLimit(2)
                            }
                            .frame(width: 120, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(list.owner.isEmpty ? list.name : "\(list.name) — \(list.owner)")
                    }
                }
            }
        }
    }
}

/// Un lien collé (playlist, album, titre) : lancé sur l'appareil qui joue.
private struct SpotifyLinkField: View {
    @State private var account = SpotifyAccount.shared
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lancer un lien").font(Carnet.serif(16)).foregroundStyle(StudyPalette.ink)
            HStack {
                TextField("Lien d'une playlist ou d'un album (Partager › Copier le lien)", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(play)
                Button("Écouter", action: play)
                    .buttonStyle(.ink)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func play() {
        guard let uri = SpotifyLocal.uri(from: link) else { account.lastError = String(localized: "Colle un lien Spotify (playlist, album…)."); return }
        account.play(uri: uri)
        link = ""
    }
}
