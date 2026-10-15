import AppKit
import SwiftData
import SwiftUI

/// Les onglets d'à côté, comme ceux d'un navigateur ; « + » ouvre la page
/// de choix (ce qu'on peut mettre à côté).
struct SideTabBar: View {
    var desk: StudyDesk
    let items: [StudyDesk.SideItem]
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(items) { item in
                        SideTab(item: item, selected: item.id == desk.sideSelection, tint: tint,
                                select: { desk.sideSelection = item.id }, close: { desk.closeSide(item.id) })
                    }
                    let choosing = !items.contains { $0.id == desk.sideSelection }
                    Button { desk.sideSelection = nil } label: {
                        Image(systemName: "plus")
                            .font(.callout.weight(.semibold))
                            .frame(width: 28, height: 26)
                            .background(choosing ? Carnet.ground : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(choosing ? StudyPalette.ink : StudyPalette.inkSecondary)
                    .help("Ouvrir autre chose à côté")
                }
                .padding(.horizontal, 8)
            }
            DeskIconButton(icon: "sidebar.right", help: "Fermer le volet (⌘\\) — les onglets restent") { desk.sideOpen = false }
                .padding(.trailing, 6)
        }
        .frame(height: 40)
        .deskGlass(in: Rectangle())
    }
}

struct SideTab: View {
    let item: StudyDesk.SideItem
    let selected: Bool
    let tint: Color
    var select: () -> Void
    var close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? tint : StudyPalette.inkTertiary)
            Text(item.title)
                .font(.callout.weight(selected ? .medium : .regular))
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Button(action: close) {
                Image(systemName: "xmark").font(.caption2.weight(.bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(StudyPalette.inkSecondary)
            .opacity(selected || hovering ? 1 : 0)
            .help("Fermer l'onglet")
        }
        .foregroundStyle(selected ? StudyPalette.ink : StudyPalette.inkSecondary)
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .frame(height: 28)
        .background(selected ? Carnet.ground : (hovering ? StudyPalette.raisedMore : .clear),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(StudyPalette.rule)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .contextMenu { Button("Fermer l'onglet", action: close) }
    }
}

/// La page « nouvel onglet » d'à côté : ce qu'on peut y mettre, rangé.
struct SidePicker: View {
    struct Entry: Identifiable {
        let item: StudyDesk.SideItem
        let detail: String
        var id: UUID { item.id }
    }

    struct Group: Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    let groups: [Group]
    let openIDs: [StudyDesk.SideItem]
    let tint: Color
    var open: (StudyDesk.SideItem) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("À côté").font(Carnet.serif(.largeTitle)).foregroundStyle(StudyPalette.ink)
                    Text("Ce que tu veux garder sous les yeux pendant que tu travailles au centre.")
                        .font(.callout).foregroundStyle(StudyPalette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title.uppercased())
                            .font(.caption2.weight(.semibold)).tracking(1)
                            .foregroundStyle(StudyPalette.inkTertiary)
                        ForEach(group.entries) { entry in
                            row(entry)
                        }
                    }
                }
                Text("Dans le cours ou tes notes, « À côté » en haut d'un document l'ajoute ici.")
                    .font(.caption).foregroundStyle(StudyPalette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ entry: Entry) -> some View {
        let isOpen = openIDs.contains { $0.same(entry.item) }
        return Button { open(entry.item) } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.item.icon)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(StudyPalette.raisedMore, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.item.title).foregroundStyle(StudyPalette.ink).lineLimit(1)
                    Text(entry.detail).font(.caption).foregroundStyle(StudyPalette.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if isOpen {
                    Text("Ouvert").font(.caption2).foregroundStyle(StudyPalette.inkTertiary)
                }
            }
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(DeskRowStyle())
    }
}

struct DeskRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(configuration.isPressed ? StudyPalette.raisedMore : (hovering ? StudyPalette.raised : .clear),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onHover { hovering = $0 }
        }
    }
}

struct SidePlaceholder: View {
    let icon: String
    let text: LocalizedStringKey
    var action: (LocalizedStringKey, () -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.title).foregroundStyle(StudyPalette.inkTertiary)
            Text(text).foregroundStyle(StudyPalette.inkSecondary)
            if let action {
                Button(action.0, action: action.1).buttonStyle(.paper)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Un cahier de tes notes, à côté ; relu quand GoodNotes le resauvegarde.
struct NotebookReader: View {
    let path: String
    private var store: NotesStore { .shared }

    var body: some View {
        if let document = store.documents.first(where: { $0.path == path }), let url = store.url(document) {
            PDFPane(url: url, memory: url.absoluteString)
                .id("\(path)#\(document.modified.timeIntervalSince1970)")
                .overlay(alignment: .topTrailing) {
                    Button { Task { await store.refresh(force: true) } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .frame(width: 28, height: 28)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .help("Relire le cahier (sauvegardé \(document.modified.formatted(.relative(presentation: .named))))")
                }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await store.refresh() }
        }
    }
}

/// Un petit bouton d'icône, pour les en-têtes.
struct DeskIconButton: View {
    let icon: String
    let help: LocalizedStringKey
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.callout.weight(.semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(StudyPalette.inkSecondary)
        .help(help)
    }
}
