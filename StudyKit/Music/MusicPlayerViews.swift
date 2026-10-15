import MusicKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

// Le lecteur du mode étude : la pochette, le morceau, les commandes — en grand
// dans l'onglet Musique, en petit dans la barre du haut (Mac) ou au-dessus des
// onglets (iPhone). Dessiné d'après le lecteur de Music : des glyphes nus, des
// curseurs fins qui s'épaississent sous le pointeur, un fond pris à la pochette.

/// L'onglet Musique : le lecteur, et de quoi choisir.
struct MusicPane: View {
    var compact = false
    @State private var music = StudyMusic.shared

    var body: some View {
        Group {
            if compact {
                VStack(spacing: 0) {
                    if music.nowPlaying.hasTrack {
                        MusicNowPlayingCard(compact: true)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                    }
                    MusicBrowser()
                }
                .background(StudyPalette.ground)
            } else {
                // Des tailles exactes : l'avancée du morceau, redessinée chaque
                // seconde, ne fait plus recalculer la grille des pochettes à côté.
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            MusicNowPlayingCard(compact: false)
                                .padding(.horizontal, 28)
                                .padding(.top, 28)
                                .padding(.bottom, 20)
                            MusicUpNextList()
                                .frame(maxHeight: .infinity)
                        }
                        .frame(width: 344, height: geometry.size.height, alignment: .top)
                        .background { MusicArtworkBackdrop() }
                        Rectangle().fill(StudyPalette.rule).frame(width: 1)
                        MusicBrowser()
                            .frame(width: max(0, geometry.size.width - 345), height: geometry.size.height)
                    }
                }
                .background(StudyPalette.ground)
            }
        }
        .musicAttached()
    }
}

/// Le fond du lecteur : la couleur de la pochette, en lueur, comme dans Music.
/// La même technique que la lueur du cours derrière le mode étude.
private struct MusicArtworkBackdrop: View {
    @State private var music = StudyMusic.shared

    var body: some View {
        let tint = music.artworkTint ?? .clear
        ZStack {
            StudyPalette.raised
            LinearGradient(colors: [tint.opacity(0.42), tint.opacity(0.12), .clear],
                           startPoint: .top, endPoint: .bottom)
        }
        .animation(.smooth(duration: 0.8), value: music.artworkTint)
        .ignoresSafeArea()
    }
}

/// Le morceau en cours.
struct MusicNowPlayingCard: View {
    var compact: Bool
    @State private var music = StudyMusic.shared

    private var playing: StudyMusic.NowPlaying { music.nowPlaying }

    var body: some View {
        if compact { compactBody } else { fullBody }
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            MusicNowArtwork(side: 288, radius: 10)
                .shadow(color: .black.opacity(playing.isPlaying ? 0.45 : 0.25), radius: playing.isPlaying ? 22 : 12, y: playing.isPlaying ? 12 : 6)
                .scaleEffect(playing.isPlaying || !playing.hasTrack ? 1 : 0.9)
                .animation(.spring(response: 0.5, dampingFraction: 0.78), value: playing.isPlaying)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
            if playing.hasTrack {
                titles
                    .padding(.bottom, 14)
                MusicProgress(playing: playing, onSeek: music.seek(to:))
                    .padding(.bottom, 14)
                HStack(spacing: 0) {
                    MusicGlyphButton(icon: "shuffle", size: 13, label: "Aléatoire", active: playing.shuffle) {
                        music.setShuffle(!playing.shuffle)
                    }
                    Spacer()
                    MusicGlyphButton(icon: "backward.fill", size: 20, label: "Précédent") { music.previous() }
                    Spacer()
                    MusicGlyphButton(icon: playing.isPlaying ? "pause.fill" : "play.fill", size: 30,
                                     label: playing.isPlaying ? "Pause" : "Lecture") { music.togglePlayPause() }
                    Spacer()
                    MusicGlyphButton(icon: "forward.fill", size: 20, label: "Suivant") { music.next() }
                    Spacer()
                    MusicGlyphButton(icon: playing.repeatMode.icon, size: 13, label: "Répéter", active: playing.repeatMode != .off) {
                        music.cycleRepeat()
                    }
                }
                #if os(macOS)
                MusicVolume()
                    .padding(.top, 14)
                #else
                if music.isRemote, music.volume != nil {
                    MusicVolume().padding(.top, 14)
                }
                #endif
                MusicDevicePicker()
                    .padding(.top, 16)
            } else if music.automationDenied {
                VStack(alignment: .leading, spacing: 8) {
                    Text("StudyTrack ne peut pas contrôler Music")
                        .font(Carnet.serif(.title3, weight: .semibold))
                        .foregroundStyle(StudyPalette.ink)
                    Text("macOS a refusé l'accès. Active Music pour StudyTrack dans Réglages Système › Confidentialité et sécurité › Automatisation (avant de commencer une session : les Réglages sont fermés pendant un blocage).")
                        .font(.callout)
                        .foregroundStyle(StudyPalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    #if os(macOS)
                    Button("Redemander l'autorisation") { StudyMusic.shared.askAutomationAgain() }
                        .buttonStyle(.paper)
                    Button("Ouvrir les Réglages Système") {
                        // Pendant un blocage, les Réglages sont permis 90 secondes.
                        NotificationCenter.default.post(name: .studyAllowSystemSettings, object: nil)
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.paper)
                    #endif
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Rien ne joue")
                        .font(Carnet.serif(.title3, weight: .semibold))
                        .foregroundStyle(StudyPalette.ink)
                    Text("Choisis un album, une playlist ou un morceau. La musique joue dans Music et continue après la session.")
                        .font(.callout)
                        .foregroundStyle(StudyPalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let error = music.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Carnet.review)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: music.lastError)
    }

    private var compactBody: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                MusicNowArtwork(side: 52, radius: 6)
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(playing.title ?? "")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(StudyPalette.ink)
                        Text(playing.artist ?? "")
                            .font(.caption)
                            .foregroundStyle(StudyPalette.inkSecondary)
                    }
                    .lineLimit(1)
                    MusicProgress(playing: playing, onSeek: music.seek(to:), showsTimes: false)
                }
                if music.devices.count > 1 { MusicDevicePicker(compact: true) }
            }
            // Les mêmes gestes que le grand lecteur : l'iPhone n'en est plus privé.
            HStack(spacing: 0) {
                MusicGlyphButton(icon: "shuffle", size: 13, label: "Aléatoire", active: playing.shuffle) {
                    music.setShuffle(!playing.shuffle)
                }
                Spacer()
                MusicGlyphButton(icon: "backward.fill", size: 18, label: "Précédent") { music.previous() }
                Spacer()
                MusicGlyphButton(icon: playing.isPlaying ? "pause.fill" : "play.fill", size: 24,
                                 label: playing.isPlaying ? "Pause" : "Lecture") { music.togglePlayPause() }
                Spacer()
                MusicGlyphButton(icon: "forward.fill", size: 18, label: "Suivant") { music.next() }
                Spacer()
                MusicGlyphButton(icon: playing.repeatMode.icon, size: 13, label: "Répéter", active: playing.repeatMode != .off) {
                    music.cycleRepeat()
                }
            }
        }
        .padding(12)
        .background {
            ZStack {
                StudyPalette.raised
                (music.artworkTint ?? .clear).opacity(0.25)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .animation(.smooth(duration: 0.8), value: music.artworkTint)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(playing.title ?? "")
                .font(.title3.weight(.semibold))
                .foregroundStyle(StudyPalette.ink)
            Text(playing.artist ?? "")
                .font(.body)
                .foregroundStyle(StudyPalette.inkSecondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help([playing.title, playing.artist, playing.album].compactMap { $0 }.joined(separator: " — "))
        .contentTransition(.opacity)
        .animation(.smooth(duration: 0.3), value: playing.key)
    }

    static func time(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        return Duration.seconds(Int(seconds)).formatted(.time(pattern: .minuteSecond))
    }
}

// MARK: - Curseurs

/// L'avancée du morceau : une ligne fine, qu'on tire n'importe où.
private struct MusicProgress: View {
    let playing: StudyMusic.NowPlaying
    let onSeek: (TimeInterval) -> Void
    var showsTimes = true
    @State private var scrubbing: TimeInterval?

    var body: some View {
        // Une fois par seconde (l'affichage est en secondes), et rien à l'arrêt.
        TimelineView(.animation(minimumInterval: 1, paused: !playing.isPlaying || scrubbing != nil)) { context in
            let duration = max(playing.duration, 1)
            let elapsed = min(scrubbing ?? playing.elapsed(at: context.date), duration)
            VStack(spacing: 5) {
                MusicSlider(value: elapsed / duration,
                            onChange: { scrubbing = $0 * duration },
                            onCommit: { fraction in
                                onSeek(fraction * duration)
                                scrubbing = nil
                            })
                if showsTimes {
                    HStack {
                        Text(MusicNowPlayingCard.time(elapsed))
                        Spacer()
                        Text("−" + MusicNowPlayingCard.time(max(0, playing.duration - elapsed)))
                    }
                    .font(.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(scrubbing == nil ? StudyPalette.inkTertiary : StudyPalette.inkSecondary)
                }
            }
        }
        .disabled(!playing.hasTrack)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Position")
        .accessibilityValue(MusicNowPlayingCard.time(playing.elapsed(at: Date())))
    }
}

/// Le volume de Music (sur l'iPhone : celui du Mac, quand c'est lui qui joue).
private struct MusicVolume: View {
    @State private var music = StudyMusic.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
            MusicSlider(value: music.volume ?? 1, onChange: { music.setVolume($0) }, onCommit: { music.setVolume($0) })
            Image(systemName: "speaker.wave.3.fill")
        }
        .font(.caption2)
        .foregroundStyle(StudyPalette.inkTertiary)
        .disabled(music.volume == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((music.volume ?? 0) * 100)) %")
    }
}

/// Un curseur à la façon de Music : 4 pt au repos, 8 pt sous le pointeur ou
/// pendant qu'on tire ; pas de bouton rond.
private struct MusicSlider: View {
    let value: Double
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void
    @State private var hovering = false
    @State private var dragging = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        GeometryReader { proxy in
            let active = (hovering || dragging) && isEnabled
            let height: CGFloat = active ? 8 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(StudyPalette.ink.opacity(0.16))
                Capsule()
                    .fill(StudyPalette.ink.opacity(active ? 0.95 : 0.7))
                    .frame(width: max(height, proxy.size.width * min(max(value, 0), 1)))
            }
            .frame(height: height)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        dragging = true
                        onChange(min(max(gesture.location.x / proxy.size.width, 0), 1))
                    }
                    .onEnded { gesture in
                        dragging = false
                        onCommit(min(max(gesture.location.x / proxy.size.width, 0), 1))
                    }
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: active)
        }
        .frame(height: 14)
        .onHover { hovering = $0 }
    }
}

// MARK: - Mini lecteur

/// Le lecteur en petit : la pochette, le titre, lecture/pause, suivant, et un
/// filet d'avancée. Un clic sur la pochette ouvre l'onglet Musique.
struct MusicMiniPlayer: View {
    /// Toute la largeur (au-dessus des onglets de l'iPhone).
    var wide = false
    var open: () -> Void
    @State private var music = StudyMusic.shared
    @State private var hovering = false

    var body: some View {
        let playing = music.nowPlaying
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 9) {
                    MusicNowArtwork(side: wide ? 34 : 28, radius: 5)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(playing.hasTrack ? (playing.title ?? "") : (music.automationDenied ? String(localized: "Music n'est pas autorisé") : String(localized: "Musique")))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(StudyPalette.ink)
                        HStack(spacing: 4) {
                            if music.isRemote {
                                Image(systemName: music.playingOn.icon).font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(music.artworkTint ?? StudyPalette.inkSecondary)
                            }
                            Text(!playing.hasTrack
                                 ? (music.automationDenied ? String(localized: "Réglages Système › Confidentialité › Automatisation") : String(localized: "Rien ne joue"))
                                 : music.isRemote ? "Sur ton \(music.playingOn.label)" + (playing.artist.map { " · \($0)" } ?? "") : (playing.artist ?? ""))
                                .font(.caption)
                                .foregroundStyle(StudyPalette.inkSecondary)
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: wide ? .infinity : 170, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ouvrir la musique")
            if playing.hasTrack {
                MusicGlyphButton(icon: "backward.fill", size: 13, label: "Précédent") { music.previous() }
                MusicGlyphButton(icon: playing.isPlaying ? "pause.fill" : "play.fill", size: 15,
                                 label: playing.isPlaying ? "Pause" : "Lecture") { music.togglePlayPause() }
                MusicGlyphButton(icon: "forward.fill", size: 13, label: "Suivant") { music.next() }
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 3)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovering ? StudyPalette.rule : StudyPalette.raisedMore)
        }
        .overlay(alignment: .bottom) {
            if playing.hasTrack {
                // Au survol, la ligne devient un curseur qu'on tire.
                Group {
                    if hovering {
                        MusicProgress(playing: playing, onSeek: { music.seek(to: $0) }, showsTimes: false)
                            .frame(height: 12)
                    } else {
                        MiniProgressLine(playing: playing)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 1)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .musicAttached()
    }
}

/// Le filet d'avancée sous le mini lecteur : figé quand rien ne joue.
private struct MiniProgressLine: View {
    let playing: StudyMusic.NowPlaying

    var body: some View {
        TimelineView(.animation(minimumInterval: 2, paused: !playing.isPlaying)) { context in
            GeometryReader { proxy in
                let fraction = playing.duration > 0 ? min(playing.elapsed(at: context.date) / playing.duration, 1) : 0
                Capsule()
                    .fill(StudyPalette.inkSecondary.opacity(0.7))
                    .frame(width: proxy.size.width * fraction, height: 1.5)
            }
        }
        .frame(height: 1.5)
        .accessibilityHidden(true)
    }
}

// MARK: - Pochette, boutons

/// La pochette du morceau en cours : celle de Music, ou celle du catalogue.
struct MusicNowArtwork: View {
    let side: CGFloat
    let radius: CGFloat
    @State private var music = StudyMusic.shared

    var body: some View {
        ZStack {
            Rectangle().fill(music.artworkTint?.opacity(0.35) ?? StudyPalette.raisedMore)
            if let image = music.artwork {
                Image(platformImage: image).resizable().scaledToFill()
                    .transition(.opacity)
            } else if let url = music.artworkURL {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: side * 0.3, weight: .light))
                    .foregroundStyle(StudyPalette.inkTertiary)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        }
        .animation(.smooth(duration: 0.35), value: music.nowPlaying.key)
    }
}

/// Un bouton de lecteur : un glyphe nu, un disque au survol (Mac), un léger
/// enfoncement au clic. La cible fait au moins 28 pt.
private struct MusicGlyphButton: View {
    let icon: String
    var size: CGFloat
    let label: LocalizedStringKey
    var active = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .regular))
                .contentTransition(.symbolEffect(.replace.downUp))
                .foregroundStyle(active ? Carnet.correct : StudyPalette.ink)
                .frame(width: max(28, size * 1.75), height: max(28, size * 1.75))
                .overlay(alignment: .bottom) {
                    // L'aléatoire, la répétition : un point quand c'est actif, pas seulement une couleur.
                    if active {
                        Circle().fill(Carnet.correct).frame(width: 3, height: 3).offset(y: 2)
                    }
                }
        }
        .buttonStyle(MusicGlyphButtonStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
        .help(Text(label))
    }
}

private struct MusicGlyphButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GlyphBody(configuration: configuration)
    }

    private struct GlyphBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .background {
                    Circle().fill(StudyPalette.ink.opacity(configuration.isPressed ? 0.14 : (hovering ? 0.07 : 0)))
                }
                .contentShape(Circle())
                .scaleEffect(configuration.isPressed ? 0.86 : 1)
                .opacity(isEnabled ? 1 : 0.35)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

// MARK: - À suivre

/// La file de Music : double-clic pour sauter, glisser pour réordonner, retirer.
struct MusicUpNextList: View {
    @State private var music = StudyMusic.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("À suivre")
                    .font(.headline)
                    .foregroundStyle(StudyPalette.ink)
                if !music.upNext.isEmpty {
                    Text("\(music.upNext.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(StudyPalette.inkTertiary)
                }
                Spacer()
                if music.canEditQueue, !music.upNext.isEmpty {
                    Button("Effacer") { music.clearQueue() }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(StudyPalette.inkSecondary)
                        .help("Vider « À suivre »")
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 6)
            if music.upNext.isEmpty {
                Text(music.nowPlaying.hasTrack ? "Rien après ce morceau." : "La file de Music apparaît ici.")
                    .font(.callout)
                    .foregroundStyle(StudyPalette.inkTertiary)
                    .padding(.horizontal, 28)
                    .padding(.top, 4)
                Spacer(minLength: 0)
            } else {
                List {
                    ForEach(music.upNext) { item in
                        MusicUpNextRow(item: item, editable: music.canEditQueue)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 0, trailing: 18))
                            .contextMenu {
                                Button("Lire maintenant", systemImage: "play.fill") { music.playQueued(item) }
                                if music.canEditQueue {
                                    Button("Lire ensuite", systemImage: "text.line.first.and.arrowtriangle.forward") { music.playQueuedNext(item) }
                                    Divider()
                                    Button("Retirer de la file", systemImage: "minus.circle", role: .destructive) { music.removeQueued([item]) }
                                }
                            }
                    }
                    .onMove { source, destination in music.moveQueued(fromOffsets: source, toOffset: destination) }
                    .onDelete { offsets in music.removeQueued(offsets.map { music.upNext[$0] }) }
                    .moveDisabled(!music.canEditQueue)
                    .deleteDisabled(!music.canEditQueue)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 40)
                .animation(.smooth(duration: 0.25), value: music.upNext)
            }
        }
        .onAppear { music.watchQueue() }
        .onDisappear { music.unwatchQueue() }
    }
}

private struct MusicUpNextRow: View {
    let item: StudyMusic.QueueItem
    let editable: Bool
    @State private var music = StudyMusic.shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title ?? String(localized: "Sans titre"))
                    .font(.callout)
                    .foregroundStyle(StudyPalette.ink)
                Text(item.artist ?? item.album ?? "")
                    .font(.caption)
                    .foregroundStyle(StudyPalette.inkSecondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .trailing) {
                if item.duration > 0 {
                    Text(MusicNowPlayingCard.time(item.duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(StudyPalette.inkTertiary)
                        .opacity(hovering && editable ? 0 : 1)
                }
                if hovering, editable {
                    Button { music.removeQueued([item]) } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.callout)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .buttonStyle(MusicPressStyle())
                    .foregroundStyle(StudyPalette.inkSecondary)
                    .help("Retirer de la file")
                    .transition(.opacity)
                }
            }
            .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(StudyPalette.ink.opacity(hovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture(count: 2) { music.playQueued(item) }
        .help("Double-clic pour le lire")
    }
}

private struct MusicAttached: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear { StudyMusic.shared.attach() }
            .onDisappear { StudyMusic.shared.detach() }
    }
}

extension View {
    /// Tant que cette vue est là, la musique est suivie.
    func musicAttached() -> some View { modifier(MusicAttached()) }
}


// MARK: - Où ça joue

/// Un seul lecteur pour tes appareils : où joue la musique, et la faire
/// passer de l'un à l'autre — elle reprend au même morceau, à la même seconde.
struct MusicDevicePicker: View {
    var compact = false
    @State private var music = StudyMusic.shared

    var body: some View {
        let devices = music.devices
        if devices.count > 1 {
            Menu {
                Section("Écouter sur") {
                    ForEach(devices, id: \.id) { device in
                        Button {
                            withAnimation(.snappy) { music.move(to: device.id) }
                        } label: {
                            let current = device.isHere ? !music.isRemote : (music.isRemote && music.playingOn == device.platform)
                            if current {
                                Label(device.isHere ? "Ce \(device.platform.label)" : "Ton \(device.platform.label)", systemImage: "checkmark")
                            } else {
                                Label(device.isHere ? "Ce \(device.platform.label)" : "Ton \(device.platform.label)", systemImage: device.platform.icon)
                            }
                        }
                    }
                }
            } label: {
                if compact {
                    Image(systemName: music.playingOn.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StudyPalette.inkSecondary)
                        .frame(width: 30, height: 30)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: music.playingOn.icon)
                        Text(music.isRemote ? "Sur ton \(music.playingOn.label)" : "Sur ce \(music.playingOn.label)")
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(music.isRemote ? (music.artworkTint ?? StudyPalette.ink) : StudyPalette.inkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(StudyPalette.raisedMore.opacity(0.7), in: Capsule())
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Où joue la musique — la faire passer d'un appareil à l'autre")
        }
    }
}

extension Notification.Name {
    /// Les Réglages Système sont permis un moment pendant un blocage (le mode étude du Mac l'écoute).
    static let studyAllowSystemSettings = Notification.Name("study.allowSystemSettings")
}
